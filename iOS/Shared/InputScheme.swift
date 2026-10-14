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

/// Keyboard writes use local defaults because App Group writes do not persist
/// without Full Access; reads choose the newest value across both stores.
enum SettingsWriter {
    case app
    case keyboard
}

struct SchemeStore {
    let shared: UserDefaults
    let local: UserDefaults

    private static let schemeKey = "inputScheme"
    private static let lastShuangpinKey = "lastShuangpinScheme"

    var scheme: InputScheme {
        InputScheme(rawValue: newest(Self.schemeKey) ?? "") ?? .fullPinyin
    }

    var lastShuangpinScheme: InputScheme {
        let saved = InputScheme(rawValue: newest(Self.lastShuangpinKey) ?? "")
        return (saved?.isShuangpin == true) ? saved! : .microsoftShuangpin
    }

    func setScheme(_ scheme: InputScheme, by writer: SettingsWriter, at time: Date = Date()) {
        write(scheme.rawValue, key: Self.schemeKey, by: writer, at: time)
        if scheme.isShuangpin { setLastShuangpinScheme(scheme, by: writer, at: time) }
    }

    func setLastShuangpinScheme(_ scheme: InputScheme, by writer: SettingsWriter,
                                at time: Date = Date()) {
        guard scheme.isShuangpin else { return }
        write(scheme.rawValue, key: Self.lastShuangpinKey, by: writer, at: time)
    }

    private func write(_ value: String, key: String, by writer: SettingsWriter, at time: Date) {
        let defaults = writer == .app ? shared : local
        defaults.set(value, forKey: key)
        defaults.set(time.timeIntervalSince1970, forKey: key + ".updatedAt")
    }

    // Pre-migration shared values have no timestamp and remain valid until overwritten.
    private func newest(_ key: String) -> String? {
        let sharedValue = shared.string(forKey: key)
        guard let localValue = local.string(forKey: key) else { return sharedValue }
        guard sharedValue != nil else { return localValue }
        let stamp = key + ".updatedAt"
        return local.double(forKey: stamp) > shared.double(forKey: stamp) ? localValue : sharedValue
    }
}

enum InputSettings {
    static let appGroup = "group.com.ismantic.sime"
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }
    private static var schemeStore: SchemeStore {
        SchemeStore(shared: defaults, local: .standard)
    }

    static var scheme: InputScheme { schemeStore.scheme }

    static func setScheme(_ scheme: InputScheme, by writer: SettingsWriter) {
        schemeStore.setScheme(scheme, by: writer)
    }

    /// The most recently used Shuangpin scheme, restored when the in-keyboard
    /// 全拼/双拼 toggle flips back to 双拼 (which cannot name a specific one).
    static var lastShuangpinScheme: InputScheme { schemeStore.lastShuangpinScheme }

    static func setLastShuangpinScheme(_ scheme: InputScheme, by writer: SettingsWriter) {
        schemeStore.setLastShuangpinScheme(scheme, by: writer)
    }

    /// Whether the empty-preedit association bar is shown after committing.
    static var predictionEnabled: Bool {
        get { defaults.object(forKey: "predictionEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "predictionEnabled") }
    }

    /// Re-decode the sentence under the anchors after a correction (default);
    /// off keeps the old Swift overlay/filter.
    static var reDecodeOnCorrection: Bool {
        get { defaults.object(forKey: "reDecodeOnCorrection") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "reDecodeOnCorrection") }
    }
}
