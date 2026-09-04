import Foundation

enum InputScheme: String, CaseIterable {
    case fullPinyin
    case microsoftShuangpin
    case xiaoheShuangpin
    case ziranmaShuangpin
    case sogouShuangpin

    /// The Shuangpin key layout for this scheme, or nil for full pinyin.
    var shuangpin: ShuangpinLayout? {
        switch self {
        case .fullPinyin: return nil
        case .microsoftShuangpin, .sogouShuangpin: return .microsoft
        case .xiaoheShuangpin: return .xiaohe
        case .ziranmaShuangpin: return .ziranma
        }
    }

    var isShuangpin: Bool { shuangpin != nil }

    /// Only the Microsoft/Sogou layout maps a final onto the `;` key, so only
    /// those schemes surface `;` on the letter page.
    var usesSemicolonKey: Bool {
        switch self {
        case .microsoftShuangpin, .sogouShuangpin: return true
        default: return false
        }
    }

    var displayName: String {
        switch self {
        case .fullPinyin: return "全拼"
        case .microsoftShuangpin: return "微软双拼"
        case .xiaoheShuangpin: return "小鹤双拼"
        case .ziranmaShuangpin: return "自然码"
        case .sogouShuangpin: return "搜狗双拼"
        }
    }
}

/// A data-driven Shuangpin layout. A syllable is two keys: the first selects
/// the initial (声母), the second the final (韵母). Some final keys stand for
/// two finals whose choice depends on the initial (e.g. ia vs ua); those are
/// modeled as ambiguous cases and resolved by shared Chinese phonotactics, so
/// each scheme only supplies its key→final table and zero-initial convention.
struct ShuangpinLayout {
    /// A final key either maps to one fixed final, or to an initial-dependent
    /// pair shared across every scheme.
    enum Final {
        case fixed(String)
        case uoO        // uo / o (bo, po, mo, fo, wo take o)
        case iaUa       // ia / ua
        case iangUang   // iang / uang
        case ongIong    // ong / iong (j/q/x take iong)
        case uiV        // ui / ü (n/l take ü, written v in Sime)
        case ueVe       // ue / üe (n/l take üe, written ve)
        case uaiIng     // uai / ing (g/k/h/zh/ch/sh take uai)
    }

    /// How a zero-initial (无声母) vowel syllable is entered.
    enum Zero {
        case marker(Character)  // leading marker key, e.g. Microsoft 'o': oa/a
        case vowel              // pinyin's own vowel letter, e.g. Xiaohe 爱=ad
    }

    let initials: [Character: String]
    let finals: [Character: Final]
    let zero: Zero

    /// Every key that can be the second (韵母) key of a syllable. Validity is
    /// ultimately decided by decoding the expanded syllable, not by this set.
    static let finalKeyCandidates: Set<Character> = Set("abcdefghijklmnopqrstuvwxyz;")
    var finalKeyCandidates: Set<Character> { Self.finalKeyCandidates }

    // Initial sets that resolve the ambiguous finals. Membership is tested on
    // the expanded initial string ("zh"/"ch"/"sh" included).
    private static let uSet: Set<String> = ["g", "k", "h", "zh", "ch", "sh", "r", "z", "c", "s"]
    private static let iongSet: Set<String> = ["j", "q", "x"]
    private static let nlSet: Set<String> = ["n", "l"]
    private static let oSet: Set<String> = ["b", "p", "m", "f", "w"]
    private static let uaiSet: Set<String> = ["g", "k", "h", "zh", "ch", "sh"]

    /// The initial (声母) a single key stands for on its own: v/i/u map to
    /// zh/ch/sh, every other key is itself. Used for a trailing lone key so a
    /// bare "u" decodes as sh (水) rather than the literal letter (English up).
    func initial(for key: Character) -> String {
        initials[key] ?? String(key)
    }

    private func resolve(_ final: Final, initial: String) -> String {
        switch final {
        case .fixed(let s): return s
        case .uoO: return Self.oSet.contains(initial) ? "o" : "uo"
        case .iaUa: return Self.uSet.contains(initial) ? "ua" : "ia"
        case .iangUang: return Self.uSet.contains(initial) ? "uang" : "iang"
        case .ongIong: return Self.iongSet.contains(initial) ? "iong" : "ong"
        case .uiV: return Self.nlSet.contains(initial) ? "v" : "ui"
        case .ueVe: return Self.nlSet.contains(initial) ? "ve" : "ue"
        case .uaiIng: return Self.uaiSet.contains(initial) ? "uai" : "ing"
        }
    }

    private func syllable(_ k1: Character, _ k2: Character) -> String {
        switch zero {
        case .marker(let m) where k1 == m:
            // Zero-initial via marker (Microsoft: oa/a, oo/o, or/er).
            if k2 == m { return "o" }
            if k2 == "r" { return "er" }
            return resolve(finals[k2] ?? .fixed(String(k2)), initial: "")
        case .vowel where k1 == "a" || k1 == "e" || k1 == "o":
            // Zero-initial via the pinyin's own vowel letter (Xiaohe/Ziranma):
            // aa/a, ee/e, oo/o, and vowel + final key otherwise (爱=ad, 欧=oz).
            if k1 == k2 { return String(k1) }
            if k1 == "e" && k2 == "r" { return "er" }
            return resolve(finals[k2] ?? .fixed(String(k2)), initial: "")
        default:
            let ini = initials[k1] ?? String(k1)
            return ini + resolve(finals[k2] ?? .fixed(String(k2)), initial: ini)
        }
    }

    func expand(_ input: String) -> String {
        let keys = Array(input.lowercased())
        var output = ""
        var index = 0
        while index + 1 < keys.count {
            output += syllable(keys[index], keys[index + 1])
            index += 2
        }
        // A trailing lone key is an incomplete syllable: keep it literal here.
        // Completion of a lone initial (v/i/u -> zh/ch/sh) is done separately
        // via `initial(for:)` where a decode is actually requested.
        if index < keys.count { output.append(keys[index]) }
        return output
    }
}

extension ShuangpinLayout {
    private static let commonInitials: [Character: String] = ["v": "zh", "i": "ch", "u": "sh"]

    /// Microsoft Shuangpin (also Sogou's default): ing on `;`, zero-initial via
    /// the `o` marker.
    static let microsoft = ShuangpinLayout(
        initials: commonInitials,
        finals: [
            "a": .fixed("a"), "e": .fixed("e"), "i": .fixed("i"), "u": .fixed("u"),
            "v": .uiV, "o": .uoO,
            "l": .fixed("ai"), "z": .fixed("ei"), "k": .fixed("ao"), "b": .fixed("ou"),
            "q": .fixed("iu"), "j": .fixed("an"), "f": .fixed("en"), "h": .fixed("ang"),
            "g": .fixed("eng"), "s": .ongIong, "w": .iaUa, "x": .fixed("ie"),
            "c": .fixed("iao"), "m": .fixed("ian"), "n": .fixed("in"),
            "d": .iangUang, ";": .fixed("ing"), "y": .fixed("uai"),
            "r": .fixed("uan"), "p": .fixed("un"), "t": .ueVe
        ],
        zero: .marker("o")
    )

    /// Natural Code (自然码): the same key assignments as Microsoft except ing
    /// moves off `;` onto `y` (sharing with uai, which never collides since
    /// their initials are disjoint), and zero-initials use the vowel letter.
    static let ziranma = ShuangpinLayout(
        initials: commonInitials,
        finals: [
            "a": .fixed("a"), "e": .fixed("e"), "i": .fixed("i"), "u": .fixed("u"),
            "v": .uiV, "o": .uoO,
            "l": .fixed("ai"), "z": .fixed("ei"), "k": .fixed("ao"), "b": .fixed("ou"),
            "q": .fixed("iu"), "j": .fixed("an"), "f": .fixed("en"), "h": .fixed("ang"),
            "g": .fixed("eng"), "s": .ongIong, "w": .iaUa, "x": .fixed("ie"),
            "c": .fixed("iao"), "m": .fixed("ian"), "n": .fixed("in"),
            "d": .iangUang, "y": .uaiIng,
            "r": .fixed("uan"), "p": .fixed("un"), "t": .ueVe
        ],
        zero: .vowel
    )

    /// Xiaohe (小鹤双拼): its own 26-key韵母 layout; zero-initials use the
    /// vowel letter.
    static let xiaohe = ShuangpinLayout(
        initials: commonInitials,
        finals: [
            "a": .fixed("a"), "e": .fixed("e"), "i": .fixed("i"), "u": .fixed("u"),
            "o": .uoO, "v": .uiV,
            "q": .fixed("iu"), "w": .fixed("ei"), "r": .fixed("uan"), "t": .ueVe,
            "y": .fixed("un"), "p": .fixed("ie"),
            "s": .ongIong, "d": .fixed("ai"), "f": .fixed("en"), "g": .fixed("eng"),
            "h": .fixed("ang"), "j": .fixed("an"), "k": .uaiIng, "l": .iangUang,
            "z": .fixed("ou"), "x": .iaUa, "c": .fixed("ao"), "b": .fixed("in"),
            "n": .fixed("iao"), "m": .fixed("ian")
        ],
        zero: .vowel
    )
}

/// Backwards-compatible facade for the Microsoft layout. Retained so existing
/// call sites and tests keep working; new code uses `InputScheme.shuangpin`.
enum MicrosoftShuangpin {
    static let layout = ShuangpinLayout.microsoft
    static func expand(_ input: String) -> String { layout.expand(input) }
    static func initial(for key: Character) -> String { layout.initial(for: key) }
    static let finalKeyCandidates = ShuangpinLayout.finalKeyCandidates
}

enum InputSettings {
    static let appGroup = "group.com.ismantic.sime"
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static var scheme: InputScheme {
        get {
            InputScheme(rawValue: defaults.string(forKey: "inputScheme") ?? "")
                ?? .fullPinyin
        }
        set { defaults.set(newValue.rawValue, forKey: "inputScheme") }
    }

    /// Whether the empty-preedit association bar (联想 / `sime_next_tokens`)
    /// is shown after committing. Defaults to on when unset.
    static var predictionEnabled: Bool {
        get { defaults.object(forKey: "predictionEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "predictionEnabled") }
    }
}
