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
    // Sequential selections before `raw` and sparse user corrections inside
    // `raw` use the same source-aligned segment representation. Correction
    // anchors stay sparse so every sentence position remains editable.
    private var prefixSegments: [CompositionSegment] = []
    private var anchorSegments: [CompositionSegment] = []

    init(decoder: PinyinDecoder = BuiltinPinyinDecoder(),
         inputScheme: InputScheme = InputSettings.scheme) {
        self.decoder = decoder
        self.inputScheme = inputScheme
    }

    private var prefixText: String { prefixSegments.map(\.text).joined() }
    private var consumedKeyCount: Int { prefixSegments.last?.sourceKeyRange.upperBound ?? 0 }
    private var consumedSyllableCount: Int { prefixSegments.last?.syllableRange.upperBound ?? 0 }
    var preedit: String { prefixText + raw }
    var selectionLocation: Int {
        prefixText.utf16.count + String(raw.prefix(cursor)).utf16.count
    }
    var isComposing: Bool { !raw.isEmpty || !prefixSegments.isEmpty }
    var sentencePreview: String {
        prefixText + renderedText(candidates.first?.text ?? "")
    }
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
        let rawSyllableIndex = active - prefixText.count
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

    private func renderedText(_ decoded: String) -> String {
        let base = Array(decoded)
        let anchors = anchorSegments.sorted {
            $0.syllableRange.lowerBound < $1.syllableRange.lowerBound
        }
        var output = ""
        var syllable = 0
        var anchorIndex = 0
        while syllable < base.count {
            if anchorIndex < anchors.count,
               anchors[anchorIndex].syllableRange.lowerBound == syllable {
                let anchor = anchors[anchorIndex]
                output += anchor.text
                syllable = anchor.syllableRange.upperBound
                anchorIndex += 1
            } else {
                output.append(base[syllable])
                syllable += 1
            }
        }
        return output
    }

    private func literalTextWithAnchors() -> String {
        guard let units = candidates.first?.units, !anchorSegments.isEmpty else {
            return raw
        }
        let syllables = units.split(separator: "'").map(String.init)
        let groups = enteredKeyGroups(for: syllables)
        guard groups.count == syllables.count else { return raw }
        let anchors = Dictionary(uniqueKeysWithValues: anchorSegments.map {
            ($0.syllableRange.lowerBound, $0)
        })
        var output = ""
        var syllable = 0
        while syllable < groups.count {
            if let anchor = anchors[syllable] {
                output += anchor.text
                syllable = anchor.syllableRange.upperBound
            } else {
                output += groups[syllable]
                syllable += 1
            }
        }
        return output
    }

    private func invalidateAnchorsForSourceEdit(at keyOffset: Int) {
        // An edit inside or before an anchor invalidates its pinyin alignment.
        // Anchors entirely before the edit remain source-aligned.
        anchorSegments.removeAll { $0.sourceKeyRange.upperBound > keyOffset }
    }

    func restore(raw: String, committed: String) {
        guard !raw.isEmpty || !committed.isEmpty else { return }
        self.raw = raw
        self.committed = committed
        if !committed.isEmpty {
            prefixSegments = [CompositionSegment(
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
        if cursor < raw.count {
            invalidateAnchorsForSourceEdit(at: cursor)
        }
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
            prefixSegments = []
            anchorSegments = []
            return
        }
        guard cursor > 0 else { return }
        invalidateAnchorsForSourceEdit(at: cursor - 1)
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
        appendPrefixSegment(
            text: candidate.text,
            keyCount: consumed,
            syllableCount: syllables,
            tokens: candidate.tokens
        )
        raw.removeFirst(min(consumed, raw.count))
        cursor = max(0, cursor - consumed)
        refresh()
        guard raw.isEmpty else { return nil }
        let result = prefixText
        publishPredictions(for: committedTokens)
        clearComposition()
        return result
    }

    private func appendPrefixSegment(text: String, keyCount: Int,
                                     syllableCount: Int, tokens: [UInt32]) {
        guard keyCount > 0, syllableCount > 0 else { return }
        let keyStart = consumedKeyCount
        let syllableStart = consumedSyllableCount
        prefixSegments.append(CompositionSegment(
            sourceKeyRange: keyStart..<(keyStart + keyCount),
            syllableRange: syllableStart..<(syllableStart + syllableCount),
            text: text,
            tokens: tokens
        ))
        committed = prefixText
        committedTokens = prefixSegments.flatMap(\.tokens)
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
            let relativeActive = active - prefixText.count
            let syllables = top.units.split(separator: "'").map(String.init)
            guard relativeActive >= 0,
                  relativeActive + span <= syllables.count else { return nil }

            let keyStart = rawLength(forSyllables: relativeActive,
                                     units: top.units)
            let keyEnd = rawLength(forSyllables: relativeActive + span,
                                   units: top.units)
            guard keyEnd > keyStart else { return nil }
            let selectedRange = relativeActive..<(relativeActive + span)
            anchorSegments.removeAll { $0.syllableRange.overlaps(selectedRange) }
            anchorSegments.append(CompositionSegment(
                sourceKeyRange: keyStart..<keyEnd,
                syllableRange: selectedRange,
                text: replacement.text,
                tokens: replacement.tokens
            ))
            anchorSegments.sort {
                $0.syllableRange.lowerBound < $1.syllableRange.lowerBound
            }
            activeCharacterIndex = nil
            replacementCandidates = []
            refresh()

            let next = selectedRange.upperBound
            if next < syllables.count {
                activateCharacter(prefixText.count + next)
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
        let relativeIndex = index - prefixText.count
        guard syllables.indices.contains(relativeIndex) else { return }
        activeCharacterIndex = index
        let current = renderedText(top.text)
        let fixedPrefix = String(Array(current).prefix(relativeIndex))
        let nextAnchor = anchorSegments
            .map(\.syllableRange.lowerBound)
            .filter { $0 > relativeIndex }
            .min() ?? syllables.count
        let maximumSpan = max(1, nextAnchor - relativeIndex)
        replacementCandidates = decoder.correctionCandidates(
            top.units,
            fixedPrefix: fixedPrefix,
            prefixSyllables: relativeIndex,
            limit: 60
        ).filter { candidate in
            let span = max(1, candidate.units.split(separator: "'")
                .filter { !$0.isEmpty }.count)
            return span <= maximumSpan
        }
    }

    func commitBestOrRaw() -> String? {
        // Space on a mobile keyboard commits the top *sentence* candidate.
        // Do not retain a decoder's partial-consumption tail here: this UI
        // does not yet expose segmented selection, and retaining it caused
        // the final pinyin letter to remain in composition.
        if let candidate = candidates.first {
            let result = prefixText + renderedText(candidate.text)
            if anchorSegments.isEmpty {
                publishPredictions(for: committedTokens + candidate.tokens)
            } else {
                predictionCandidates = []
            }
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
        let result: String
        if !anchorSegments.isEmpty, let candidate = candidates.first {
            // A second-row correction anchors decoded characters inside the
            // sentence, so the user has committed to Chinese. Decode the
            // remaining (non-anchored) syllables via the top candidate
            // instead of emitting their literal keys; the literal escape
            // hatch only applies when no anchor selection is active.
            result = prefixText + renderedText(candidate.text)
        } else {
            result = prefixText + literalTextWithAnchors()
        }
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
        prefixSegments = []
        anchorSegments = []
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
