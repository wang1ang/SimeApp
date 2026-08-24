import Foundation

struct Candidate: Equatable {
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
}

extension PinyinDecoder {
    func decode(_ pinyin: String, context: [UInt32], limit: Int) -> [Candidate] {
        decode(pinyin, limit: limit)
    }
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
    private(set) var raw = ""
    private(set) var committed = ""
    private(set) var candidates: [Candidate] = []
    private(set) var activeCharacterIndex: Int?
    private var replacementCandidates: [Candidate] = []
    private var overriddenPreview: String?

    init(decoder: PinyinDecoder? = nil) {
        // The fallback keeps development builds usable if model resources are
        // absent, while release builds use the bundled offline Sime engine.
        self.decoder = decoder ?? NativePinyinDecoder() ?? BuiltinPinyinDecoder()
    }

    var preedit: String { committed + raw }
    var isComposing: Bool { !raw.isEmpty || !committed.isEmpty }
    var sentencePreview: String { overriddenPreview ?? (committed + (candidates.first?.text ?? "")) }
    var displayCandidates: [Candidate] {
        replacementCandidates.isEmpty ? candidates : replacementCandidates
    }

    func append(_ letter: String) {
        raw.append(contentsOf: letter.lowercased())
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
        raw.removeLast()
        refresh()
    }

    func select(_ index: Int) -> String? {
        guard candidates.indices.contains(index) else { return nil }
        let candidate = candidates[index]
        committed += candidate.text
        raw.removeFirst(min(candidate.consumed, raw.count))
        refresh()
        guard raw.isEmpty else { return nil }
        let result = committed
        reset()
        return result
    }

    func selectDisplayed(_ index: Int) -> String? {
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
        // Re-decode the tail from the tapped character, not just its single
        // syllable. This exposes word and phrase candidates at that position.
        let tail = syllables[index...].joined(separator: "'")
        let prefix = syllables[..<index].joined(separator: "'")
        let context = prefix.isEmpty
            ? [] : (decoder.decode(prefix, limit: 1).first?.tokens ?? [])
        // Put high-recall alternatives for the tapped syllable first (删 for
        // shan, for example), then append context-ranked words and phrases.
        let syllableCandidates = decoder.decode(syllables[index], limit: 30)
        let contextualCandidates = decoder.decode(tail, context: context, limit: 18)
        var seen = Set<String>()
        replacementCandidates = (syllableCandidates + contextualCandidates)
            .filter { seen.insert($0.text).inserted }
    }

    func commitBestOrRaw() -> String? {
        // A character-level replacement owns the final sentence preview.
        // Commit it verbatim rather than falling back to the original top
        // decoder candidate.
        if let overriddenPreview {
            reset()
            return overriddenPreview
        }
        // Space on a mobile keyboard commits the top *sentence* candidate.
        // Do not retain a decoder's partial-consumption tail here: this UI
        // does not yet expose segmented selection, and retaining it caused
        // the final pinyin letter to remain in composition.
        if let candidate = candidates.first {
            let result = committed + candidate.text
            reset()
            return result
        }
        guard isComposing else { return nil }
        let result = preedit
        reset()
        return result
    }

    func reset() {
        raw = ""
        committed = ""
        candidates = []
        activeCharacterIndex = nil
        replacementCandidates = []
        overriddenPreview = nil
    }

    private func refresh() {
        candidates = raw.isEmpty ? [] : decoder.decode(raw, limit: 9)
    }
}
