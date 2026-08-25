import Foundation

struct Candidate {
    let text: String
    let consumed: Int
    let tokens: [UInt32]
    let units: String

    init(text: String, consumed: Int, tokens: [UInt32], units: String = "") {
        self.text = text
        self.consumed = consumed
        self.tokens = tokens
        self.units = units
    }
}

/// Keep the keyboard UI independent from the native Sime bridge.
protocol PinyinDecoder {
    func decode(_ pinyin: String, limit: Int) -> [Candidate]
    func decode(_ pinyin: String, context: [UInt32], limit: Int) -> [Candidate]
    /// High-recall candidates for one exact pinyin span, used to recover the
    /// token path for a fixed correction prefix.
    func exactCandidates(_ pinyin: String, limit: Int) -> [Candidate]
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
    private let decoder: PinyinDecoder
    private let inputScheme: InputScheme
    private(set) var raw = ""
    private(set) var committed = ""
    private(set) var cursor = 0
    private(set) var candidates: [Candidate] = []
    private(set) var activeCharacterIndex: Int?
    private var replacementCandidates: [Candidate] = []
    private var predictionCandidates: [Candidate] = []
    private var contextTokens: [UInt32] = []
    private var committedTokens: [UInt32] = []
    private var overriddenPreview: String?

    init(decoder: PinyinDecoder? = nil, inputScheme: InputScheme = InputSettings.scheme) {
        // The fallback keeps development builds usable if model resources are
        // absent, while release builds use the bundled offline Sime engine.
        self.decoder = decoder ?? NativePinyinDecoder() ?? BuiltinPinyinDecoder()
        self.inputScheme = inputScheme
    }

    var preedit: String { committed + raw }
    var selectionLocation: Int {
        committed.utf16.count + String(raw.prefix(cursor)).utf16.count
    }
    var isComposing: Bool { !raw.isEmpty || !committed.isEmpty }
    var sentencePreview: String { overriddenPreview ?? (committed + (candidates.first?.text ?? "")) }
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
        let rawSyllableIndex = active - committed.count
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

    func append(_ letter: String) {
        let insertion = raw.index(raw.startIndex, offsetBy: cursor)
        raw.insert(contentsOf: letter.lowercased(), at: insertion)
        cursor += letter.count
        predictionCandidates = []
        overriddenPreview = nil
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
        committed += candidate.text
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
           replacementCandidates.indices.contains(index) {
            var chars = Array(sentencePreview)
            guard chars.indices.contains(active) else { return nil }
            let replacement = replacementCandidates[index]
            let consumedSyllables = replacement.units
                .split(separator: "'")
                .filter { !$0.isEmpty }
                .count
            let span = max(1, consumedSyllables)
            let end = min(chars.count, active + span)
            chars.replaceSubrange(active..<end, with: replacement.text)
            overriddenPreview = String(chars)

            // Continue the classic character-by-character correction flow at
            // the first syllable after the replacement, rather than leaving
            // the old candidate set selected at the previous character.
            let next = active + span
            if next < chars.count {
                activateCharacter(next)
            } else {
                activeCharacterIndex = nil
                replacementCandidates = []
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
        guard syllables.indices.contains(index) else { return }
        activeCharacterIndex = index
        // Decode the complete original pinyin span, then retain only paths
        // whose Chinese prefix is exactly what appears before the tap.  This
        // is a lattice constraint, not a next-token guess: 性价比 is a single
        // dictionary token, so decoding just jia'bi with “性” as context loses
        // its path and incorrectly promotes 假币.
        let fixedPrefix = String(Array(sentence).prefix(index))
        let fullPaths = decoder.exactCandidates(top.units, limit: 60)
        replacementCandidates = fullPaths.compactMap { path in
            let pathCharacters = Array(path.text)
            let pathSyllables = path.units.split(separator: "'").map(String.init)
            guard pathCharacters.count > index,
                  pathSyllables.count > index,
                  String(pathCharacters.prefix(index)) == fixedPrefix else {
                return nil
            }
            return Candidate(
                text: String(pathCharacters.dropFirst(index)),
                consumed: path.consumed,
                tokens: path.tokens,
                units: pathSyllables[index...].joined(separator: "'")
            )
        }
    }

    func commitBestOrRaw() -> String? {
        // A character-level replacement owns the final sentence preview.
        // Commit it verbatim rather than falling back to the original top
        // decoder candidate.
        if let overriddenPreview {
            // A manually replaced preview no longer has a trustworthy full
            // token sequence, so do not use the original sentence tokens for
            // prediction context.
            predictionCandidates = []
            clearComposition()
            return overriddenPreview
        }
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
        contextTokens += tokens
        contextTokens = Array(contextTokens.suffix(32))
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
        overriddenPreview = nil
    }

    private func refresh() {
        // Keep the full first-syllable character set reachable during normal
        // input too; otherwise low-frequency characters cannot be selected
        // before continuing with the remaining syllables.
        let input = inputScheme == .microsoftShuangpin
            ? MicrosoftShuangpin.expand(raw) : raw
        candidates = input.isEmpty ? [] : decoder.decode(input, context: contextTokens, limit: 60)
    }
}
