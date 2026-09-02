import Foundation

final class Composition {
    /// One immutable selection in the composition source. Anchoring is a
    /// sequence of source-aligned segments, so no state transition infers a
    /// pinyin boundary from the number of displayed Han characters.
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
    // Per-initial cache of the final keys that complete a valid Shuangpin
    // syllable. Bounded by the alphabet, so each initial is validated through
    // the decoder at most once for this Composition (a decoder swap builds a
    // fresh Composition, which resets the cache).
    private var shuangpinFinalHighlightCache: [Character: Set<Character>] = [:]

    init(decoder: PinyinDecoder = BuiltinPinyinDecoder(),
         inputScheme: InputScheme = InputSettings.scheme) {
        self.decoder = decoder
        self.inputScheme = inputScheme
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
    var displayCandidates: [Candidate] {
        if !replacementCandidates.isEmpty { return replacementCandidates }
        return isComposing ? candidates : predictionCandidates
    }

    /// The literal key sequence entered for the active correction syllable.
    /// Do not use Sime's normalized pinyin units here: a Microsoft Shuangpin
    /// user must see their two-key code, and full-pinyin input must retain
    /// typed separators such as an apostrophe.
    var activeEnteredKeys: String? {
        guard activeShowsKeys,
              let active = activeCharacterIndex,
              let units = candidates.first?.units else { return nil }
        let syllables = units.split(separator: "'").map(String.init)
        let rawSyllableIndex = active - prefixText.count
        guard syllables.indices.contains(rawSyllableIndex) else { return nil }
        let groups = enteredKeyGroups(for: syllables)
        guard groups.indices.contains(rawSyllableIndex) else { return nil }
        return groups[rawSyllableIndex]
    }

    /// Letter-layout keys that complete a valid syllable with the Shuangpin
    /// initial the user just typed. Non-empty only while a lone initial (the
    /// odd key at the composition cursor) awaits its final; empty for full
    /// pinyin and once the syllable is complete. Validity comes from decoding
    /// each expanded two-key syllable, so the highlighted set always tracks
    /// what the engine can actually produce.
    func shuangpinFinalKeyHighlights() -> Set<Character> {
        guard inputScheme == .microsoftShuangpin else { return [] }
        // Syllables are exactly two keys, so a pending initial exists only when
        // an odd number of keys precede the cursor; it is the key before it.
        guard cursor >= 1, cursor <= raw.count, cursor % 2 == 1 else { return [] }
        let keyIndex = raw.index(raw.startIndex, offsetBy: cursor - 1)
        guard let key = raw[keyIndex].lowercased().first else { return [] }
        if let cached = shuangpinFinalHighlightCache[key] { return cached }
        let highlights = MicrosoftShuangpin.finalKeyCandidates.filter { finalKey in
            let syllable = MicrosoftShuangpin.expand(String([key, finalKey]))
            // A valid syllable yields a Han candidate. Invalid combos only
            // echo the literal letters back (text == the ASCII pinyin), so
            // require at least one non-ASCII (Chinese) candidate here.
            return decoder.syllableCandidates(syllable).contains { candidate in
                candidate.text.contains { !$0.isASCII }
            }
        }
        let set = Set(highlights)
        shuangpinFinalHighlightCache[key] = set
        return set
    }

    private func enteredKeyGroups(for syllables: [String]) -> [String] {
        var remaining = Substring(raw)
        var groups: [String] = []
        for syllable in syllables {
            switch inputScheme {
            case .microsoftShuangpin:
                guard remaining.count >= 2 else { return [] }
                groups.append(String(remaining.prefix(2)))
                remaining.removeFirst(2)
            case .fullPinyin:
                // Apostrophes are input keys too; associate one with the
                // syllable that follows it so the displayed label is literal.
                var group = ""
                if remaining.first == "'" {
                    group.append("'")
                    remaining.removeFirst()
                }
                guard remaining.count >= syllable.count else { return [] }
                group += String(remaining.prefix(syllable.count))
                remaining.removeFirst(syllable.count)
                groups.append(group)
            }
        }
        return groups
    }

    private func rawLength(forSyllables count: Int, units: String) -> Int {
        guard count > 0 else { return 0 }
        let syllables = units.split(separator: "'").map(String.init)
        let groups = enteredKeyGroups(for: syllables)
        guard groups.count >= count else { return 0 }
        return groups.prefix(count).reduce(0) { $0 + $1.count }
    }

    private func renderedText(_ decoded: String) -> String {
        let base = Array(decoded)
        let anchors = anchorSegments.sorted {
            $0.syllableRange.lowerBound < $1.syllableRange.lowerBound
        }
        var output = ""
        var syllable = 0
        var anchorIndex = 0
        while syllable < base.count {
            if anchorIndex < anchors.count,
               anchors[anchorIndex].syllableRange.lowerBound == syllable {
                let anchor = anchors[anchorIndex]
                output += anchor.text
                syllable = anchor.syllableRange.upperBound
                anchorIndex += 1
            } else {
                output.append(base[syllable])
                syllable += 1
            }
        }
        return output
    }

    private func literalTextWithAnchors() -> String {
        guard let units = candidates.first?.units, !anchorSegments.isEmpty else {
            return raw
        }
        let syllables = units.split(separator: "'").map(String.init)
        let groups = enteredKeyGroups(for: syllables)
        guard groups.count == syllables.count else { return raw }
        let anchors = Dictionary(uniqueKeysWithValues: anchorSegments.map {
            ($0.syllableRange.lowerBound, $0)
        })
        var output = ""
        var syllable = 0
        while syllable < groups.count {
            if let anchor = anchors[syllable] {
                output += anchor.text
                syllable = anchor.syllableRange.upperBound
            } else {
                output += groups[syllable]
                syllable += 1
            }
        }
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

    func updateHostContext(from text: String) {
        let tokens = decoder.tokenize(text)
        guard hostContextTokens != tokens else { return }
        hostContextTokens = tokens
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
        let syllables = max(1, candidate.units.split(separator: "'")
            .filter { !$0.isEmpty }.count)
        let sourceKeys = String(raw.prefix(min(consumed, raw.count)))
        appendPrefixSegment(
            text: candidate.text,
            keyCount: consumed,
            syllableCount: syllables,
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
        guard inputScheme == .microsoftShuangpin else { return candidate.consumed }
        // Sime returns pinyin units (for example xiao'guo), while each
        // Microsoft Shuangpin syllable was entered with two keyboard keys.
        let syllableCount = candidate.units.split(separator: "'")
            .filter { !$0.isEmpty }
            .count
        return syllableCount > 0 ? syllableCount * 2 : candidate.consumed
    }

    func selectDisplayed(_ index: Int) -> String? {
        if !isComposing, predictionCandidates.indices.contains(index) {
            let prediction = predictionCandidates[index]
            publishPredictions(for: prediction.tokens)
            return prediction.text
        }
        if let active = activeCharacterIndex,
           replacementCandidates.indices.contains(index),
           let top = candidates.first {
            let replacement = replacementCandidates[index]
            let span = max(1, replacement.units.split(separator: "'")
                .filter { !$0.isEmpty }.count)
            let relativeActive = active - prefixText.count
            let syllables = top.units.split(separator: "'").map(String.init)
            guard relativeActive >= 0,
                  relativeActive + span <= syllables.count else { return nil }

            let keyStart = rawLength(forSyllables: relativeActive,
                                     units: top.units)
            let keyEnd = rawLength(forSyllables: relativeActive + span,
                                   units: top.units)
            guard keyEnd > keyStart else { return nil }
            let selectedRange = relativeActive..<(relativeActive + span)
            anchorSegments.removeAll { $0.syllableRange.overlaps(selectedRange) }
            anchorSegments.append(CompositionSegment(
                sourceKeyRange: keyStart..<keyEnd,
                syllableRange: selectedRange,
                text: replacement.text,
                tokens: replacement.tokens
            ))
            anchorSegments.sort {
                $0.syllableRange.lowerBound < $1.syllableRange.lowerBound
            }
            activeCharacterIndex = nil
            activeShowsKeys = false
            replacementCandidates = []
            refresh()

            let next = selectedRange.upperBound
            if next < syllables.count {
                activateCharacter(prefixText.count + next)
            }
            return nil
        }
        return select(index)
    }

    func activateCharacter(_ index: Int) {
        // Second tap on the already-highlighted character reveals its literal
        // typed keys; the first tap only selects/colors it (below) and lists
        // replacement candidates. Keep the candidates untouched here.
        if index == activeCharacterIndex, !activeShowsKeys {
            activeShowsKeys = true
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
        let syllables = top.units.split(separator: "'").map(String.init)
        let relativeIndex = index - prefixText.count
        guard syllables.indices.contains(relativeIndex) else { return }
        activeCharacterIndex = index
        activeShowsKeys = false
        let current = renderedText(top.text)
        let fixedPrefix = String(Array(current).prefix(relativeIndex))
        let nextAnchor = anchorSegments
            .map(\.syllableRange.lowerBound)
            .filter { $0 > relativeIndex }
            .min() ?? syllables.count
        let maximumSpan = max(1, nextAnchor - relativeIndex)
        replacementCandidates = decoder.correctionCandidates(
            top.units,
            fixedPrefix: fixedPrefix,
            prefixSyllables: relativeIndex,
            limit: 60,
            expansion: inputScheme != .microsoftShuangpin
        ).filter { candidate in
            let span = max(1, candidate.units.split(separator: "'")
                .filter { !$0.isEmpty }.count)
            guard span <= maximumSpan else { return false }
            // Correction candidates begin at the active syllable, so their
            // finals are locked just like normal decode candidates.
            return unitsMatchLockedFinals(candidate.units, fromSyllable: relativeIndex)
        }
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

    private func publishPredictions(for tokens: [UInt32]) {
        guard !tokens.isEmpty else {
            predictionCandidates = []
            return
        }
        contextTokens = Array(((hostContextTokens ?? contextTokens) + tokens).suffix(32))
        predictionCandidates = decoder.predict(contextTokens, limit: 9)
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
        // Chinese-English mixed input: split at the first uppercase letter.
        // The lowercase prefix decodes as pinyin; from the first capital to
        // the end is a literal English tail. Decoding only the prefix keeps
        // the pinyin segmentation clean (the tail must not pollute it).
        let upperIndex = raw.firstIndex(where: { $0.isUppercase })
        let pinyinPart = upperIndex.map { String(raw[..<$0]) } ?? raw
        let englishTail = upperIndex.map { String(raw[$0...]) } ?? ""

        var result: [Candidate] = []
        var pinyinUnits = ""
        if !pinyinPart.isEmpty {
            let lower = pinyinPart.lowercased()
            let context = hostContextTokens ?? contextTokens
            var chinese: [Candidate] = []
            if inputScheme == .microsoftShuangpin {
                let keys = Array(lower)
                let hasLoneInitial = keys.count % 2 == 1
                // Delimit every syllable with an apostrophe. Each Shuangpin
                // syllable is exactly two keys, so this hands the engine exact
                // boundaries and stops it re-segmenting a syllable (pie -> pi+e,
                // so rong'yi'pie'jiao stays 撇, not 被阿). A trailing lone key is
                // a single initial (v/i/u -> zh/ch/sh) that still expands.
                var syllables = stride(from: 0, to: keys.count - 1, by: 2).map {
                    MicrosoftShuangpin.expand(String(keys[$0..<$0 + 2]))
                }
                if hasLoneInitial {
                    syllables.append(MicrosoftShuangpin.initial(for: keys.last!))
                }
                let input = syllables.joined(separator: "'")
                // Expand only to complete a trailing lone initial; complete
                // syllables must not expand (else li -> 柳州).
                chinese = input.isEmpty ? [] : decoder.decode(
                    input, context: context, limit: 60, expansion: hasLoneInitial)
                chinese = chinese.filter { matchesLockedShuangpinFinals($0) }
            } else {
                // Full pinyin expands for abbreviation/tail completion.
                chinese = lower.isEmpty ? [] : decoder.decode(
                    lower, context: context, limit: 60, expansion: true)
            }
            if englishTail.isEmpty {
                result = chinese
            } else {
                // Append the literal English tail to each Chinese path. Units
                // are cleared and consumed spans the whole buffer so one
                // commit takes it all through the normal segment path.
                result = chinese.map {
                    Candidate(text: $0.text + englishTail, consumed: raw.count,
                              tokens: $0.tokens, units: "")
                }
            }
            pinyinUnits = chinese.first?.units ?? ""
        }
        // The literal typed string (case preserved; raw keys in Shuangpin) is
        // the same kind of candidate as a word. A leading capital signals
        // English intent and ranks it first; otherwise it trails the Chinese
        // so a clean pinyin sentence looks free of English, and surfaces on
        // top only when no Chinese path exists.
        if !raw.isEmpty {
            let literal = Candidate(text: raw, consumed: raw.count,
                                    tokens: [], units: "", isEnglish: true)
            if raw.first?.isUppercase == true {
                result.insert(literal, at: 0)
            } else {
                result.append(literal)
            }
        }
        candidates = result
        displayGroups = computeDisplayGroups(pinyinPart: pinyinPart,
                                             englishTail: englishTail,
                                             pinyinUnits: pinyinUnits)
    }

    /// Segment `raw` to line up 1:1 with the top candidate's characters: the
    /// pinyin prefix splits into syllables (two keys for Shuangpin, the pinyin
    /// length for full pinyin), while the literal English tail splits one key
    /// per character. Display only — never changes commit consumption.
    private func computeDisplayGroups(pinyinPart: String, englishTail: String,
                                      pinyinUnits: String) -> [String] {
        var parts: [String] = []
        if !pinyinPart.isEmpty {
            let syllables = pinyinUnits.split(separator: "'").map(String.init)
            if syllables.isEmpty {
                // No Chinese decode: keep the pinyin as one ungrouped chunk.
                parts.append(pinyinPart)
            } else {
                var remaining = Substring(pinyinPart)
                for syllable in syllables {
                    if remaining.isEmpty { break }
                    var group = ""
                    if remaining.first == "'" { group.append("'"); remaining.removeFirst() }
                    let want = inputScheme == .microsoftShuangpin ? 2 : syllable.count
                    let take = min(want, remaining.count)
                    group += String(remaining.prefix(take))
                    remaining.removeFirst(take)
                    parts.append(group)
                }
                if !remaining.isEmpty { parts.append(String(remaining)) }
            }
        }
        // The literal English tail aligns one first-row character per key.
        parts.append(contentsOf: englishTail.map(String.init))
        return parts
    }

    /// The exact pinyin of every *completed* Microsoft Shuangpin syllable.
    /// Each syllable is two keys, so a trailing odd key is still incomplete
    /// and its final is not yet locked.
    private func lockedShuangpinSyllables() -> [String] {
        let keys = Array(raw)
        var syllables: [String] = []
        var index = 0
        while index + 1 < keys.count {
            syllables.append(MicrosoftShuangpin.expand(String(keys[index...index + 1])))
            index += 2
        }
        return syllables
    }

    /// True unless the syllables of `units` (which begin at syllable `offset`
    /// of the composition) shorten or otherwise disagree with an already
    /// locked Shuangpin final. Syllables past the completed region — the
    /// trailing incomplete key — are unconstrained.
    private func unitsMatchLockedFinals(_ units: String, fromSyllable offset: Int) -> Bool {
        guard inputScheme == .microsoftShuangpin else { return true }
        let syllables = units.split(separator: "'").map(String.init)
        let locked = lockedShuangpinSyllables()
        for index in 0..<syllables.count {
            let lockedIndex = offset + index
            guard lockedIndex < locked.count else { break }
            if syllables[index] != locked[lockedIndex] { return false }
        }
        return true
    }

    /// In Shuangpin a completed syllable's final is fixed, so the decoder must
    /// not offer paths that shorten it (for example `xi'hu`/`xi'hua` for the
    /// typed `xi`+`huan`). Reject any multi-syllable candidate whose syllables
    /// disagree with the locked finals; single-syllable character alternatives
    /// (which may target either end of the sentence) always pass through.
    private func matchesLockedShuangpinFinals(_ candidate: Candidate) -> Bool {
        let syllables = candidate.units.split(separator: "'").map(String.init)
        guard syllables.count >= 2 else { return true }
        return unitsMatchLockedFinals(candidate.units, fromSyllable: 0)
    }
}
