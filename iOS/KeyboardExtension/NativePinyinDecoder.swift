import Foundation

/// Offline decoder backed by the same C++ Sime core as Android and macOS.
final class NativePinyinDecoder: PinyinDecoder {
    private var handle: OpaquePointer?

    init?() {
        guard let dict = Bundle.main.path(forResource: "sime", ofType: "dict"),
              let cnt = Bundle.main.path(forResource: "sime", ofType: "cnt") else {
            return nil
        }
        let created = sime_create(dict, cnt)
        guard sime_ready(created) else {
            if let created { sime_destroy(created) }
            return nil
        }
        handle = created
    }

    deinit {
        if let handle { sime_destroy(handle) }
    }

    func decode(_ pinyin: String, limit: Int) -> [Candidate] {
        guard let handle, !pinyin.isEmpty else { return [] }
        var sentence = sime_decode_sentence(handle, pinyin, 2)
        defer { sime_free_results(&sentence) }
        var results = unpack(sentence)
        var words = sime_decode_str(handle, pinyin, Int32(min(limit, 3)))
        defer { sime_free_results(&words) }
        for item in unpack(words) where !results.contains(where: { $0.text == item.text && $0.consumed == item.consumed }) {
            results.append(item)
        }
        // Also offer alternatives for the first syllable. DecodeStr over a
        // whole phrase (for example "nihao") only returns whole-phrase
        // paths, whereas mobile IMEs also expose "你 / 尼 / 呢" for "ni".
        if let units = results.first?.units,
           let firstSyllable = units.split(separator: "'").first,
           !firstSyllable.isEmpty {
            var syllableResults = sime_decode_str(handle, String(firstSyllable), Int32(limit))
            defer { sime_free_results(&syllableResults) }
            for item in unpack(syllableResults)
                where !results.contains(where: { $0.text == item.text && $0.consumed == item.consumed }) {
                results.append(item)
            }
        }
        return Array(results.prefix(limit))
    }

    private func unpack(_ results: SimeResults) -> [Candidate] {
        guard results.count > 0, let items = results.items else { return [] }
        return (0..<Int(results.count)).compactMap { index in
            let item = items[index]
            guard let text = item.text else { return nil }
            let tokens: [UInt32] = item.token_count > 0 && item.tokens != nil
                ? (0..<Int(item.token_count)).map { item.tokens![$0] } : []
            let units = item.units.map { String(cString: $0) } ?? ""
            return Candidate(text: String(cString: text), consumed: Int(item.consumed), tokens: tokens, units: units)
        }
    }
}
