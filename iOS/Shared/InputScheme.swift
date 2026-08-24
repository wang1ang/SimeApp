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
                // o is the uo key after ordinary initials, but remains the
                // plain o final for b/p/m/f syllables such as bo and mo.
                final = ["b", "p", "m", "f"].contains(initialKey) ? "o" : "uo"
            case "w":
                // w is ia (xia) or ua (gua/hua/kua), depending on initial.
                final = ["g", "k", "h"].contains(initialKey) ? "ua" : "ia"
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
