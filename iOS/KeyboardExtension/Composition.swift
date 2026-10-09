import Foundation

final class Composition {
    /// One immutable selection in the composition source, aligned to the raw
    /// keys and syllables it consumed. Prefix segments carry a whole selection
    /// (possibly multi-syllable); correction anchors are one syllable each.
    private struct CompositionSegment {
        let sourceKeyRange: Range<Int>
        let syllableRange: Range<Int>
        let text: String
        let tokens: [UInt32]
        // The literal keys that produced this segment. Retained so a tap on an
        // already-committed first-row character can restore them into `raw`
        // and re-open selection. Empty for restored/lock-screen segments.
        var sourceKeys: String = ""
    }

    private let decoder: PinyinDecoder
    private let inputScheme: InputScheme
    private(set) var raw = ""
    private(set) var committed = ""
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
    private var committedTokens: [UInt32] = []
    // Sequential selections before `raw` and sparse user corrections inside
    // `raw` use the same source-aligned segment representation. Correction
    // anchors stay sparse so every sentence position remains editable.
    private var prefixSegments: [CompositionSegment] = []
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

    private var prefixText: String { prefixSegments.map(\.text).joined() }
    private var consumedKeyCount: Int { prefixSegments.last?.sourceKeyRange.upperBound ?? 0 }
    private var consumedSyllableCount: Int { prefixSegments.last?.syllableRange.upperBound ?? 0 }
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
    // Ungrouped preedit for commit paths: separators are display-only and must
    // never reach the host document.
    private var rawPreedit: String { prefixText + raw }
    var preedit: String { prefixText + groupedRaw }
    /// The displayed preedit up to the composition cursor (committed prefix
    /// plus grouped raw before the cursor). Callers strip this from the host
    /// context so the marked, grouped pinyin never becomes model input.
    var markedPrefix: String {
        var out = ""
        var rawSeen = 0
        for (index, group) in rawSyllableGroups.enumerated() {
            guard rawSeen < cursor else { break }
            if index > 0 { out += Self.syllableSeparator }
            out += String(group.prefix(cursor - rawSeen))
            rawSeen += group.count
        }
        return prefixText + out
    }
    var selectionLocation: Int { markedPrefix.utf16.count }
    var isComposing: Bool { !raw.isEmpty || !prefixSegments.isEmpty }
    var sentencePreview: String {
        prefixText + renderedText(candidates.first?.text ?? "")
    }

    struct SentenceSegment {
        let text: String
        let displayIndex: Int
    }

    private struct SentenceMapping {
        let segments: [SentenceSegment]
        let unitRanges: [Range<Int>]

        init(text: String, segmentChars: [Int], anchors: [CompositionSegment] = [],
             prefixLength: Int = 0) {
            let chars = Array(text)
            var segments: [SentenceSegment] = []
            var ranges = Array(repeating: 0..<0, count: segmentChars.count)
            var display = min(prefixLength, chars.count)
            var unit = 0
            let anchorsByStart = Dictionary(
                anchors.map { ($0.syllableRange.lowerBound, $0) },
                uniquingKeysWith: { first, _ in first })
            for index in 0..<display {
                segments.append(SentenceSegment(text: String(chars[index]),
                                                displayIndex: index))
            }
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
                        anchors: anchorSegments,
                        prefixLength: prefixText.count)
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
        let relative = index - prefixText.count
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
    /// candidate begins (relative to the sentence preview, offset by the
    /// committed prefix). A segment can span several characters, so this is not
    /// the segment index itself.
    private func displayIndex(forSegment segmentIndex: Int) -> Int {
        let ranges = sentenceMapping.unitRanges
        guard ranges.indices.contains(segmentIndex) else {
            return prefixText.count + segmentIndex
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

    func restore(raw: String, committed: String) {
        guard !raw.isEmpty || !committed.isEmpty else { return }
        self.raw = raw
        self.committed = committed
        if !committed.isEmpty {
            prefixSegments = [CompositionSegment(
                sourceKeyRange: 0..<0,
                syllableRange: 0..<0,
                text: committed,
                tokens: []
            )]
        }
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
            committed = ""
            committedTokens = []
            prefixSegments = []
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
        let consumed = rawConsumption(of: candidate)
        let segments = max(1, segmentCharCounts(candidate).count)
        let sourceKeys = String(raw.prefix(min(consumed, raw.count)))
        appendPrefixSegment(
            text: candidate.text,
            keyCount: consumed,
            syllableCount: segments,
            tokens: candidate.tokens,
            sourceKeys: sourceKeys
        )
        raw.removeFirst(min(consumed, raw.count))
        cursor = max(0, cursor - consumed)
        refresh()
        guard raw.isEmpty else { return nil }
        let result = prefixText
        publishPredictions(for: committedTokens)
        clearComposition()
        return result
    }

    private func appendPrefixSegment(text: String, keyCount: Int,
                                     syllableCount: Int, tokens: [UInt32],
                                     sourceKeys: String = "") {
        guard keyCount > 0, syllableCount > 0 else { return }
        let keyStart = consumedKeyCount
        let syllableStart = consumedSyllableCount
        prefixSegments.append(CompositionSegment(
            sourceKeyRange: keyStart..<(keyStart + keyCount),
            syllableRange: syllableStart..<(syllableStart + syllableCount),
            text: text,
            tokens: tokens,
            sourceKeys: sourceKeys
        ))
        committed = prefixText
        committedTokens = prefixSegments.flatMap(\.tokens)
    }

    private func rawConsumption(of candidate: Candidate) -> Int {
        let keys = segmentRawLengths(candidate).reduce(0, +)
        return keys > 0 ? keys : candidate.consumed
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
                guard coveredKeys == replacementKeyCount else { return nil }
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
            // A replacement can span multiple final segments.
            if selectedRange.upperBound >= segmentCount {
                let result = prefixText + renderedText(top.text)
                predictionCandidates = []
                clearComposition()
                return result
            }
            cursor = raw.count
            return nil
        }
        return select(index)
    }

    /// 锚点视为 ground truth：整句候选在锚点位置与锚点文本不符则过滤掉。
    func matchesAnchors(_ candidate: Candidate) -> Bool {
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
        // A tap inside the sequentially committed prefix re-opens that
        // selection: restore its keys (and every later prefix segment's keys)
        // into `raw`, then activate the first syllable of the reopened span.
        if index < prefixText.count {
            guard uncommitPrefix(containingCharacter: index) else { return }
            activateCharacter(prefixText.count)
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
        let displayRelativeIndex = index - prefixText.count
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

    /// Undo the committed prefix segment that renders character `charIndex`
    /// (and every segment after it), pushing their literal keys back to the
    /// front of `raw` so the user can choose again. Anchors are relative to
    /// the raw decode that just changed, so they are cleared.
    private func uncommitPrefix(containingCharacter charIndex: Int) -> Bool {
        var cumulative = 0
        var start: Int?
        for (segmentIndex, segment) in prefixSegments.enumerated() {
            let count = segment.text.count
            if charIndex < cumulative + count { start = segmentIndex; break }
            cumulative += count
        }
        guard let firstRemoved = start else { return false }
        let restoredKeys = prefixSegments[firstRemoved...]
            .map(\.sourceKeys).joined()
        guard !restoredKeys.isEmpty else { return false }
        prefixSegments.removeSubrange(firstRemoved...)
        raw = restoredKeys + raw
        cursor += restoredKeys.count
        committed = prefixText
        committedTokens = prefixSegments.flatMap(\.tokens)
        anchorSegments = []
        replacementCandidates = []
        refresh()
        return true
    }

    func commitBestOrRaw() -> String? {
        // Space on a mobile keyboard commits the top *sentence* candidate.
        // Do not retain a decoder's partial-consumption tail here: this UI
        // does not yet expose segmented selection, and retaining it caused
        // the final pinyin letter to remain in composition.
        if let candidate = candidates.first {
            let result = prefixText + renderedText(candidate.text)
            if anchorSegments.isEmpty {
                publishPredictions(for: committedTokens + candidate.tokens)
            } else {
                predictionCandidates = []
            }
            clearComposition()
            return result
        }
        guard isComposing else { return nil }
        let result = rawPreedit
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
            // A second-row correction anchors decoded characters inside the
            // sentence, so the user has committed to Chinese. Decode the
            // remaining (non-anchored) syllables via the top candidate
            // instead of emitting their literal keys; the literal escape
            // hatch only applies when no anchor selection is active.
            result = prefixText + renderedText(candidate.text)
        } else {
            result = prefixText + literalTextWithAnchors()
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
        committed = ""
        committedTokens = []
        prefixSegments = []
        anchorSegments = []
        cursor = 0
        candidates = []
        activeCharacterIndex = nil
        activeShowsKeys = false
        replacementCandidates = []
        displayGroups = []
    }

    private func refresh() {
        let context = Array(
            ((hostContextTokens ?? contextTokens) + committedTokens).suffix(32))
        candidates = decoder.decodeComposition(
            raw, scheme: inputScheme, context: context, limit: 60)
        displayGroups = computeDisplayGroups(
            raw: raw, units: candidates.first?.units ?? "", top: candidates.first)
    }

    /// Group raw keys by decoder spans, joining adjacent spans shown as one
    /// ASCII word. Display grouping never changes commit consumption.
    private func computeDisplayGroups(raw: String, units: String,
                                      top: Candidate?) -> [String] {
        let topText = top?.text ?? ""
        if let top, !top.segmentKeys.isEmpty {
            let groups = rawGroups(of: top)
            let spans = sentenceMapping.unitRanges
            let text = Array(sentencePreview)
            var parts: [String] = []
            var index = 0
            while index < groups.count {
                guard spans.indices.contains(index) else {
                    parts.append(contentsOf: groups[index...])
                    break
                }
                let span = spans[index]
                let isEnglish = !span.isEmpty && span.allSatisfy {
                    text[$0].isASCII && text[$0].isLetter
                }
                guard isEnglish else {
                    parts.append(groups[index])
                    index += 1
                    continue
                }
                var end = index + 1
                var previous = span
                while end < min(groups.count, spans.count) {
                    let next = spans[end]
                    guard !next.isEmpty,
                          next.allSatisfy({ text[$0].isASCII && text[$0].isLetter }),
                          next.lowerBound == previous.upperBound || next == previous else {
                        break
                    }
                    previous = next
                    end += 1
                }
                parts.append(groups[index..<end].joined())
                index = end
            }
            let used = groups.reduce(0) { $0 + $1.count }
            if used < raw.count { parts.append(String(raw.dropFirst(used))) }
            return parts.isEmpty && !raw.isEmpty ? [raw] : parts
        }
        var parts: [String] = []
        var pinyinPrefix = raw
        var remainingUnits = units.split(separator: "'").map(String.init)
        let englishPrefix = topText.prefix(while: { $0.isASCII && $0.isLetter })
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
}
