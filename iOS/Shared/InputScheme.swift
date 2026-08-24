import Foundation

enum InputScheme: String {
    case fullPinyin
    case microsoftShuangpin
}

enum MicrosoftShuangpin {
    private static let initials: [Character: String] = ["v": "zh", "i": "ch", "u": "sh"]
    private static let finals: [Character: String] = [
        "a": "a", "o": "o", "e": "e", "i": "i", "u": "u", "v": "ü",
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
            let initial = initials[keys[index]] ?? String(keys[index])
            let final = finals[keys[index + 1]] ?? String(keys[index + 1])
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
