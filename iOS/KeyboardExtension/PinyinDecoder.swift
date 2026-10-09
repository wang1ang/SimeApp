import Foundation

struct Candidate {
    let text: String
    let consumed: Int
    let tokens: [UInt32]
    let units: String
    /// Optional decoder-supplied source spans aligned with `segmentChars`.
    /// Shuangpin index decoders provide them; other decoders may use `units`.
    let segmentKeys: [Int]
    /// Display-character widths aligned 1:1 with `segmentKeys`.
    let segmentChars: [Int]
    /// Sime's log score, retained so correction can prune weak lattice paths.
    let score: Double
    /// A literal, case-preserved English candidate (the raw typed string).
    /// It carries no pinyin units or LM tokens and commits through the same
    /// segment path as a Chinese word.
    let isEnglish: Bool

    init(text: String, consumed: Int, tokens: [UInt32], units: String = "",
         segmentKeys: [Int] = [], segmentChars: [Int] = [],
         score: Double = 0, isEnglish: Bool = false) {
        self.text = text
        self.consumed = consumed
        self.tokens = tokens
        self.units = units
        self.segmentKeys = segmentKeys
        self.segmentChars = segmentChars
        self.score = score
        self.isEnglish = isEnglish
    }
}

/// Keep the keyboard UI independent from the native Sime bridge.
protocol PinyinDecoder {
    /// Index binding expected by the scheme, if this decoder has one.
    var shuangpinIndexName: String? { get }
    /// True for the native Sime engine; false for the builtin fallback. The
    /// controller swaps to the native engine once loaded.
    var isNative: Bool { get }
    func decode(_ pinyin: String, limit: Int) -> [Candidate]
    func decode(_ pinyin: String, context: [UInt32], limit: Int) -> [Candidate]
    func decode(_ pinyin: String, context: [UInt32], limit: Int,
                expansion: Bool) -> [Candidate]
    /// High-recall candidates for one exact pinyin span, used to recover the
    /// token path for a fixed correction prefix.
    func exactCandidates(_ pinyin: String, limit: Int) -> [Candidate]
    func correctionCandidates(_ pinyin: String, fixedPrefix: String,
                              prefixSyllables: Int, limit: Int) -> [Candidate]
    func correctionCandidates(_ pinyin: String, fixedPrefix: String,
                              prefixSyllables: Int, limit: Int,
                              expansion: Bool) -> [Candidate]
    func tokenize(_ text: String) -> [UInt32]
    func syllableCandidates(_ pinyin: String) -> [Candidate]
    func predict(_ context: [UInt32], limit: Int) -> [Candidate]
    /// Association (联想): next-word prediction merged with completion of
    /// the trailing context token. Each candidate's `consumed` is the number
    /// of leading characters of `text` already in the document (0 for
    /// next-word), so callers insert `text` with the first `consumed`
    /// characters dropped.
    func associate(_ context: [UInt32], limit: Int) -> [Candidate]
}

extension PinyinDecoder {
    var shuangpinIndexName: String? { nil }
    var hasShuangpinIndex: Bool { shuangpinIndexName != nil }
    var isNative: Bool { false }

    func decode(_ pinyin: String, context: [UInt32], limit: Int) -> [Candidate] {
        decode(pinyin, limit: limit)
    }

    // Abbreviation/tail expansion is a full-pinyin convenience; default to it
    // so existing callers keep their behavior. Shuangpin passes false.
    func decode(_ pinyin: String, context: [UInt32], limit: Int,
                expansion: Bool) -> [Candidate] {
        decode(pinyin, context: context, limit: limit)
    }

    func exactCandidates(_ pinyin: String, limit: Int) -> [Candidate] {
        decode(pinyin, limit: limit)
    }

    func correctionCandidates(_ pinyin: String, fixedPrefix: String,
                              prefixSyllables: Int, limit: Int) -> [Candidate] {
        exactCandidates(pinyin, limit: limit)
    }

    func correctionCandidates(_ pinyin: String, fixedPrefix: String,
                              prefixSyllables: Int, limit: Int,
                              expansion: Bool) -> [Candidate] {
        correctionCandidates(pinyin, fixedPrefix: fixedPrefix,
                             prefixSyllables: prefixSyllables, limit: limit)
    }

    func tokenize(_ text: String) -> [UInt32] { [] }

    func syllableCandidates(_ pinyin: String) -> [Candidate] {
        exactCandidates(pinyin, limit: 60)
    }

    func predict(_ context: [UInt32], limit: Int) -> [Candidate] { [] }

    // Default: fall back to plain next-word prediction so decoders that do
    // not implement completion still work.
    func associate(_ context: [UInt32], limit: Int) -> [Candidate] {
        predict(context, limit: limit)
    }

    private func usesIndex(for scheme: InputScheme) -> Bool {
        guard let requested = scheme.shuangpinIndexName else { return false }
        return shuangpinIndexName == requested
    }

    /// Decode the raw composition through the decoder binding selected by the
    /// scheme, preserving the entered casing for mixed-English lookup.
    func decodeComposition(_ raw: String, scheme: InputScheme,
                           context: [UInt32], limit: Int) -> [Candidate] {
        let decoded: [Candidate]
        if usesIndex(for: scheme) {
            decoded = decode(raw, context: context, limit: limit, expansion: true)
        } else if let layout = scheme.shuangpin {
            let keys = Array(raw.lowercased())
            let hasLoneInitial = keys.count % 2 == 1
            var syllables = stride(from: 0, to: keys.count - 1, by: 2).map {
                layout.expand(String(keys[$0..<$0 + 2]))
            }
            if hasLoneInitial, let last = keys.last {
                syllables.append(layout.initial(for: last))
            }
            let expanded = syllables.joined(separator: "'")
            let candidates = decode(expanded, context: context, limit: limit,
                                    expansion: hasLoneInitial)
            let locked = stride(from: 0, to: keys.count - 1, by: 2).map {
                layout.expand(String(keys[$0..<$0 + 2]))
            }
            decoded = candidates.filter { candidate in
                let units = candidate.units.split(separator: "'").map(String.init)
                guard units.count >= 2 else { return true }
                for index in 0..<min(units.count, locked.count) {
                    if units[index] != locked[index] { return false }
                }
                return true
            }
        } else {
            decoded = decode(raw, context: context, limit: limit, expansion: true)
        }

        guard !raw.isEmpty,
              !decoded.contains(where: { $0.text == raw }) else { return decoded }
        return decoded + [Candidate(text: raw, consumed: raw.count,
                                    tokens: [], units: "", isEnglish: true)]
    }

    /// Correction dispatch mirrors decodeComposition: the engine receives raw
    /// keys when indexed, while legacy decoders receive expanded pinyin units.
    func correctionCandidatesForComposition(
        raw: String, top: Candidate, scheme: InputScheme,
        fixedPrefix: String, prefixSegment: Int, rawKeyColumn: Int,
        limit: Int
    ) -> [Candidate] {
        if usesIndex(for: scheme) {
            return correctionCandidates(
                raw, fixedPrefix: fixedPrefix, prefixSyllables: rawKeyColumn,
                limit: limit, expansion: true)
        }
        let expansion = scheme.shuangpin == nil || raw.count % 2 == 1
        let results = correctionCandidates(
            top.units, fixedPrefix: fixedPrefix,
            prefixSyllables: prefixSegment, limit: limit,
            expansion: expansion)
        guard let layout = scheme.shuangpin else { return results }
        let keys = Array(raw)
        var locked: [String] = []
        var offset = 0
        while offset + 1 < keys.count {
            locked.append(layout.expand(String(keys[offset...offset + 1])))
            offset += 2
        }
        return results.filter { candidate in
            let units = candidate.units.split(separator: "'").map(String.init)
            for index in 0..<min(units.count, locked.count) {
                let lockedIndex = prefixSegment + index
                if lockedIndex < locked.count && units[index] != locked[lockedIndex] {
                    return false
                }
            }
            return true
        }
    }

    func pendingShuangpinInitial(raw: String, cursor: Int, scheme: InputScheme,
                                  candidate: Candidate?) -> Character? {
        guard scheme.shuangpin != nil,
              cursor > 0, cursor <= raw.count else { return nil }
        var runStart = 0
        if usesIndex(for: scheme),
           let candidate,
           candidate.segmentKeys.count == candidate.segmentChars.count {
            let text = Array(candidate.text)
            var displayOffset = 0
            var rawOffset = 0
            for (keys, chars) in zip(candidate.segmentKeys,
                                     candidate.segmentChars) {
                let end = min(text.count, displayOffset + chars)
                let range = displayOffset..<end
                if !range.isEmpty && range.allSatisfy({
                    text[$0].isASCII && text[$0].isLetter
                }) {
                    runStart = rawOffset + keys
                }
                displayOffset += chars
                rawOffset += keys
            }
        }
        let keysBeforeCursor = cursor - runStart
        guard keysBeforeCursor > 0, keysBeforeCursor % 2 == 1 else { return nil }
        return raw[raw.index(raw.startIndex, offsetBy: cursor - 1)]
    }

    func isLegalShuangpinSyllable(rawKeys: String, expanded: String,
                                  scheme: InputScheme) -> Bool {
        if usesIndex(for: scheme) {
            return syllableCandidates(rawKeys).contains { candidate in
                candidate.text.contains { !$0.isASCII }
                    && candidate.segmentKeys == [rawKeys.count]
                    && candidate.segmentChars == [1]
            }
        }
        return syllableCandidates(expanded).contains { candidate in
            candidate.units == expanded && candidate.text.contains { !$0.isASCII }
        }
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
