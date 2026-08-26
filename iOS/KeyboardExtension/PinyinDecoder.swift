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
}

extension PinyinDecoder {
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
