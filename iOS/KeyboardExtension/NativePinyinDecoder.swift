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
        decode(pinyin, context: [], limit: limit)
    }

    func exactCandidates(_ pinyin: String, limit: Int) -> [Candidate] {
        guard let handle, !pinyin.isEmpty, limit > 0 else { return [] }
        var results = sime_decode_str(handle, pinyin, Int32(limit))
        defer { sime_free_results(&results) }
        return unpack(results)
    }

    func correctionCandidates(_ pinyin: String, fixedPrefix: String,
                              prefixSyllables: Int, limit: Int) -> [Candidate] {
        correctionCandidates(pinyin, fixedPrefix: fixedPrefix,
                             prefixSyllables: prefixSyllables, limit: limit,
                             expansion: true)
    }

    func correctionCandidates(_ pinyin: String, fixedPrefix: String,
                              prefixSyllables: Int, limit: Int,
                              expansion: Bool) -> [Candidate] {
        guard let handle, !pinyin.isEmpty, prefixSyllables >= 0, limit > 0 else { return [] }
        var results = sime_decode_correction(
            handle, pinyin, fixedPrefix, Int32(prefixSyllables), Int32(limit),
            expansion
        )
        defer { sime_free_results(&results) }
        return unpack(results)
    }

    func tokenize(_ text: String) -> [UInt32] {
        guard let handle, !text.isEmpty else { return [] }
        var tokens = sime_tokenize_text(handle, text)
        defer { sime_free_tokens(&tokens) }
        guard tokens.count > 0, let items = tokens.items else { return [] }
        return (0..<Int(tokens.count)).map { items[$0] }
    }

    func syllableCandidates(_ pinyin: String) -> [Candidate] {
        exactCandidates(pinyin, limit: 60)
    }

    func predict(_ context: [UInt32], limit: Int) -> [Candidate] {
        guard let handle, !context.isEmpty, limit > 0 else { return [] }
        var results = context.withUnsafeBufferPointer { buffer in
            sime_next_tokens(handle, buffer.baseAddress, Int32(context.count), Int32(limit))
        }
        defer { sime_free_results(&results) }
        return unpack(results)
    }

    func decode(_ pinyin: String, context: [UInt32], limit: Int) -> [Candidate] {
        decode(pinyin, context: context, limit: limit, expansion: true)
    }

    func decode(_ pinyin: String, context: [UInt32], limit: Int,
                expansion: Bool) -> [Candidate] {
        guard let handle, !pinyin.isEmpty else { return [] }
        var sentence = context.withUnsafeBufferPointer { buffer in
            context.isEmpty
                ? sime_decode_sentence(handle, pinyin, 2, expansion)
                : sime_decode_sentence_with_context(
                    handle, pinyin, buffer.baseAddress, Int32(context.count), 2,
                    expansion)
        }
        defer { sime_free_results(&sentence) }
        var results = unpack(sentence)
        // Reserve candidate capacity for complete first-syllable character
        // alternatives rather than letting whole-input words consume it all.
        var words = sime_decode_str(handle, pinyin, Int32(min(limit, 5)))
        defer { sime_free_results(&words) }
        for item in unpack(words) where !results.contains(where: { $0.text == item.text && $0.consumed == item.consumed }) {
            results.append(item)
        }
        // A phrase decode only yields whole-phrase paths. Add short word
        // alternatives for both ends, so "nihao" also exposes 你/呢 and 好/号.
        if let units = results.first?.units {
            let syllables = units.split(separator: "'").map(String.init)
            var ends: [String] = []
            if let first = syllables.first { ends.append(first) }
            if let last = syllables.last, last != syllables.first { ends.append(last) }
            for syllable in ends where !syllable.isEmpty {
                var syllableResults = sime_decode_str(handle, syllable, Int32(limit))
                defer { sime_free_results(&syllableResults) }
                for item in unpack(syllableResults)
                    where !results.contains(where: { $0.text == item.text && $0.consumed == item.consumed }) {
                    results.append(item)
                }
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
            return Candidate(
                text: String(cString: text),
                consumed: Int(item.consumed),
                tokens: tokens,
                units: units,
                score: Double(item.score)
            )
        }
    }
}
