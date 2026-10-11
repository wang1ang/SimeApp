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
    // Tokens derived from the host's text before the insertion point. They
    // supersede the local fallback whenever UIKit exposes that text.
    private var hostContextTokens: [UInt32]?
    private var contextTokens: [UInt32] = []
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
            if !predictionEnabled { predictionCandidates = [] }
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
    var sentencePreview: String {
        renderedText(candidates.first?.text ?? "")
    }

    struct SentenceSegment {
        let text: String
        let displayIndex: Int
    }

    private struct SentenceMapping {
        let segments: [SentenceSegment]
        let unitRanges: [Range<Int>]

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
                    segments.append(SentenceSegment(
                        text: String(chars[range]), displayIndex: start))
                    display = end
                    unit = anchor.syllableRange.upperBound
                    continue
                }
                let runStart = display
                var range = span(unit, from: display)
                ranges[unit] = range
                display = range.upperBound
                unit += 1
                // Keep adjacent ASCII decoder segments as one touch target.
                if isEnglish(range) {
                    while unit < segmentChars.count,
                          anchorsByStart[unit] == nil {
                        let next = span(unit, from: display)
                        guard isEnglish(next) else { break }
                        ranges[unit] = next
                        range = next
                        display = next.upperBound
                        unit += 1
                    }
                }
                segments.append(SentenceSegment(
                    text: String(chars[runStart..<display]),
                    displayIndex: runStart))
            }
            self.segments = segments
            self.unitRanges = ranges
        }
    }


    var sentenceSegments: [SentenceSegment] {
        sentenceMapping.segments
    }

    private var sentenceMapping: SentenceMapping {
        SentenceMapping(text: sentencePreview,
                        segmentChars: segmentCharCounts(candidates.first),
                        anchors: usingEngineAnchors ? anchorsAlignedToTop() : anchorSegments)
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

    var hasLiteralEnglishCandidate: Bool {
        candidates.contains { $0.isEnglish }
    }

    var displayCandidates: [Candidate] {
        if !replacementCandidates.isEmpty { return replacementCandidates }
        guard !isComposing else { return candidates }
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

    func moveCursor(to offset: Int) {
        cursor = min(max(0, offset), raw.count)
    }

    /// Discard the in-progress composition without committing to the host.
    /// Used when the host context shows the marked pinyin no longer belongs to
    /// the focused field, so it isn't re-injected into the wrong field.
    func cancel() {
        clearComposition()
    }

    func updateHostContext(from text: String) {
        let tokens = decoder.tokenize(text)
        guard hostContextTokens != tokens else { return }
        hostContextTokens = tokens
        // Host is the authoritative baseline: replace the ledger, don't append.
        contextTokens = tokens
        if isComposing { refresh() }
    }

    func append(_ letter: String) {
        if cursor < raw.count {
            invalidateAnchorsForSourceEdit(at: cursor)
        }
        let insertion = raw.index(raw.startIndex, offsetBy: cursor)
        raw.insert(contentsOf: letter, at: insertion)
        cursor += letter.count
        predictionCandidates = []
        activeCharacterIndex = nil
        activeShowsKeys = false
        replacementCandidates = []
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
        if rawConsumption(of: candidate) >= raw.count {
            return commitSentence(candidate.text, tokens: candidate.tokens)
        }
        anchorFrontSelection(candidate)
        activeCharacterIndex = nil
        activeShowsKeys = false
        replacementCandidates = []
        refresh()
        return nil
    }

    /// Commit a full sentence to the host and clear the composition.
    private func commitSentence(_ text: String, tokens: [UInt32]) -> String {
        let result = renderedText(text)
        if anchorSegments.isEmpty {
            publishPredictions(for: tokens)
        } else {
            predictionCandidates = []
        }
        clearComposition()
        return result
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
        anchorSegments.sort { $0.syllableRange.lowerBound < $1.syllableRange.lowerBound }
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

    func selectDisplayed(_ index: Int) -> String? {
        if !isComposing, predictionCandidates.indices.contains(index) {
            let prediction = predictionCandidates[index]
            // Association candidates carry the full word; `consumed` leading
            // characters are already in the document (completion of the
            // trailing token), so only the remainder is inserted.
            let drop = min(prediction.consumed, prediction.text.count)
            let insert = String(prediction.text.dropFirst(drop))
            publishPredictions(for: prediction.tokens, replacingLast: drop > 0)
            return insert
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
                    anchorSegments.sort { $0.syllableRange.lowerBound < $1.syllableRange.lowerBound }
                    activeCharacterIndex = nil
                    activeShowsKeys = false
                    replacementCandidates = []
                    refresh()
                    if keyEnd >= raw.count {
                        return commitSentence(candidates.first?.text ?? "",
                                              tokens: candidates.first?.tokens ?? [])
                    }
                    return nil
                }
            }
            guard relativeActive + span <= segmentCount else { return nil }

            let keyStart = rawLength(forSegments: relativeActive, of: top)
            let keyEnd = !replacement.segmentKeys.isEmpty && replacementKeyCount > 0
                ? keyStart + replacementKeyCount
                : rawLength(forSegments: relativeActive + span, of: top)
            guard keyEnd > keyStart else { return nil }
            let selectedRange = relativeActive..<(relativeActive + span)
            // Anchor per segment: re-choosing a position just replaces that
            // segment's anchor, leaving the rest locked.
            anchorSegments.removeAll { $0.syllableRange.overlaps(selectedRange) }
            let chars = Array(replacement.text)
            let tokensAligned = replacement.tokens.count == span
            if chars.count == span {
                for offset in 0..<span {
                    let seg = relativeActive + offset
                    let start = rawLength(forSegments: seg, of: top)
                    let end = rawLength(forSegments: seg + 1, of: top)
                    anchorSegments.append(CompositionSegment(
                        sourceKeyRange: start..<end,
                        syllableRange: seg..<(seg + 1),
                        text: String(chars[offset]),
                        tokens: tokensAligned ? [replacement.tokens[offset]] : []
                    ))
                }
            } else {
                // A segment can produce several characters (多音节词): keep the
                // whole span as one anchor rather than splitting per character.
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
            anchorSegments.sort {
                $0.syllableRange.lowerBound < $1.syllableRange.lowerBound
            }
            activeCharacterIndex = nil
            activeShowsKeys = false
            replacementCandidates = []
            refresh()

            let next = selectedRange.upperBound
            if next < segmentCount {
                activateCharacter(displayIndex(forSegment: next))
                return nil
            }
            // A replacement can span multiple final segments. Commit the
            // re-decoded top (engine mode) / anchor-overlaid top (overlay mode).
            if selectedRange.upperBound >= segmentCount {
                return commitSentence(candidates.first?.text ?? top.text,
                                      tokens: candidates.first?.tokens ?? [])
            }
            cursor = raw.count
            return nil
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
        guard activeCharacterIndex != nil else { return }
        activeCharacterIndex = nil
        activeShowsKeys = false
        replacementCandidates = []
        displayGroups = []
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
        let maximumSpan = max(1, nextAnchor - relativeIndex)
        let anchorColumn = rawLength(forSegments: relativeIndex, of: top)
        replacementCandidates = decoder.correctionCandidatesForComposition(
            raw: raw,
            top: top,
            scheme: inputScheme,
            fixedPrefix: fixedPrefix,
            prefixSegment: relativeIndex,
            rawKeyColumn: anchorColumn,
            limit: 60
        ).filter { segmentCharCounts($0).count <= maximumSpan }
    }

    func commitBestOrRaw() -> String? {
        // Space on a mobile keyboard commits the top *sentence* candidate.
        // Do not retain a decoder's partial-consumption tail here: this UI
        // does not yet expose segmented selection, and retaining it caused
        // the final pinyin letter to remain in composition.
        if let candidate = candidates.first {
            let result = renderedText(candidate.text)
            if anchorSegments.isEmpty {
                publishPredictions(for: candidate.tokens)
            } else {
                predictionCandidates = []
            }
            clearComposition()
            return result
        }
        guard isComposing else { return nil }
        let result = raw
        predictionCandidates = []
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
            result = renderedText(candidate.text)
        } else {
            result = literalTextWithAnchors()
        }
        predictionCandidates = []
        clearComposition()
        return result
    }

    private func publishPredictions(for tokens: [UInt32],
                                    replacingLast: Bool = false) {
        guard predictionEnabled, !tokens.isEmpty else {
            predictionCandidates = []
            return
        }
        // Extend the running ledger so consecutive association taps accumulate.
        var base = contextTokens
        // A completion subsumes the trailing context token (狐 → 狐狸); drop it.
        if replacingLast, !base.isEmpty { base.removeLast() }
        contextTokens = Array((base + tokens).suffix(32))
        predictionCandidates = decoder.associate(contextTokens, limit: 9)
    }

    private func clearComposition() {
        raw = ""
        anchorSegments = []
        cursor = 0
        candidates = []
        activeCharacterIndex = nil
        activeShowsKeys = false
        replacementCandidates = []
        displayGroups = []
    }

    private func refresh() {
        let context = Array((hostContextTokens ?? contextTokens).suffix(32))
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
                guard let token = seg.tokens.first, token != 0 else { return nil }
                out.append(DecodeAnchor(a: a, b: b, english: false, token: token))
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
