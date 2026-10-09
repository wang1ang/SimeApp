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
    // One shared instance per binding: the full-pinyin engine and the
    // shuangpin-index engine are distinct `Sime` objects (a single instance is
    // bound to one path at creation). They are memory-cheap to keep both: the
    // dict, cnt, and GRU embedding are mmap'd read-only from the same files, so
    // the OS shares those physical pages; only the tiny ncnn nets and per-engine
    // decode caches duplicate.
    private static var shared: [Bool: NativePinyinDecoder] = [:]
    private static var loading: Set<Bool> = []
    private static var waiters: [Bool: [(NativePinyinDecoder?) -> Void]] = [:]

    /// Whether this decoder is bound to the shuangpin index (raw-key path).
    let usesShuangpinIndex: Bool

    var hasShuangpinIndex: Bool { usesShuangpinIndex }
    var isNative: Bool { true }

    /// The already-loaded native decoder for the given binding, if it finished
    /// loading earlier in this process. Main-thread only.
    static func sharedIfLoaded(index: Bool = false) -> NativePinyinDecoder? {
        shared[index]
    }

    /// Release every loaded engine's caches under memory pressure. Main-thread
    /// only, matching the rest of the shared-decoder access.
    static func resetAllCaches() {
        shared.values.forEach { $0.resetCaches() }
    }

    /// Load (or reuse) a shared native decoder without blocking the main
    /// thread. `index` selects the shuangpin-index binding. `completion` runs on
    /// the main thread; synchronously when the decoder is already cached.
    /// Main-thread only.
    static func loadShared(index: Bool = false,
                           _ completion: @escaping (NativePinyinDecoder?) -> Void) {
        if let decoder = shared[index] {
            completion(decoder)
            return
        }
        waiters[index, default: []].append(completion)
        guard !loading.contains(index) else { return }
        loading.insert(index)
        loadQueue.async {
            let decoder = NativePinyinDecoder(useShuangpinIndex: index)
            DispatchQueue.main.async {
                shared[index] = decoder
                loading.remove(index)
                let pending = waiters[index] ?? []
                waiters[index] = nil
                pending.forEach { $0(decoder) }
            }
        }
    }

    init?(bundle: Bundle = .main, useShuangpinIndex: Bool = false) {
        guard let dict = bundle.path(forResource: "sime", ofType: "dict"),
              let cnt = bundle.path(forResource: "sime", ofType: "cnt") else {
            return nil
        }
        // The shuangpin index binds the engine to the raw-key path. Its absence
        // from the bundle is fatal for this binding (the caller falls back to
        // the full-pinyin decoder), so require it when requested.
        var spIndex: String?
        if useShuangpinIndex {
            guard let path = bundle.path(forResource: "sime.sp",
                                         ofType: "index") else {
                return nil
            }
            spIndex = path
        }
        let created = sime_create(dict, cnt, spIndex)
        guard sime_ready(created) else {
            if let created { sime_destroy(created) }
            return nil
        }
        handle = created
        usesShuangpinIndex = useShuangpinIndex
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

    func associate(_ context: [UInt32], limit: Int) -> [Candidate] {
        guard let handle, !context.isEmpty, limit > 0 else { return [] }
        var results = context.withUnsafeBufferPointer { buffer in
            sime_associate(handle, buffer.baseAddress, Int32(context.count), Int32(limit))
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
        // The shuangpin-index path re-feeds raw key spans (two keys per
        // syllable); the full-pinyin path re-feeds its pinyin units.
        for syllable in endSyllables(of: results.first, rawInput: pinyin)
        where !syllable.isEmpty {
            var syllableResults = sime_decode_str(handle, syllable, Int32(limit))
            defer { sime_free_results(&syllableResults) }
            for item in unpack(syllableResults)
                where !results.contains(where: { $0.text == item.text && $0.consumed == item.consumed }) {
                results.append(item)
            }
        }
        return Array(results.prefix(limit))
    }

    /// The first and last segment spans of the top candidate, re-queried for
    /// single-character alternatives. On the index path these are raw key spans
    /// from `segmentKeys` (no two-key assumption); on the full-pinyin path they
    /// are the pinyin units split on the apostrophe.
    private func endSyllables(of top: Candidate?, rawInput: String) -> [String] {
        guard let top else { return [] }
        if usesShuangpinIndex {
            let keys = Array(rawInput)
            let spans = top.segmentKeys
            guard !spans.isEmpty else { return [] }
            // Prefix sums give each segment's [start, end) in raw keys.
            var starts: [Int] = []
            var acc = 0
            for span in spans { starts.append(acc); acc += span }
            func slice(_ segment: Int) -> String? {
                guard spans.indices.contains(segment) else { return nil }
                let start = starts[segment]
                let end = start + spans[segment]
                guard start < end, end <= keys.count else { return nil }
                return String(keys[start..<end])
            }
            var ends: [String] = []
            if let first = slice(0) { ends.append(first) }
            if spans.count > 1, let last = slice(spans.count - 1),
               last != ends.first {
                ends.append(last)
            }
            return ends
        }
        let syllables = top.units.split(separator: "'").map(String.init)
        var ends: [String] = []
        if let first = syllables.first { ends.append(first) }
        if let last = syllables.last, last != syllables.first { ends.append(last) }
        return ends
    }

    private func unpack(_ results: SimeResults) -> [Candidate] {
        guard results.count > 0, let items = results.items else { return [] }
        return (0..<Int(results.count)).compactMap { index in
            let item = items[index]
            guard let text = item.text else { return nil }
            let tokens: [UInt32] = item.token_count > 0 && item.tokens != nil
                ? (0..<Int(item.token_count)).map { item.tokens![$0] } : []
            let units = item.units.map { String(cString: $0) } ?? ""
            let segmentKeys: [Int] = item.segment_count > 0 && item.segment_keys != nil
                ? (0..<Int(item.segment_count)).map { Int(item.segment_keys![$0]) } : []
            let segmentChars: [Int] = item.segment_count > 0 && item.segment_chars != nil
                ? (0..<Int(item.segment_count)).map { Int(item.segment_chars![$0]) } : []
            let display = String(cString: text)
            let isEnglish = !display.isEmpty && display.unicodeScalars.allSatisfy {
                $0.isASCII && CharacterSet.letters.contains($0)
            }
            return Candidate(
                text: display,
                consumed: Int(item.consumed),
                tokens: tokens,
                units: units,
                segmentKeys: segmentKeys,
                segmentChars: segmentChars,
                score: Double(item.score),
                isEnglish: isEnglish
            )
        }
    }
}
