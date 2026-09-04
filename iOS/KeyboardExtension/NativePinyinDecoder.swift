import Foundation

/// Offline decoder backed by the same C++ Sime core as Android and macOS.
final class NativePinyinDecoder: PinyinDecoder {
    private var handle: OpaquePointer?

    // Loading the ~9MB GRU embedding, the two ncnn models, and touching the
    // mmap'd score tables costs hundreds of ms. Doing that on the main thread
    // during keyboard activation freezes touches and makes the layout flash,
    // so build it on a background queue and cache the result for the lifetime
    // of the extension process. All access to the cache below is confined to
    // the main thread.
    private static let loadQueue = DispatchQueue(
        label: "com.ismantic.sime.decoder-load", qos: .userInitiated)
    private static var shared: NativePinyinDecoder?
    private static var loading = false
    private static var waiters: [(NativePinyinDecoder?) -> Void] = []

    /// The already-loaded native decoder, if it finished loading earlier in
    /// this process. Main-thread only.
    static var sharedIfLoaded: NativePinyinDecoder? { shared }

    /// Load (or reuse) the shared native decoder without blocking the main
    /// thread. `completion` runs on the main thread; synchronously when the
    /// decoder is already cached. Main-thread only.
    static func loadShared(_ completion: @escaping (NativePinyinDecoder?) -> Void) {
        if let shared {
            completion(shared)
            return
        }
        waiters.append(completion)
        guard !loading else { return }
        loading = true
        loadQueue.async {
            let decoder = NativePinyinDecoder()
            DispatchQueue.main.async {
                shared = decoder
                loading = false
                let pending = waiters
                waiters.removeAll()
                pending.forEach { $0(decoder) }
            }
        }
    }

    init?(bundle: Bundle = .main) {
        guard let dict = bundle.path(forResource: "sime", ofType: "dict"),
              let cnt = bundle.path(forResource: "sime", ofType: "cnt") else {
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

    /// Release the engine's internal caches to shrink the resident footprint
    /// under memory pressure. Memory-only hint; decode results are unchanged.
    /// Main-thread only, matching the rest of the shared-decoder access.
    func resetCaches() {
        guard let handle else { return }
        sime_reset_caches(handle)
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
        // The n-gram model's most frequent successor of nearly any token is
        // punctuation (，。、！？...), so an unfiltered prediction bar is
        // flooded with punctuation and useful word suggestions never reach
        // the visible slots. Over-fetch, drop punctuation/symbol-only
        // predictions, then keep the top `limit` real words.
        let poolSize = Int32(min(max(limit * 6, limit), 60))
        var results = context.withUnsafeBufferPointer { buffer in
            sime_next_tokens(handle, buffer.baseAddress, Int32(context.count), poolSize)
        }
        defer { sime_free_results(&results) }
        return unpack(results)
            .filter { !Self.isPunctuationOnly($0.text) }
            .prefix(limit)
            .map { $0 }
    }

    /// A prediction whose every character is punctuation, a symbol, or
    /// whitespace carries no lexical value in the association bar.
    private static func isPunctuationOnly(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        return text.unicodeScalars.allSatisfy { scalar in
            CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
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
