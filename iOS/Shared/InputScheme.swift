import Foundation

enum InputScheme: String {
    case fullPinyin
    case microsoftShuangpin
}

enum MicrosoftShuangpin {
    private static let initials: [Character: String] = ["v": "zh", "i": "ch", "u": "sh"]
    private static let finals: [Character: String] = [
        "a": "a", "e": "e", "i": "i", "u": "u", "v": "ü",
        "l": "ai", "z": "ei", "k": "ao", "b": "ou", "q": "iu",
        "j": "an", "f": "en", "h": "ang", "g": "eng", "s": "ong",
        "w": "ia", "x": "ie", "c": "iao", "m": "ian", "n": "in",
        "d": "iang", ";": "ing", "y": "uai", "r": "uan", "p": "un",
        "t": "ue"
    ]

    static func expand(_ input: String) -> String {
        let keys = Array(input.lowercased())
        var output = ""
        var index = 0
        while index + 1 < keys.count {
            let initialKey = keys[index]
            let finalKey = keys[index + 1]
            let initial = initials[initialKey] ?? String(initialKey)
            let final: String
            switch finalKey {
            case "o":
                // o is uo after ordinary initials, but plain o in bo/po/mo/fo.
                final = ["b", "p", "m", "f", "w"].contains(initialKey) ? "o" : "uo"
            case "w":
                // w: ia (xia) / ua (gua, zhua, chua, shua).
                final = ["g", "k", "h", "v", "i", "u", "r", "z", "c", "s"].contains(initialKey)
                    ? "ua" : "ia"
            case "d":
                // d: iang (jiang) / uang (guang, zhuang).
                final = ["g", "k", "h", "v", "i", "u", "r", "z", "c", "s"].contains(initialKey)
                    ? "uang" : "iang"
            case "s":
                // s: ong (song) / iong (jiong, qiong, xiong, yong).
                final = ["j", "q", "x", "y"].contains(initialKey) ? "iong" : "ong"
            case "v":
                // v: ui (gui, zhui) / ü (nü, lü).
                final = ["n", "l"].contains(initialKey) ? "ü" : "ui"
            case "t":
                final = ["j", "q", "x", "y", "n", "l"].contains(initialKey) ? "üe" : "ue"
            case "r":
                final = ["j", "q", "x", "y", "n", "l"].contains(initialKey) ? "üan" : "uan"
            case "p":
                final = ["j", "q", "x", "y", "n", "l"].contains(initialKey) ? "ün" : "un"
            default:
                final = finals[finalKey] ?? String(finalKey)
            }
            output += initial + final
            index += 2
        }
        if index < keys.count { output.append(keys[index]) }
        return output
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
}
