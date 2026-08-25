import Foundation

final class Composition {
    /// One immutable selection in the composition source. Anchoring is a
    /// sequence of source-aligned segments, so no state transition infers a
    /// pinyin boundary from the number of displayed Han characters.
    private struct CompositionSegment {
        let sourceKeyRange: Range<Int>
        let syllableRange: Range<Int>
        let text: String
        let tokens: [UInt32]
    }

    private let decoder: PinyinDecoder
    private let inputScheme: InputScheme
    private(set) var raw = ""
    private(set) var committed = ""
    private(set) var cursor = 0
    private(set) var candidates: [Candidate] = []
    private(set) var activeCharacterIndex: Int?
    private var replacementCandidates: [Candidate] = []
    private var predictionCandidates: [Candidate] = []
    // Tokens derived from the host's text before the insertion point. They
    // supersede the local fallback whenever UIKit exposes that text.
    private var hostContextTokens: [UInt32]?
    private var contextTokens: [UInt32] = []
    private var committedTokens: [UInt32] = []
    private var fixedSegments: [CompositionSegment] = []

    init(decoder: PinyinDecoder = BuiltinPinyinDecoder(),
         inputScheme: InputScheme = InputSettings.scheme) {
        self.decoder = decoder
        self.inputScheme = inputScheme
    }

    private var fixedText: String { fixedSegments.map(\.text).joined() }
    private var consumedKeyCount: Int { fixedSegments.last?.sourceKeyRange.upperBound ?? 0 }
    private var consumedSyllableCount: Int { fixedSegments.last?.syllableRange.upperBound ?? 0 }
    var preedit: String { fixedText + raw }
    var selectionLocation: Int {
        fixedText.utf16.count + String(raw.prefix(cursor)).utf16.count
    }
    var isComposing: Bool { !raw.isEmpty || !fixedSegments.isEmpty }
    var sentencePreview: String { fixedText + (candidates.first?.text ?? "") }
    var displayCandidates: [Candidate] {
        if !replacementCandidates.isEmpty { return replacementCandidates }
        return isComposing ? candidates : predictionCandidates
    }

    /// The literal key sequence entered for the active correction syllable.
    /// Do not use Sime's normalized pinyin units here: a Microsoft Shuangpin
    /// user must see their two-key code, and full-pinyin input must retain
    /// typed separators such as an apostrophe.
    var activeEnteredKeys: String? {
        guard let active = activeCharacterIndex,
              let units = candidates.first?.units else { return nil }
        let syllables = units.split(separator: "'").map(String.init)
        let rawSyllableIndex = active - fixedText.count
        guard syllables.indices.contains(rawSyllableIndex) else { return nil }
        let groups = enteredKeyGroups(for: syllables)
        guard groups.indices.contains(rawSyllableIndex) else { return nil }
        return groups[rawSyllableIndex]
    }

    private func enteredKeyGroups(for syllables: [String]) -> [String] {
        var remaining = Substring(raw)
        var groups: [String] = []
        for syllable in syllables {
            switch inputScheme {
            case .microsoftShuangpin:
                guard remaining.count >= 2 else { return [] }
                groups.append(String(remaining.prefix(2)))
                remaining.removeFirst(2)
            case .fullPinyin:
                // Apostrophes are input keys too; associate one with the
                // syllable that follows it so the displayed label is literal.
                var group = ""
                if remaining.first == "'" {
                    group.append("'")
                    remaining.removeFirst()
                }
                guard remaining.count >= syllable.count else { return [] }
                group += String(remaining.prefix(syllable.count))
                remaining.removeFirst(syllable.count)
                groups.append(group)
            }
        }
        return groups
    }

    private func rawLength(forSyllables count: Int, units: String) -> Int {
        guard count > 0 else { return 0 }
        let syllables = units.split(separator: "'").map(String.init)
        let groups = enteredKeyGroups(for: syllables)
        guard groups.count >= count else { return 0 }
        return groups.prefix(count).reduce(0) { $0 + $1.count }
    }

    func restore(raw: String, committed: String) {
        guard !raw.isEmpty || !committed.isEmpty else { return }
        self.raw = raw
        self.committed = committed
        if !committed.isEmpty {
            fixedSegments = [CompositionSegment(
                sourceKeyRange: 0..<0,
                syllableRange: 0..<0,
                text: committed,
                tokens: []
            )]
        }
        cursor = raw.count
        refresh()
    }

    func moveCursor(to offset: Int) {
        cursor = min(max(0, offset), raw.count)
    }

    func updateHostContext(from text: String) {
        let tokens = decoder.tokenize(text)
        guard hostContextTokens != tokens else { return }
        hostContextTokens = tokens
        if isComposing { refresh() }
    }

    func append(_ letter: String) {
        let insertion = raw.index(raw.startIndex, offsetBy: cursor)
        raw.insert(contentsOf: letter.lowercased(), at: insertion)
        cursor += letter.count
        predictionCandidates = []
        activeCharacterIndex = nil
        replacementCandidates = []
        refresh()
    }

    func delete() {
        guard !raw.isEmpty else {
            committed = ""
            committedTokens = []
            fixedSegments = []
            return
        }
        guard cursor > 0 else { return }
        let deletion = raw.index(raw.startIndex, offsetBy: cursor - 1)
        raw.remove(at: deletion)
        cursor -= 1
        refresh()
    }

    func select(_ index: Int) -> String? {
        guard candidates.indices.contains(index) else { return nil }
        let candidate = candidates[index]
        let consumed = rawConsumption(of: candidate)
        let syllables = max(1, candidate.units.split(separator: "'")
            .filter { !$0.isEmpty }.count)
        appendFixedSegment(
            text: candidate.text,
            keyCount: consumed,
            syllableCount: syllables,
            tokens: candidate.tokens
        )
        raw.removeFirst(min(consumed, raw.count))
        cursor = max(0, cursor - consumed)
        refresh()
        guard raw.isEmpty else { return nil }
        let result = fixedText
        publishPredictions(for: committedTokens)
        clearComposition()
        return result
    }

    private func appendFixedSegment(text: String, keyCount: Int,
                                    syllableCount: Int, tokens: [UInt32]) {
        guard keyCount > 0, syllableCount > 0 else { return }
        let keyStart = consumedKeyCount
        let syllableStart = consumedSyllableCount
        fixedSegments.append(CompositionSegment(
            sourceKeyRange: keyStart..<(keyStart + keyCount),
            syllableRange: syllableStart..<(syllableStart + syllableCount),
            text: text,
            tokens: tokens
        ))
        committed = fixedText
        committedTokens = fixedSegments.flatMap(\.tokens)
    }

    private func rawConsumption(of candidate: Candidate) -> Int {
        guard inputScheme == .microsoftShuangpin else { return candidate.consumed }
        // Sime returns pinyin units (for example xiao'guo), while each
        // Microsoft Shuangpin syllable was entered with two keyboard keys.
        let syllableCount = candidate.units.split(separator: "'")
            .filter { !$0.isEmpty }
            .count
        return syllableCount > 0 ? syllableCount * 2 : candidate.consumed
    }

    func selectDisplayed(_ index: Int) -> String? {
        if !isComposing, predictionCandidates.indices.contains(index) {
            let prediction = predictionCandidates[index]
            publishPredictions(for: prediction.tokens)
            return prediction.text
        }
        if let active = activeCharacterIndex,
           replacementCandidates.indices.contains(index),
           let top = candidates.first {
            let replacement = replacementCandidates[index]
            let span = max(1, replacement.units.split(separator: "'")
                .filter { !$0.isEmpty }.count)
            let relativeActive = active - fixedText.count
            guard relativeActive >= 0 else { return nil }

            // Materialize the selected prefix and consume exactly its source
            // syllables. Subsequent input can therefore only decode the raw
            // suffix; it cannot retranslate this user anchor.
            let fixed = String(Array(sentencePreview).prefix(active))
            let consumed = rawLength(forSyllables: relativeActive + span,
                                     units: top.units)
            guard consumed > 0 else { return nil }
            appendFixedSegment(
                text: String(fixed.dropFirst(fixedText.count)) + replacement.text,
                keyCount: consumed,
                syllableCount: relativeActive + span,
                tokens: replacement.tokens
            )
            raw.removeFirst(min(consumed, raw.count))
            cursor = max(0, cursor - consumed)
            activeCharacterIndex = nil
            replacementCandidates = []
            refresh()
            if !raw.isEmpty {
                activateCharacter(fixedText.count)
            }
            return nil
        }
        return select(index)
    }

    func activateCharacter(_ index: Int) {
        let sentence = sentencePreview
        guard Array(sentence).indices.contains(index),
              let top = candidates.first else { return }
        let syllables = top.units.split(separator: "'").map(String.init)
        let relativeIndex = index - fixedText.count
        guard syllables.indices.contains(relativeIndex) else { return }
        activeCharacterIndex = index
        // Sime owns both normal correction layers: full constrained suffix
        // paths first, then short/character alternatives at this syllable.
        // Swift neither filters complete paths nor appends a separate table.
        let fixedPrefix = String(Array(top.text).prefix(relativeIndex))
        replacementCandidates = decoder.correctionCandidates(
            top.units,
            fixedPrefix: fixedPrefix,
            prefixSyllables: relativeIndex,
            limit: 60
        )
    }

    func commitBestOrRaw() -> String? {
        // Space on a mobile keyboard commits the top *sentence* candidate.
        // Do not retain a decoder's partial-consumption tail here: this UI
        // does not yet expose segmented selection, and retaining it caused
        // the final pinyin letter to remain in composition.
        if let candidate = candidates.first {
            let result = fixedText + candidate.text
            publishPredictions(for: committedTokens + candidate.tokens)
            clearComposition()
            return result
        }
        guard isComposing else { return nil }
        let result = preedit
        predictionCandidates = []
        clearComposition()
        return result
    }

    /// Commits the currently marked input without decoding its remaining pinyin.
    /// A prior explicit candidate selection remains part of the preedit, while
    /// the unconverted portion is inserted literally as English text.
    func commitPreeditLiterally() -> String? {
        guard isComposing else { return nil }
        let result = preedit
        predictionCandidates = []
        clearComposition()
        return result
    }

    private func publishPredictions(for tokens: [UInt32]) {
        guard !tokens.isEmpty else {
            predictionCandidates = []
            return
        }
        contextTokens = Array(((hostContextTokens ?? contextTokens) + tokens).suffix(32))
        predictionCandidates = decoder.predict(contextTokens, limit: 9)
    }

    private func clearComposition() {
        raw = ""
        committed = ""
        committedTokens = []
        fixedSegments = []
        cursor = 0
        candidates = []
        activeCharacterIndex = nil
        replacementCandidates = []
    }

    private func refresh() {
        // Keep the full first-syllable character set reachable during normal
        // input too; otherwise low-frequency characters cannot be selected
        // before continuing with the remaining syllables.
        let input = inputScheme == .microsoftShuangpin
            ? MicrosoftShuangpin.expand(raw) : raw
        candidates = input.isEmpty ? [] : decoder.decode(
            input,
            context: hostContextTokens ?? contextTokens,
            limit: 60
        )
    }
}
