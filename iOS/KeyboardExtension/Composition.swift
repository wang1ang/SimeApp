import Foundation

final class Composition {
    /// One correction anchor: pinned output text aligned to the raw keys and
    /// syllable positions it covers. Usually one syllable; a multi-syllable
    /// word anchor spans several.
    private struct CompositionSegment {
        let sourceKeyRange: Range<Int>
        let syllableRange: Range<Int>
        let text: String
        let tokens: [UInt32]
    }

    private let decoder: PinyinDecoder
    private let inputScheme: InputScheme
    private(set) var raw = ""
    private(set) var cursor = 0
    private(set) var candidates: [Candidate] = []
    private(set) var activeCharacterIndex: Int?
    // A first tap only highlights the character (color change) and lists its
    // replacement candidates; the literal typed keys are revealed on the
    // second tap of the same character. This flag tracks that second stage.
    private(set) var activeShowsKeys: Bool = false
    private var replacementCandidates: [Candidate] = []
    private var predictionCandidates: [Candidate] = []
    /// Shown instead of association while the host text ends in arithmetic.
    private(set) var calculatorSuggestion: CalculatorSuggestion?
    private var contextTokens: [UInt32] = []
    // Text a backspace left after `contextTokens` that is no token; it offers
    // word completions until picked or settled.
    private var contextFragment = ""
    // Sparse user corrections inside `raw`. There is no in-composition prefix:
    // a selection pins its span here and the whole input stays editable; the
    // only "prefix" is already-committed host text, carried as context.
    private var anchorSegments: [CompositionSegment] = []

    /// Exposed so the controller can tell whether the active composition already
    /// runs on a native engine with the binding the current scheme wants.
    var decoderIsNative: Bool { decoder.isNative }
    var decoderIndexName: String? { decoder.shuangpinIndexName }


    init(decoder: PinyinDecoder = BuiltinPinyinDecoder(),
         inputScheme: InputScheme = InputSettings.scheme) {
        self.decoder = decoder
        self.inputScheme = inputScheme
    }

    /// When false, the empty-preedit association bar (联想) is suppressed.
    /// Refreshed by the keyboard from `InputSettings.predictionEnabled`.
    var predictionEnabled: Bool = InputSettings.predictionEnabled {
        didSet {
            if !predictionEnabled {
                predictionCandidates = []
                calculatorSuggestion = nil
            }
        }
    }

    /// Re-decode the whole sentence under the anchors on correction (default);
    /// off keeps the Swift overlay. Set by the keyboard from InputSettings.
    var reDecodeOnCorrection: Bool = InputSettings.reDecodeOnCorrection
    /// Set when the last refresh fed anchors to the engine, so the Swift
    /// overlay/filter stands down (candidates are already anchor-consistent).
    private var usingEngineAnchors = false

    private static let syllableSeparator = " "
    // Display-only grouping of `raw`, aligned 1:1 with the top candidate's
    // characters (first row). Computed in `refresh()`; never affects how many
    // keys a commit consumes.
    private var displayGroups: [String] = []
    private var rawSyllableGroups: [String] {
        displayGroups.isEmpty && !raw.isEmpty ? [raw] : displayGroups
    }
    private var groupedRaw: String {
        rawSyllableGroups.joined(separator: Self.syllableSeparator)
    }
    var preedit: String { groupedRaw }
    /// The displayed preedit up to the composition cursor. Callers strip this
    /// from the host context so the marked, grouped pinyin never becomes model
    /// input.
    var markedPrefix: String {
        var out = ""
        var rawSeen = 0
        for (index, group) in rawSyllableGroups.enumerated() {
            guard rawSeen < cursor else { break }
            if index > 0 { out += Self.syllableSeparator }
            out += String(group.prefix(cursor - rawSeen))
            rawSeen += group.count
        }
        return out
    }
    var selectionLocation: Int { markedPrefix.utf16.count }
    var isComposing: Bool { !raw.isEmpty }
    var languageModelContext: [UInt32] { Array(contextTokens.suffix(32)) }
    var debugContextText: String {
        decoder.describeContext(languageModelContext)
    }
    var sentencePreview: String {
        renderedText(candidates.first?.text ?? "")
    }

    struct SentenceSegment {
        let text: String
        let displayIndex: Int
        /// English follows English, so a space separates them.
        let spacedBefore: Bool
    }

    private struct SentenceMapping {
        let segments: [SentenceSegment]
        let unitRanges: [Range<Int>]
        /// Every pair of adjacent English words is spaced, as in the marked text.
        var spacedText: String {
            segments.map { ($0.spacedBefore ? " " : "") + $0.text }.joined()
        }

        init(text: String, segmentChars: [Int], anchors: [CompositionSegment] = []) {
            let chars = Array(text)
            var segments: [SentenceSegment] = []
            var ranges = Array(repeating: 0..<0, count: segmentChars.count)
            var display = 0
            var unit = 0
            let anchorsByStart = Dictionary(
                anchors.map { ($0.syllableRange.lowerBound, $0) },
                uniquingKeysWith: { first, _ in first })
            // Per-segment character span for the segment at `index`, clamped.
            func span(_ index: Int, from offset: Int) -> Range<Int> {
                let count = max(1, segmentChars[index])
                return offset..<min(chars.count, offset + count)
            }
            func isEnglish(_ range: Range<Int>) -> Bool {
                !range.isEmpty && range.allSatisfy {
                    chars[$0].isASCII && chars[$0].isLetter
                }
            }
            var endsEnglish = false
            func append(_ range: Range<Int>) {
                let startsEnglish = isEnglish(range.prefix(1))
                segments.append(SentenceSegment(
                    text: String(chars[range]), displayIndex: range.lowerBound,
                    spacedBefore: endsEnglish && startsEnglish))
                endsEnglish = isEnglish(range.suffix(1))
            }
            while unit < segmentChars.count && display < chars.count {
                if let anchor = anchorsByStart[unit],
                   anchor.syllableRange.upperBound <= segmentChars.count {
                    let start = display
                    let end = min(chars.count, start + anchor.text.count)
                    let range = start..<end
                    for anchoredUnit in anchor.syllableRange {
                        if ranges.indices.contains(anchoredUnit) {
                            ranges[anchoredUnit] = range
                        }
                    }
                    append(range)
                    display = end
                    unit = anchor.syllableRange.upperBound
                    continue
                }
                let range = span(unit, from: display)
                ranges[unit] = range
                display = range.upperBound
                unit += 1
                append(range)
            }
            self.segments = segments
            self.unitRanges = ranges
        }
    }

    var sentenceSegments: [SentenceSegment] {
        sentenceMapping.segments
    }

    private var sentenceMapping: SentenceMapping {
        sentenceMapping(of: candidates.first)
    }

    private func sentenceMapping(of candidate: Candidate?) -> SentenceMapping {
        SentenceMapping(text: renderedText(candidate?.text ?? ""),
                        segmentChars: segmentCharCounts(candidate),
                        anchors: usingEngineAnchors ? anchorsAlignedToTop() : anchorSegments)
    }

    /// A candidate as listed: adjacent English words spaced as in the first row.
    func displayText(of candidate: Candidate) -> String {
        spacedText(SentenceMapping(text: candidate.text,
                                   segmentChars: segmentCharCounts(candidate)),
                   plain: candidate.text)
    }

    /// Commit what the first row shows, anchors included.
    private func committedText(of candidate: Candidate) -> String {
        spacedText(sentenceMapping(of: candidate), plain: renderedText(candidate.text))
    }

    /// Falls back to the plain text if the mapping drops any of it.
    private func spacedText(_ mapping: SentenceMapping, plain: String) -> String {
        let shown = mapping.spacedText
        return shown.filter { $0 != " " } == plain ? shown : plain
    }

    /// Re-map anchors onto the current top candidate's segmentation by their
    /// key ranges (the anchors' own `syllableRange` drifts once the engine
    /// re-decodes). Anchors not aligned to a segment boundary are dropped.
    private func anchorsAlignedToTop() -> [CompositionSegment] {
        guard let top = candidates.first else { return [] }
        let keyLens = segmentRawLengths(top)
        guard !keyLens.isEmpty else { return [] }
        var segmentAt: [Int: Int] = [:]   // key offset -> segment index
        var acc = 0
        for (i, k) in keyLens.enumerated() { segmentAt[acc] = i; acc += k }
        segmentAt[acc] = keyLens.count
        return anchorSegments.compactMap { anchor in
            guard let lo = segmentAt[anchor.sourceKeyRange.lowerBound],
                  let hi = segmentAt[anchor.sourceKeyRange.upperBound],
                  hi > lo else { return nil }
            return CompositionSegment(sourceKeyRange: anchor.sourceKeyRange,
                                      syllableRange: lo..<hi,
                                      text: anchor.text, tokens: anchor.tokens)
        }
    }

    var displayCandidates: [Candidate] {
        if !replacementCandidates.isEmpty { return replacementCandidates }
        guard !isComposing else { return candidates }
        if let calc = calculatorSuggestion {
            return [Candidate(text: calc.display, consumed: 0, tokens: [])]
        }
        // Association completions carry the full word (e.g. 狐狸) but their
        // leading `consumed` characters are already in the document, so the
        // bar must show only the part that will be inserted (狸) — never the
        // base character again.
        return predictionCandidates.map { candidate in
            let drop = min(candidate.consumed, candidate.text.count)
            guard drop > 0 else { return candidate }
            return Candidate(text: String(candidate.text.dropFirst(drop)),
                             consumed: candidate.consumed,
                             tokens: candidate.tokens,
                             units: candidate.units,
                             segmentKeys: candidate.segmentKeys,
                             segmentChars: candidate.segmentChars,
                             score: candidate.score)
        }
    }

    /// Maps a displayed sentence segment to the first decoder unit it owns.
    /// ASCII runs consume however many units Sime used for that word, while
    /// each Han character consumes one unit. This keeps the mapping generic
    /// for English at the beginning, middle, or end of a sentence.
    private func unitCharacterRanges(text: String, segmentChars: [Int]) -> [Range<Int>] {
        SentenceMapping(text: text, segmentChars: segmentChars).unitRanges
    }

    private func unitIndex(forDisplayIndex index: Int) -> Int {
        let relative = index
        guard relative >= 0, !candidates.isEmpty else { return relative }
        let mapping = sentenceMapping
        guard mapping.segments.contains(where: { $0.displayIndex == index }) else {
            return relative
        }
        return mapping.unitRanges.firstIndex {
            $0.lowerBound <= index && index < $0.upperBound
        } ?? relative
    }

    /// The display-character index where segment `segmentIndex` of the top
    /// candidate begins. A segment can span several characters, so this is not
    /// the segment index itself.
    private func displayIndex(forSegment segmentIndex: Int) -> Int {
        let ranges = sentenceMapping.unitRanges
        guard ranges.indices.contains(segmentIndex) else {
            return segmentIndex
        }
        return ranges[segmentIndex].lowerBound
    }

    /// The literal key sequence entered for the active correction syllable.
    /// Do not use Sime's normalized pinyin units here: a Microsoft Shuangpin
    /// user must see their two-key code, and full-pinyin input must retain
    /// typed separators such as an apostrophe.
    var activeEnteredKeys: String? {
        guard activeShowsKeys,
              let active = activeCharacterIndex,
              let top = candidates.first else { return nil }
        let rawSegmentIndex = unitIndex(forDisplayIndex: active)
        let groups = rawGroups(of: top)
        guard groups.indices.contains(rawSegmentIndex) else { return nil }
        return groups[rawSegmentIndex]
    }

    func shuangpinFinalKeyHighlights() -> Set<Character> {
        decoder.shuangpinFinalKeyHighlights(
            raw: raw, cursor: cursor, scheme: inputScheme, candidate: candidates.first)
    }

    /// Display spans come from the decoder, which can expose characters inside
    /// multi-syllable Han tokens while keeping English words intact.
    private func segmentCharCounts(_ candidate: Candidate?) -> [Int] {
        guard let candidate else { return [] }
        if !candidate.segmentChars.isEmpty { return candidate.segmentChars }
        guard !inputScheme.isShuangpin else { return [] }

        let units = candidate.units.split(separator: "'").map(String.init)
        let text = Array(candidate.text)
        var counts = Array(repeating: 0, count: units.count)
        var display = 0
        var unit = 0
        while display < text.count, unit < units.count {
            if text[display].isASCII && text[display].isLetter {
                let start = display
                while display < text.count,
                      text[display].isASCII && text[display].isLetter {
                    display += 1
                }
                var remaining = display - start
                while unit < units.count, remaining > 0 {
                    let width = min(units[unit].count, remaining)
                    counts[unit] = width
                    remaining -= width
                    unit += 1
                }
            } else {
                counts[unit] = 1
                display += 1
                unit += 1
            }
        }
        return counts
    }

    /// Raw-key spans come from the decoder; full pinyin may derive them from
    /// the decoder's `units` when explicit spans are unavailable.
    private func segmentRawLengths(_ candidate: Candidate?) -> [Int] {
        guard let candidate else { return [] }
        if !candidate.segmentKeys.isEmpty { return candidate.segmentKeys }
        guard !inputScheme.isShuangpin else { return [] }
        let syllables = candidate.units.split(separator: "'").map(String.init)
        return enteredKeyGroups(for: syllables).map(\.count)
    }

    /// Raw-key length consumed by the first `count` segments of `candidate`.
    private func rawLength(forSegments count: Int, of candidate: Candidate?) -> Int {
        guard count > 0 else { return 0 }
        let lengths = segmentRawLengths(candidate)
        guard lengths.count >= count else { return 0 }
        return lengths.prefix(count).reduce(0, +)
    }

    /// The raw keys entered for each segment of `candidate`, sliced from `raw`
    /// by the per-segment lengths. Used for display labels and per-syllable
    /// editing.
    private func rawGroups(of candidate: Candidate?) -> [String] {
        let lengths = segmentRawLengths(candidate)
        let keys = Array(raw)
        var groups: [String] = []
        var cursor = 0
        for length in lengths {
            guard length > 0, cursor + length <= keys.count else { break }
            groups.append(String(keys[cursor..<cursor + length]))
            cursor += length
        }
        return groups
    }

    private func enteredKeyGroups(for syllables: [String]) -> [String] {
        var remaining = Substring(raw)
        var groups: [String] = []
        for syllable in syllables {
            var group = ""
            if remaining.first == "'" {
                group.append("'")
                remaining.removeFirst()
            }
            if remaining.count < syllable.count {
                guard syllable == syllables.last, !remaining.isEmpty else { return [] }
                groups.append(group + remaining)
                remaining.removeAll()
                continue
            }
            group += String(remaining.prefix(syllable.count))
            remaining.removeFirst(syllable.count)
            groups.append(group)
        }
        return groups
    }

    private func renderedText(_ decoded: String) -> String {
        // Engine already produced anchor-consistent text; don't overlay again.
        if usingEngineAnchors { return decoded }
        let ranges = unitCharacterRanges(
            text: decoded, segmentChars: segmentCharCounts(candidates.first))
        let anchorRanges = anchorSegments.compactMap { anchor -> (range: Range<Int>, text: String)? in
            guard ranges.indices.contains(anchor.syllableRange.lowerBound) else { return nil }
            let first = ranges[anchor.syllableRange.lowerBound].lowerBound
            let lastUnit = min(ranges.count - 1, anchor.syllableRange.upperBound - 1)
            return (first..<ranges[lastUnit].upperBound, anchor.text)
        }
        return applyAnchors(to: decoded, ranges: anchorRanges)
    }

    private func literalTextWithAnchors() -> String {
        guard let top = candidates.first, !anchorSegments.isEmpty else { return raw }
        let groups = rawGroups(of: top)
        guard groups.count == segmentRawLengths(top).count, !groups.isEmpty else { return raw }
        let ranges = anchorSegments.map { anchor in
            let start = groups.prefix(anchor.syllableRange.lowerBound).reduce(0) { $0 + $1.count }
            let end = groups.prefix(anchor.syllableRange.upperBound).reduce(0) { $0 + $1.count }
            return (range: start..<end, text: anchor.text)
        }
        return applyAnchors(to: groups.joined(), ranges: ranges)
    }

    private func applyAnchors(to text: String,
                              ranges: [(range: Range<Int>, text: String)]) -> String {
        let chars = Array(text)
        var output = ""
        var position = 0
        for item in ranges.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard item.range.lowerBound >= position,
                  item.range.upperBound <= chars.count else { continue }
            output += String(chars[position..<item.range.lowerBound])
            output += item.text
            position = item.range.upperBound
        }
        output += String(chars[position...])
        return output
    }

    private func invalidateAnchorsForSourceEdit(at keyOffset: Int) {
        // An edit inside or before an anchor invalidates its pinyin alignment.
        // Anchors entirely before the edit remain source-aligned.
        anchorSegments.removeAll { $0.sourceKeyRange.upperBound > keyOffset }
    }

    func restore(raw: String) {
        guard !raw.isEmpty else { return }
        self.raw = raw
        cursor = raw.count
        refresh()
    }

    /// Start a new scheme with the same keys and context; corrections from the
    /// old scheme cannot be mapped to the new scheme's syllable boundaries.
    func reinterpret(from previous: Composition) {
        predictionEnabled = previous.predictionEnabled
        reDecodeOnCorrection = previous.reDecodeOnCorrection
        contextTokens = previous.contextTokens
        contextFragment = previous.contextFragment
        restore(raw: previous.raw)
    }

    func moveCursor(to offset: Int) {
        cursor = min(max(0, offset), raw.count)
    }

    /// Discard the in-progress composition without committing to the host.
    /// Used when the host context shows the marked pinyin no longer belongs to
    /// the focused field, so it isn't re-injected into the wrong field.
    func cancel() {
        clearComposition()
    }

    /// Host text wins over the ledger unless it ends with the ledger's text,
    /// in which case the ledger's own segmentation is kept. Returns whether
    /// the context changed.
    @discardableResult
    func updateHostContext(from text: String) -> Bool {
        let ledger = ledgerText
        if !ledger.isEmpty, text.hasSuffix(ledger) { return false }
        let tokens = hostTokens(text)
        guard tokens != contextTokens || !contextFragment.isEmpty else { return false }
        contextTokens = tokens
        contextFragment = ""
        if isComposing {
            refresh()
        } else {
            predictionCandidates = predictionEnabled && !tokens.isEmpty
                ? decoder.associate(tokens, limit: 9) : []
        }
        return true
    }

    // The ledger as it reads in the host: adjacent English words are spaced,
    // as the keyboard commits them.
    private var ledgerText: String {
        let pieces = contextTokens.map(decoder.tokenText)
            + (contextFragment.isEmpty ? [] : [contextFragment])
        var text = ""
        var previousIsEnglish = false
        for piece in pieces {
            let isEnglish = Self.isEnglishWord(piece)
            if isEnglish && previousIsEnglish { text += " " }
            text += piece
            previousIsEnglish = isEnglish
        }
        return text
    }

    // Only English words joined by one space share a context; any other
    // whitespace breaks it, since nothing before it can score.
    private func hostTokens(_ text: String) -> [UInt32] {
        var tokens: [UInt32] = []
        var end = text.endIndex
        while true {
            let start = text[..<end].lastIndex(where: \.isWhitespace)
                .map { text.index(after: $0) } ?? text.startIndex
            let chunk = text[start..<end]
            guard !chunk.isEmpty else { break }
            tokens = chunkTokens(chunk) + tokens
            guard !tokens.contains(0), start > text.startIndex,
                  Self.isEnglishLetter(chunk.first) else { break }
            let space = text.index(before: start)
            guard text[space] == " ", space > text.startIndex,
                  Self.isEnglishLetter(text[text.index(before: space)]) else { break }
            end = space
        }
        return Self.afterLastBreak(tokens)
    }

    // English is never split into pieces: a word is one whole token or a break.
    private func chunkTokens(_ chunk: Substring) -> [UInt32] {
        let tokens = decoder.tokenize(String(chunk))
        guard !tokens.isEmpty else { return [0] }
        let kept = Self.afterLastBreak(tokens)
        let texts = kept.map(decoder.tokenText)
        // A word whose start fell before a break is only part of a word.
        var cut = Self.isEnglishLetter(chunk.dropLast(texts.joined().count).last)
        var result: [UInt32] = kept.count < tokens.count ? [0] : []
        var word = ""
        func endWord() {
            guard !word.isEmpty else { return }
            result.append(cut ? 0 : decoder.contextToken(word))
            word = ""
        }
        for (token, text) in zip(kept, texts) {
            if Self.isEnglishWord(text) {
                word += text
            } else {
                endWord()
                cut = false
                result.append(token)
            }
        }
        endWord()
        return result
    }

    private static func isEnglishLetter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isASCII && character.isLetter
    }

    private static func isEnglishWord(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { isEnglishLetter($0) }
    }

    func append(_ letter: String) {
        if cursor < raw.count {
            invalidateAnchorsForSourceEdit(at: cursor)
        }
        let insertion = raw.index(raw.startIndex, offsetBy: cursor)
        raw.insert(contentsOf: letter, at: insertion)
        cursor += letter.count
        predictionCandidates = []
        calculatorSuggestion = nil
        clearActiveSelection()
        refresh()
    }

    func delete() {
        guard !raw.isEmpty else {
            anchorSegments = []
            return
        }
        guard cursor > 0 else { return }
        invalidateAnchorsForSourceEdit(at: cursor - 1)
        let deletion = raw.index(raw.startIndex, offsetBy: cursor - 1)
        raw.remove(at: deletion)
        cursor -= 1
        refresh()
    }

    func select(_ index: Int) -> String? {
        guard candidates.indices.contains(index) else { return nil }
        let candidate = candidates[index]
        // A selection pins its span as anchors and keeps the input editable;
        // it commits to the host only when it covers the last key (契约 11a/11b).
        let consumed = rawConsumption(of: candidate)
        if consumed >= raw.count {
            return commitSentence(candidate)
        }
        anchorFrontSelection(candidate)
        return settleAnchors(endingAt: consumed, fallback: candidate)
    }

    /// Re-decode under the updated anchors, then commit once they reach the
    /// last key (11b) or move on to the next character.
    private func settleAnchors(endingAt keyEnd: Int, fallback: Candidate) -> String? {
        anchorSegments.sort { $0.syllableRange.lowerBound < $1.syllableRange.lowerBound }
        clearActiveSelection()
        refresh()
        if keyEnd >= raw.count {
            return commitSentence(candidates.first ?? fallback)
        }
        advanceToSegment(startingAtKey: keyEnd)
        return nil
    }

    /// Commit a full sentence to the host and clear the composition.
    private func commitSentence(_ candidate: Candidate) -> String {
        let result = committedText(of: candidate)
        recordSentenceCommit(candidate)
        clearComposition()
        return result
    }

    /// After a correction, activate the segment of the re-decoded sentence that
    /// begins at raw key `key`, so the user keeps correcting left to right.
    private func advanceToSegment(startingAtKey key: Int) {
        guard let top = candidates.first else { cursor = raw.count; return }
        var acc = 0
        for (seg, k) in segmentRawLengths(top).enumerated() {
            if acc == key { activateCharacter(displayIndex(forSegment: seg)); return }
            acc += k
        }
        cursor = raw.count
    }

    private func clearActiveSelection() {
        activeCharacterIndex = nil
        activeShowsKeys = false
        replacementCandidates = []
    }

    /// Anchor a front-row candidate over its own key spans (per character for
    /// Chinese, whole run for English) without consuming `raw`, so the choice
    /// is pinned but the whole input stays editable and re-decodes.
    private func anchorFrontSelection(_ candidate: Candidate) {
        let segChars = segmentCharCounts(candidate)
        let keyLens = segmentRawLengths(candidate)
        guard !segChars.isEmpty, segChars.count == keyLens.count else { return }
        let chars = Array(candidate.text)
        let tokensAligned = candidate.tokens.count == segChars.count
        var charCursor = 0
        var keyCursor = 0
        for i in 0..<segChars.count {
            let charEnd = min(chars.count, charCursor + max(0, segChars[i]))
            let keyEnd = keyCursor + keyLens[i]
            let range = i..<(i + 1)
            anchorSegments.removeAll { $0.syllableRange.overlaps(range) }
            anchorSegments.append(CompositionSegment(
                sourceKeyRange: keyCursor..<keyEnd,
                syllableRange: range,
                text: String(chars[charCursor..<charEnd]),
                tokens: tokensAligned ? [candidate.tokens[i]] : []))
            charCursor = charEnd
            keyCursor = keyEnd
        }
    }

    private func rawConsumption(of candidate: Candidate) -> Int {
        let keys = segmentRawLengths(candidate).reduce(0, +)
        return keys > 0 ? keys : candidate.consumed
    }

    /// Auto-anchor every segment before `segmentIndex` to the current top
    /// reading (segments already anchored are left as-is), so a correction
    /// keeps its left context fixed through the anchored re-decode.
    private func autoAnchorLeftContext(before segmentIndex: Int, of top: Candidate) {
        guard segmentIndex > 0 else { return }
        let segChars = segmentCharCounts(top)
        guard segChars.count >= segmentIndex else { return }
        let chars = Array(top.text)
        let tokensAligned = top.tokens.count == segChars.count
        var charCursor = 0
        for seg in 0..<segmentIndex {
            let start = charCursor
            let end = min(chars.count, start + max(0, segChars[seg]))
            charCursor = end
            if anchorSegments.contains(where: { $0.syllableRange.contains(seg) }) {
                continue
            }
            guard end > start else { continue }
            let keyStart = rawLength(forSegments: seg, of: top)
            let keyEnd = rawLength(forSegments: seg + 1, of: top)
            guard keyEnd > keyStart else { continue }
            anchorSegments.append(CompositionSegment(
                sourceKeyRange: keyStart..<keyEnd,
                syllableRange: seg..<(seg + 1),
                text: String(chars[start..<end]),
                tokens: tokensAligned ? [top.tokens[seg]] : []
            ))
        }
    }

    /// Re-evaluates the host text before the cursor; returns whether the
    /// suggestion changed so the caller can re-render.
    @discardableResult
    func updateCalculator(context: String?) -> Bool {
        let next = isComposing || !predictionEnabled ? nil : context.flatMap(Calculator.suggestion(forContext:))
        guard next != calculatorSuggestion else { return false }
        calculatorSuggestion = next
        if next != nil { predictionCandidates = [] }
        return true
    }

    func selectDisplayed(_ index: Int) -> String? {
        if !isComposing, let calc = calculatorSuggestion {
            guard index == 0 else { return nil }
            calculatorSuggestion = nil
            return calc.insert
        }
        if !isComposing, predictionCandidates.indices.contains(index) {
            let prediction = predictionCandidates[index]
            // Association candidates carry the full word; `consumed` leading
            // characters are already in the document (completion of the
            // trailing token), so only the remainder is inserted.
            let drop = min(prediction.consumed, prediction.text.count)
            let insert = String(prediction.text.dropFirst(drop))
            // A next English word is spaced off unless a space precedes it.
            let spaced = drop == 0 && Self.isEnglishLetter(insert.first)
                && contextFragment != " "
            // Only English words share a context across a space.
            if spaced, let last = contextTokens.last {
                let text = decoder.tokenText(last)
                if !text.isEmpty, !Self.isEnglishWord(text) { contextTokens = [] }
            }
            publishPredictions(for: prediction.tokens, replacingLast: drop > 0)
            return spaced ? " " + insert : insert
        }
        if let active = activeCharacterIndex,
           replacementCandidates.indices.contains(index),
           let top = candidates.first {
            let replacement = replacementCandidates[index]
            let relativeActive = unitIndex(forDisplayIndex: active)
            let segmentCount = segmentCharCounts(top).count
            guard relativeActive >= 0, relativeActive < segmentCount else { return nil }

            let topKeyLengths = segmentRawLengths(top)
            let replacementKeyCount = segmentRawLengths(replacement).reduce(0, +)
            var span = max(1, segmentCharCounts(replacement).count)
            if !replacement.segmentKeys.isEmpty, replacementKeyCount > 0 {
                var coveredKeys = 0
                span = 0
                while relativeActive + span < segmentCount,
                      coveredKeys < replacementKeyCount {
                    coveredKeys += topKeyLengths[relativeActive + span]
                    span += 1
                }
                if coveredKeys != replacementKeyCount {
                    // Replacement keys cross top-segment boundaries (English
                    // "Bi" over the B|ie split): anchor it by key range and
                    // re-decode (契约 11a), committing only if it reaches the
                    // last key (11b).
                    let keyStart = rawLength(forSegments: relativeActive, of: top)
                    let keyEnd = keyStart + replacementKeyCount
                    autoAnchorLeftContext(before: relativeActive, of: top)
                    anchorSegments.removeAll { $0.sourceKeyRange.overlaps(keyStart..<keyEnd) }
                    anchorSegments.append(CompositionSegment(
                        sourceKeyRange: keyStart..<keyEnd,
                        syllableRange: relativeActive..<(relativeActive + 1),
                        text: replacement.text,
                        tokens: replacement.tokens))
                    return settleAnchors(endingAt: keyEnd, fallback: replacement)
                }
            }
            guard relativeActive + span <= segmentCount else { return nil }

            let keyStart = rawLength(forSegments: relativeActive, of: top)
            let keyEnd = !replacement.segmentKeys.isEmpty && replacementKeyCount > 0
                ? keyStart + replacementKeyCount
                : rawLength(forSegments: relativeActive + span, of: top)
            guard keyEnd > keyStart else { return nil }
            let selectedRange = relativeActive..<(relativeActive + span)
            // Anchor faithfully, one anchor per replacement segment
            // (那|篇|paper): a Chinese segment carries its char + token, an
            // English segment its literal letters. Re-choosing a position just
            // replaces that segment's anchors, leaving the rest locked.
            anchorSegments.removeAll { $0.syllableRange.overlaps(selectedRange) }
            let chars = Array(replacement.text)
            let replSegChars = segmentCharCounts(replacement)
            let replSegKeys = replacement.segmentKeys
            if !replSegKeys.isEmpty, replSegKeys.count == replSegChars.count,
               replSegKeys.reduce(0, +) == keyEnd - keyStart,
               replSegChars.reduce(0, +) == chars.count {
                // One anchor per pick syllable over its own key sub-range, so
                // a re-segmentation (现 → 西|安) stays separate cells.
                var keyCursor = keyStart
                var charCursor = 0
                var tokenCursor = 0
                for i in replSegKeys.indices {
                    let kEnd = keyCursor + replSegKeys[i]
                    let n = replSegChars[i]
                    let text = String(chars[charCursor..<charCursor + n])
                    charCursor += n
                    let english = text.allSatisfy { $0.isASCII && $0.isLetter }
                    var tokens: [UInt32] = []
                    if !english, tokenCursor + n <= replacement.tokens.count {
                        tokens = Array(replacement.tokens[tokenCursor..<tokenCursor + n])
                        tokenCursor += n
                    }
                    anchorSegments.append(CompositionSegment(
                        sourceKeyRange: keyCursor..<kEnd,
                        syllableRange: (relativeActive + i)..<(relativeActive + i + 1),
                        text: text,
                        tokens: tokens))
                    keyCursor = kEnd
                }
            } else if replSegChars.count == span, replSegChars.reduce(0, +) == chars.count {
                var charCursor = 0
                var tokenCursor = 0
                for offset in 0..<span {
                    let seg = relativeActive + offset
                    let start = rawLength(forSegments: seg, of: top)
                    let end = rawLength(forSegments: seg + 1, of: top)
                    let n = replSegChars[offset]
                    let text = String(chars[charCursor..<charCursor + n])
                    charCursor += n
                    let english = text.allSatisfy { $0.isASCII && $0.isLetter }
                    var tokens: [UInt32] = []
                    if !english, tokenCursor + n <= replacement.tokens.count {
                        tokens = Array(replacement.tokens[tokenCursor..<tokenCursor + n])
                        tokenCursor += n
                    }
                    anchorSegments.append(CompositionSegment(
                        sourceKeyRange: start..<end,
                        syllableRange: seg..<(seg + 1),
                        text: text,
                        tokens: tokens))
                }
            } else {
                // No usable per-segment breakdown (e.g. a stub candidate): keep
                // the whole span as one anchor.
                anchorSegments.append(CompositionSegment(
                    sourceKeyRange: keyStart..<keyEnd,
                    syllableRange: selectedRange,
                    text: replacement.text,
                    tokens: replacement.tokens
                ))
            }
            // Lock everything before the chosen position to the current top
            // reading, so re-decoding under this anchor can't disturb the
            // characters the user already accepted on its left.
            autoAnchorLeftContext(before: relativeActive, of: top)
            // By key position, robust across re-segmentation.
            return settleAnchors(endingAt: keyEnd, fallback: top)
        }
        return select(index)
    }

    /// 锚点视为 ground truth：整句候选在锚点位置与锚点文本不符则过滤掉。
    func matchesAnchors(_ candidate: Candidate) -> Bool {
        if usingEngineAnchors { return true }
        guard !anchorSegments.isEmpty else { return true }
        let chars = Array(candidate.text)
        let segmentCount = segmentCharCounts(candidate).count
        // Only filter when characters line up 1:1 with segments; otherwise we
        // cannot map anchor segment ranges to characters, so keep the candidate.
        guard chars.count == segmentCount else { return true }
        for anchor in anchorSegments {
            let range = anchor.syllableRange
            guard range.lowerBound >= 0, range.upperBound <= chars.count else { return false }
            if String(chars[range]) != anchor.text { return false }
        }
        return true
    }

    /// 关闭第一行选中（气泡消失时用）：取消高亮，恢复普通候选/联想。
    func deactivateCharacter() {
        clearActiveSelection()
    }

    /// A further tap on the character whose pinyin is being edited leaves
    /// editing instead of reopening its candidates.
    func isEditingPinyin(at index: Int) -> Bool {
        activeShowsKeys && activeCharacterIndex == index
    }

    func activateCharacter(_ index: Int, allowKeyToggle: Bool = true) {
        // Second tap on the highlighted char reveals its typed keys; the first
        // only selects it and lists candidates.
        if allowKeyToggle, index == activeCharacterIndex, !activeShowsKeys {
            activeShowsKeys = true
            // Enter pinyin editing: cursor to this segment's raw key end.
            if let top = candidates.first {
                let rel = unitIndex(forDisplayIndex: index)
                if rel >= 0 {
                    cursor = min(rawLength(forSegments: rel + 1, of: top),
                                 raw.count)
                }
            }
            return
        }
        let sentence = sentencePreview
        guard Array(sentence).indices.contains(index),
              let top = candidates.first else { return }
        let segmentCount = segmentCharCounts(top).count
        let relativeIndex = unitIndex(forDisplayIndex: index)
        guard relativeIndex >= 0, relativeIndex < segmentCount else { return }
        activeCharacterIndex = index
        activeShowsKeys = false
        // Candidate mode keeps the edit cursor at the end (only the toggle
        // above moves it into a syllable).
        cursor = raw.count
        let current = renderedText(top.text)
        let displayRelativeIndex = index
        let fixedPrefix = String(Array(current).prefix(max(0, displayRelativeIndex)))
        let nextAnchor = anchorSegments
            .map(\.syllableRange.lowerBound)
            .filter { $0 > relativeIndex }
            .min() ?? segmentCount
        let anchorColumn = rawLength(forSegments: relativeIndex, of: top)
        // Bound by raw-key span to the next anchor, not segment count, so a
        // re-split of the same keys (xian → 西安) survives.
        let maximumKeys = max(1, rawLength(forSegments: nextAnchor, of: top) - anchorColumn)
        replacementCandidates = decoder.correctionCandidatesForComposition(
            raw: raw,
            scheme: inputScheme,
            fixedPrefix: fixedPrefix,
            rawKeyColumn: anchorColumn,
            context: Array(contextTokens.suffix(32)),
            limit: 60
        ).filter {
            let keys = segmentRawLengths($0).reduce(0, +)
            return keys == 0 || keys <= maximumKeys
        }
    }

    func commitBestOrRaw() -> String? {
        // Space on a mobile keyboard commits the top *sentence* candidate.
        // Do not retain a decoder's partial-consumption tail here: this UI
        // does not yet expose segmented selection, and retaining it caused
        // the final pinyin letter to remain in composition.
        if let candidate = candidates.first {
            let result = committedText(of: candidate)
            recordSentenceCommit(candidate)
            clearComposition()
            return result
        }
        guard isComposing else { return nil }
        let result = raw
        predictionCandidates = []
        appendInsertedContext(result)
        clearComposition()
        return result
    }

    /// Commits the currently marked input without decoding its remaining pinyin.
    /// A prior explicit candidate selection remains part of the preedit, while
    /// the unconverted portion is inserted literally as English text.
    func commitPreeditLiterally() -> String? {
        guard isComposing else { return nil }
        let result: String
        if !anchorSegments.isEmpty, let candidate = candidates.first {
            // Corrections anchored decoded characters, so the user committed to
            // Chinese: decode the non-anchored syllables via the top candidate
            // instead of emitting their literal keys.
            result = committedText(of: candidate)
            recordSentenceCommit(candidate)
        } else {
            result = literalTextWithAnchors()
            predictionCandidates = []
            appendInsertedContext(result)
        }
        clearComposition()
        return result
    }

    private func publishPredictions(for tokens: [UInt32],
                                    replacingLast: Bool = false) {
        guard !tokens.isEmpty else {
            predictionCandidates = []
            return
        }
        // Extend the running ledger so consecutive association taps accumulate.
        extendContext(with: tokens, replacingLast: replacingLast)
        guard predictionEnabled else {
            predictionCandidates = []
            return
        }
        predictionCandidates = decoder.associate(contextTokens, limit: 9)
    }

    /// Text committed as one unit (a symbol, a digit, literal keys) enters the
    /// context as a whole token; text with no token clears it.
    func appendInsertedContext(_ text: String) {
        guard !text.isEmpty else { return }
        extendContext(with: [decoder.contextToken(text)])
        predictionCandidates = predictionEnabled
            ? decoder.associate(contextTokens, limit: 9) : []
    }

    /// Backspace outside composition removes the last character from the
    /// context. A shortened token that is no longer a token becomes a
    /// fragment offering word completions; earlier tokens stay settled.
    func deleteContextBackward() {
        let text: String
        if !contextFragment.isEmpty {
            text = contextFragment
        } else if let last = contextTokens.popLast() {
            text = decoder.tokenText(last)
        } else {
            return
        }
        contextFragment = String(text.dropLast())
        if contextFragment.isEmpty, Self.isEnglishWord(text),
           let previous = contextTokens.last, Self.isEnglishWord(decoder.tokenText(previous)) {
            // The space between two English words is deleted on its own.
            contextFragment = " "
        } else if !contextFragment.isEmpty {
            let exact = decoder.contextToken(contextFragment)
            if exact != 0 {
                contextTokens.append(exact)
                contextFragment = ""
            } else {
                let completions = predictionEnabled
                    ? decoder.complete(contextFragment, context: contextTokens, limit: 9) : []
                if !completions.isEmpty {
                    predictionCandidates = completions
                    return
                }
                settleContextFragment()
            }
        }
        // After a space only next words fit, not completions of the word before it.
        predictionCandidates = predictionEnabled && !contextTokens.isEmpty
            ? decoder.associate(contextTokens, limit: 9)
                .filter { contextFragment != " " || $0.consumed == 0 } : []
    }

    // A fragment left without a picked completion: English has no word
    // pieces, so the context breaks; Chinese re-segments the fragment.
    private func settleContextFragment() {
        guard !contextFragment.isEmpty, contextFragment != " " else { return }
        let fragment = contextFragment
        contextFragment = ""
        guard !fragment.allSatisfy(\.isASCII) else {
            contextTokens = []
            return
        }
        let tokens = decoder.tokenize(fragment)
        contextTokens = tokens.isEmpty ? [] : Self.afterLastBreak(contextTokens + tokens)
    }

    /// Space and newline never form a token, so they start a fresh context.
    func clearContext() {
        contextTokens = []
        contextFragment = ""
        predictionCandidates = []
    }

    // The decoder's tokens are the committed sentence, anchors included on the
    // engine path; only the legacy overlay, whose tokens miss the anchors,
    // needs re-segmenting.
    private func recordSentenceCommit(_ candidate: Candidate) {
        if anchorSegments.isEmpty || usingEngineAnchors {
            publishPredictions(for: candidate.tokens)
        } else {
            predictionCandidates = []
            extendContext(with: decoder.tokenize(renderedText(candidate.text)))
        }
    }

    private func extendContext(with tokens: [UInt32], replacingLast: Bool = false) {
        // A completion subsumes its prefix: the fragment, else the trailing
        // token (狐 → 狐狸).
        if replacingLast {
            if contextFragment.isEmpty {
                contextTokens = contextTokens.dropLast()
            } else {
                contextFragment = ""
            }
        }
        if contextFragment == " " {
            contextFragment = ""
            // Only English words share a context across a space.
            if let first = tokens.first, !Self.isEnglishWord(decoder.tokenText(first)) {
                contextTokens = []
            }
        }
        settleContextFragment()
        contextTokens = Array(Self.afterLastBreak(contextTokens + tokens).suffix(32))
    }

    // Nothing before a NotToken break can score, so the context keeps only
    // what follows it.
    private static func afterLastBreak(_ tokens: [UInt32]) -> [UInt32] {
        guard let last = tokens.lastIndex(of: 0) else { return tokens }
        return Array(tokens[(last + 1)...])
    }

    private func clearComposition() {
        raw = ""
        anchorSegments = []
        cursor = 0
        candidates = []
        clearActiveSelection()
        displayGroups = []
    }

    private func refresh() {
        settleContextFragment()
        let context = Array(contextTokens.suffix(32))
        let anchors = engineAnchors()
        usingEngineAnchors = anchors != nil
        candidates = decoder.decodeComposition(
            raw, scheme: inputScheme, context: context, limit: 60,
            anchors: anchors ?? [])
        displayGroups = computeDisplayGroups(
            raw: raw, units: candidates.first?.units ?? "", top: candidates.first)
    }

    /// Anchors for the engine, or nil to use the Swift overlay. Native
    /// sp-index path only; nil if any Chinese anchor lacks a usable token.
    /// True on the native engine with re-decode on (full pinyin or shuangpin
    /// index), i.e. where a selection becomes an engine anchor, not a prefix.
    /// Both decode `raw` 1:1 in input-letter coordinates, so anchor key ranges
    /// line up with the engine input.
    private var supportsEngineAnchors: Bool {
        reDecodeOnCorrection
            && decoder.isNative
            && decoder.shuangpinIndexName == inputScheme.shuangpinIndexName
    }

    private func engineAnchors() -> [DecodeAnchor]? {
        guard supportsEngineAnchors, !anchorSegments.isEmpty else { return nil }
        var out: [DecodeAnchor] = []
        for seg in anchorSegments {
            let a = seg.sourceKeyRange.lowerBound
            let b = seg.sourceKeyRange.upperBound
            guard b > a, b <= raw.count else { return nil }
            let english = !seg.text.isEmpty && seg.text.allSatisfy {
                $0.isASCII && $0.isLetter
            }
            if english {
                out.append(DecodeAnchor(a: a, b: b, english: true, token: 0,
                                        text: seg.text))
            } else {
                // Match by character (text); the token is only an injection
                // fallback, so a tokenless anchor still constrains the decode.
                out.append(DecodeAnchor(a: a, b: b, english: false,
                                        token: seg.tokens.first ?? 0,
                                        text: seg.text))
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Group raw keys by decoder spans, then join spans committed as one
    /// English anchor. Display grouping never changes commit consumption.
    private func computeDisplayGroups(raw: String, units: String,
                                      top: Candidate?) -> [String] {
        if let top, !top.segmentKeys.isEmpty {
            var parts = rawGroups(of: top)
            let used = parts.reduce(0) { $0 + $1.count }
            if used < raw.count { parts.append(String(raw.dropFirst(used))) }
            // Engine mode already groups by the decoder's spans; the overlay-era
            // coalescing uses stale anchor syllable ranges and would mis-merge.
            return usingEngineAnchors ? parts : coalescingEnglishAnchorGroups(parts)
        }
        var parts: [String] = []
        var pinyinPrefix = raw
        var remainingUnits = units.split(separator: "'").map(String.init)
        let englishPrefix = (top?.text ?? "").prefix(while: { $0.isASCII && $0.isLetter })
        if englishPrefix.count > 1, raw.count >= englishPrefix.count {
            let end = raw.index(raw.startIndex, offsetBy: englishPrefix.count)
            parts.append(String(raw[..<end]))
            pinyinPrefix = String(raw[end...])
            var consumed = 0
            while !remainingUnits.isEmpty && consumed < englishPrefix.count {
                consumed += remainingUnits.removeFirst().count
            }
        }
        if !pinyinPrefix.isEmpty {
            if remainingUnits.isEmpty {
                parts.append(pinyinPrefix)
            } else {
                var input = Substring(pinyinPrefix)
                for unit in remainingUnits {
                    guard !input.isEmpty else { break }
                    var group = ""
                    if input.first == "'" { group.append("'"); input.removeFirst() }
                    let length = min(unit.count, input.count)
                    group += String(input.prefix(length))
                    input.removeFirst(length)
                    parts.append(group)
                }
                if !input.isEmpty { parts.append(String(input)) }
            }
        }
        return parts
    }

    private func coalescingEnglishAnchorGroups(_ groups: [String]) -> [String] {
        let englishRanges = Dictionary(
            anchorSegments.compactMap { anchor -> (Int, Range<Int>)? in
                guard !anchor.text.isEmpty,
                      anchor.text.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
                return (anchor.syllableRange.lowerBound, anchor.syllableRange)
            }, uniquingKeysWith: { first, _ in first })
        guard !englishRanges.isEmpty else { return groups }

        var result: [String] = []
        var index = 0
        while index < groups.count {
            guard let range = englishRanges[index], range.upperBound > index else {
                result.append(groups[index])
                index += 1
                continue
            }
            var end = min(range.upperBound, groups.count)
            while end < groups.count,
                  let next = englishRanges[end], next.upperBound > end {
                end = min(next.upperBound, groups.count)
            }
            result.append(groups[index..<end].joined())
            index = end
        }
        return result
    }
}


enum NumberPagePolicy {
    /// Half-width `. - / * + =` stay on the number page only when they follow
    /// a digit (decimals, dates, arithmetic); otherwise they end number entry.
    static func keepsNumberPage(afterInserting punctuation: String,
                                previous: Character?) -> Bool {
        guard [".", "-", "/", "*", "+", "="].contains(punctuation), let previous else { return false }
        return previous.isASCII && previous.isNumber
    }
}
