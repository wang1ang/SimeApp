import Foundation

enum InputScheme: String, CaseIterable {
    case fullPinyin
    case microsoftShuangpin
    case xiaoheShuangpin
    case ziranmaShuangpin
    case sogouShuangpin

    var isShuangpin: Bool { shuangpinIndexName != nil }

    /// The only layouts that use `;` as a Shuangpin final key.
    var usesSemicolonKey: Bool {
        switch self {
        case .microsoftShuangpin, .sogouShuangpin: return true
        default: return false
        }
    }

    /// The prebuilt decoder index for this scheme; Microsoft and Sogou share one.
    var shuangpinIndexName: String? {
        switch self {
        case .fullPinyin: return nil
        case .microsoftShuangpin, .sogouShuangpin: return "sime.sp"
        case .xiaoheShuangpin: return "sime.xiaohe.sp"
        case .ziranmaShuangpin: return "sime.ziranma.sp"
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

    /// Whether the empty-preedit association bar is shown after committing.
    static var predictionEnabled: Bool {
        get { defaults.object(forKey: "predictionEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "predictionEnabled") }
    }

    /// After a manual per-character correction, re-decode the whole sentence
    /// through the engine under the anchors (default). When off, keep the old
    /// Swift overlay/filter behavior.
    static var reDecodeOnCorrection: Bool {
        get { defaults.object(forKey: "reDecodeOnCorrection") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "reDecodeOnCorrection") }
    }
}
