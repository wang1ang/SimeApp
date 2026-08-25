import Foundation

struct Candidate {
    let text: String
    let consumed: Int
    let tokens: [UInt32]
    let units: String
    /// Sime's log score, retained so correction can prune weak lattice paths.
    let score: Double

    init(text: String, consumed: Int, tokens: [UInt32], units: String = "", score: Double = 0) {
        self.text = text
        self.consumed = consumed
        self.tokens = tokens
        self.units = units
        self.score = score
    }
}

/// Keep the keyboard UI independent from the native Sime bridge.
protocol PinyinDecoder {
    func decode(_ pinyin: String, limit: Int) -> [Candidate]
    func decode(_ pinyin: String, context: [UInt32], limit: Int) -> [Candidate]
    /// High-recall candidates for one exact pinyin span, used to recover the
    /// token path for a fixed correction prefix.
    func exactCandidates(_ pinyin: String, limit: Int) -> [Candidate]
    func correctionCandidates(_ pinyin: String, fixedPrefix: String,
                              prefixSyllables: Int, limit: Int) -> [Candidate]
    func tokenize(_ text: String) -> [UInt32]
    func syllableCandidates(_ pinyin: String) -> [Candidate]
    func predict(_ context: [UInt32], limit: Int) -> [Candidate]
}

extension PinyinDecoder {
    func decode(_ pinyin: String, context: [UInt32], limit: Int) -> [Candidate] {
        decode(pinyin, limit: limit)
    }

    func exactCandidates(_ pinyin: String, limit: Int) -> [Candidate] {
        decode(pinyin, limit: limit)
    }

    func correctionCandidates(_ pinyin: String, fixedPrefix: String,
                              prefixSyllables: Int, limit: Int) -> [Candidate] {
        exactCandidates(pinyin, limit: limit)
    }

    func tokenize(_ text: String) -> [UInt32] { [] }

    func syllableCandidates(_ pinyin: String) -> [Candidate] {
        exactCandidates(pinyin, limit: 60)
    }

    func predict(_ context: [UInt32], limit: Int) -> [Candidate] { [] }
}

/// A small offline fallback so a freshly generated extension is usable before
/// the full Sime model is linked. Replace this with the native Sime adapter.
struct BuiltinPinyinDecoder: PinyinDecoder {
    private let entries: [String: [String]] = [
        "ni": ["你", "呢", "尼"], "hao": ["好", "号", "浩"],
        "nihao": ["你好"], "wo": ["我", "握"], "men": ["们", "门"],
        "womende": ["我们的"], "shi": ["是", "时", "事", "市"],
        "de": ["的", "得", "地"], "zhong": ["中", "种", "重"],
        "guo": ["国", "过", "果"], "zhongguo": ["中国"],
        "ren": ["人", "任", "认"], "min": ["民", "明"],
        "tian": ["天", "田"], "qi": ["气", "其", "起"],
        "tianqi": ["天气"], "xie": ["谢", "些", "写"],
        "xiexie": ["谢谢"], "zai": ["在", "再"], "jian": ["见", "件"],
        "zaijian": ["再见"], "qing": ["请", "情"], "wen": ["问", "文"],
        "qingwen": ["请问"], "ma": ["吗", "妈", "马"],
        "le": ["了", "乐"], "bu": ["不", "步"], "yao": ["要", "药"],
        "keyi": ["可以"], "ke": ["可", "科"], "yi": ["以", "一", "已"],
        "wan": ["万", "完"], "an": ["安", "按"], "wangan": ["晚安"]
    ]

    func decode(_ pinyin: String, limit: Int) -> [Candidate] {
        let normalized = pinyin.lowercased()
        var output: [Candidate] = []
        for end in stride(from: normalized.count, through: 1, by: -1) {
            let prefix = String(normalized.prefix(end))
            guard let texts = entries[prefix] else { continue }
            output += texts.map { Candidate(text: $0, consumed: end, tokens: []) }
        }
        // The production Sime decoder expands unfinished syllables. Preserve
        // that behavior in the small bundled fallback too: typing "y" can
        // already offer 一 / 要 instead of leaving the candidate bar empty.
        if output.isEmpty {
            let matchingKeys = entries.keys
                .filter { $0.hasPrefix(normalized) }
                .sorted {
                    $0.count == $1.count ? $0 < $1 : $0.count < $1.count
                }
            for key in matchingKeys {
                guard let texts = entries[key] else { continue }
                output += texts.map {
                    Candidate(text: $0, consumed: normalized.count, tokens: [])
                }
            }
        }
        return Array(output.prefix(limit))
    }
}

final class Composition {
    /// A fixed decoded prefix. All remaining raw input is decoded after this
    /// boundary; it is the single source of truth for character correction,
    /// rather than a display-only replacement string.
    private struct Anchor {
        let text: String
        let syllableCount: Int
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
    private var anchor: Anchor?

    init(decoder: PinyinDecoder = BuiltinPinyinDecoder(),
         inputScheme: InputScheme = InputSettings.scheme) {
        self.decoder = decoder
        self.inputScheme = inputScheme
    }

    private var anchoredPrefix: String { anchor?.text ?? committed }
    var preedit: String { anchoredPrefix + raw }
    var selectionLocation: Int {
        anchoredPrefix.utf16.count + String(raw.prefix(cursor)).utf16.count
    }
    var isComposing: Bool { !raw.isEmpty || !anchoredPrefix.isEmpty }
    var sentencePreview: String { anchoredPrefix + (candidates.first?.text ?? "") }
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
        let rawSyllableIndex = active - anchoredPrefix.count
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
        committed = anchoredPrefix + candidate.text
        if let anchor {
            self.anchor = Anchor(text: committed,
                                 syllableCount: anchor.syllableCount + candidate.units.split(separator: "'").count)
        }
        committedTokens += candidate.tokens
        raw.removeFirst(min(consumed, raw.count))
        cursor = max(0, cursor - consumed)
        refresh()
        guard raw.isEmpty else { return nil }
        let result = committed
        publishPredictions(for: committedTokens)
        clearComposition()
        return result
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
            let relativeActive = active - anchoredPrefix.count
            guard relativeActive >= 0 else { return nil }

            // Materialize the selected prefix and consume exactly its source
            // syllables. Subsequent input can therefore only decode the raw
            // suffix; it cannot retranslate this user anchor.
            let fixed = String(Array(sentencePreview).prefix(active))
            let consumed = rawLength(forSyllables: relativeActive + span,
                                     units: top.units)
            guard consumed > 0 else { return nil }
            committed = fixed + replacement.text
            anchor = Anchor(text: committed,
                            syllableCount: (anchor?.syllableCount ?? 0) + relativeActive + span)
            raw.removeFirst(min(consumed, raw.count))
            cursor = max(0, cursor - consumed)
            activeCharacterIndex = nil
            replacementCandidates = []
            refresh()
            if !raw.isEmpty {
                activateCharacter(anchoredPrefix.count)
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
        let relativeIndex = index - anchoredPrefix.count
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
            let result = committed + candidate.text
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
        cursor = 0
        candidates = []
        activeCharacterIndex = nil
        replacementCandidates = []
        anchor = nil
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
