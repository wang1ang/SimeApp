import XCTest
@testable import Sime

private final class RecordingPinyinDecoder: PinyinDecoder {
    var shuangpinIndexName: String? = "sime.sp"
    var decodeCalls: [(pinyin: String, context: [UInt32], limit: Int)] = []
    var decodeExpansions: [Bool] = []
    var correctionExpansions: [Bool] = []
    var correctionCalls: [(pinyin: String, fixedPrefix: String,
                           prefixSyllables: Int, expansion: Bool)] = []
    var predictionCalls: [(context: [UInt32], limit: Int)] = []
    var decodeResult: (String) -> [Candidate] = { _ in [] }
    var correctionResult: [Candidate] = []
    var correctionResultsByPrefix: [Int: [Candidate]] = [:]
    var tokenizedText: [String: [UInt32]] = [:]
    var predictionResult: ([UInt32]) -> [Candidate] = { _ in [] }

    func decode(_ pinyin: String, limit: Int) -> [Candidate] {
        decode(pinyin, context: [], limit: limit)
    }

    func decode(_ pinyin: String, context: [UInt32], limit: Int) -> [Candidate] {
        decode(pinyin, context: context, limit: limit, expansion: true)
    }

    func decode(_ pinyin: String, context: [UInt32], limit: Int,
                expansion: Bool) -> [Candidate] {
        decodeCalls.append((pinyin, context, limit))
        decodeExpansions.append(expansion)
        return Array(decodeResult(pinyin).prefix(limit))
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
        correctionExpansions.append(expansion)
        correctionCalls.append((pinyin, fixedPrefix, prefixSyllables, expansion))
        return Array((correctionResultsByPrefix[prefixSyllables] ?? correctionResult).prefix(limit))
    }

    func tokenize(_ text: String) -> [UInt32] {
        tokenizedText[text] ?? []
    }

    func predict(_ context: [UInt32], limit: Int) -> [Candidate] {
        predictionCalls.append((context, limit))
        return Array(predictionResult(context).prefix(limit))
    }
}

final class CompositionCandidateSelectionTests: XCTestCase {
    func testActiveCorrectionLabelRetainsLiteralShuangpinKeys() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { raw in
            raw == "xcgo"
                ? [Candidate(text: "小国", consumed: 4, tokens: [31, 32], units: "",
                             segmentKeys: [2, 2], segmentChars: [1, 1])]
                : []
        }
        decoder.correctionResult = [
            Candidate(text: "晓", consumed: 0, tokens: [33], units: "",
                      segmentKeys: [2], segmentChars: [1])
        ]
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        "xcgo".forEach { composition.append(String($0)) }
        composition.activateCharacter(0)

        // First tap only highlights the character; it keeps the decoded glyph
        // and lists replacement candidates, but does not reveal the raw keys.
        XCTAssertEqual(composition.activeCharacterIndex, 0)
        XCTAssertNil(composition.activeEnteredKeys)
        XCTAssertEqual(composition.displayCandidates.map(\.text), ["晓"])

        // Second tap on the same character reveals its literal two-key code.
        composition.activateCharacter(0)

        XCTAssertEqual(composition.activeEnteredKeys, "xc")
        XCTAssertEqual(composition.displayCandidates.map(\.text), ["晓"])
    }

    func testActiveCorrectionRetainsTrailingInitialForPinyinEditing() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "nih"
                ? [Candidate(text: "你好", consumed: 3, tokens: [1, 2],
                             units: "ni'hao")]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        "nih".forEach { composition.append(String($0)) }
        composition.activateCharacter(1)
        composition.activateCharacter(1)

        XCTAssertEqual(composition.activeEnteredKeys, "h")
        XCTAssertEqual(composition.cursor, 3)
    }

    func testActiveCorrectionRetainsTrailingShuangpinInitialForPinyinEditing() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { _ in
            [Candidate(text: "你好", consumed: 3, tokens: [1, 2], units: "",
                       segmentKeys: [2, 1], segmentChars: [1, 1])]
        }
        decoder.correctionResult = [
            Candidate(text: "号", consumed: 0, tokens: [3], units: "",
                      segmentKeys: [1], segmentChars: [1])
        ]
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        "nih".forEach { composition.append(String($0)) }
        composition.activateCharacter(1)
        composition.activateCharacter(1)

        XCTAssertEqual(composition.activeEnteredKeys, "h")
        XCTAssertEqual(composition.cursor, 3)
    }

    func testShuangpinHighlightsDecoderValidatedFinalKeys() {
        let validCodes: Set<String> = ["xi", "xc", "xm", "xx", "xn"]
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { raw in
            if raw == "x" {
                return [Candidate(text: "小", consumed: 1, tokens: [], units: "",
                                  segmentKeys: [1], segmentChars: [1])]
            }
            if validCodes.contains(raw) {
                return [Candidate(text: "小", consumed: raw.count, tokens: [], units: "",
                                  segmentKeys: [raw.count], segmentChars: [1])]
            }
            return [Candidate(text: raw, consumed: raw.count, tokens: [], units: "")]
        }
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        composition.append("x")
        XCTAssertEqual(composition.shuangpinFinalKeyHighlights(), Set("icmxn"))
        composition.append("i")
        XCTAssertTrue(composition.shuangpinFinalKeyHighlights().isEmpty)
    }

    func testShuangpinRejectsDecoderSpanThatCoversMultipleCharacters() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { raw in
            if raw == "w" {
                return [Candidate(text: "无", consumed: 1, tokens: [], units: "",
                                  segmentKeys: [1], segmentChars: [1])]
            }
            if raw == "wy" {
                return [Candidate(text: "无碍", consumed: 2, tokens: [], units: "",
                                  segmentKeys: [2], segmentChars: [2])]
            }
            return [Candidate(text: raw, consumed: raw.count, tokens: [], units: "")]
        }
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)
        composition.append("w")
        XCTAssertFalse(composition.shuangpinFinalKeyHighlights().contains("y"))
    }

    func testFullPinyinNeverHighlightsFinalKeys() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { _ in
            [Candidate(text: "小", consumed: 1, tokens: [])]
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        composition.append("x")
        XCTAssertTrue(composition.shuangpinFinalKeyHighlights().isEmpty)
    }

    func testOddShuangpinKeyRemainsUntilPairCompletes() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { raw in
            raw == "xcgo"
                ? [Candidate(text: "小国", consumed: 4, tokens: [31, 32], units: "",
                             segmentKeys: [2, 2], segmentChars: [1, 1])]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        "xcg".forEach { composition.append(String($0)) }

        XCTAssertEqual(composition.raw, "xcg")
        XCTAssertEqual(composition.cursor, 3)
        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "xcg")
        XCTAssertEqual(composition.candidates.map(\.text), ["xcg"])
        XCTAssertEqual(composition.candidates.first?.isEnglish, true)

        composition.append("o")

        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "xcgo")
        XCTAssertEqual(composition.select(0), "小国")
        XCTAssertFalse(composition.isComposing)
    }


    func testLongShuangpinSentenceUsesDecoderProvidedSegments() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { raw in
            raw == "womfdevsgo"
                ? [Candidate(text: "我们的中国", consumed: raw.count,
                             tokens: [1, 2, 3, 4, 5], units: "",
                             segmentKeys: [2, 2, 2, 2, 2],
                             segmentChars: [1, 1, 1, 1, 1])]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        "womfdevsgo".forEach { composition.append(String($0)) }

        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "womfdevsgo")
        XCTAssertEqual(composition.sentencePreview, "我们的中国")
        XCTAssertEqual(composition.select(0), "我们的中国")
        XCTAssertEqual(decoder.predictionCalls.last?.context, [1, 2, 3, 4, 5])
    }

    func testShuangpinIndexPreservesDecoderCandidateOrder() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { raw in
            guard raw == "xihr" else { return [] }
            return [
                Candidate(text: "喜欢", consumed: 4, tokens: [1, 2], units: "",
                          segmentKeys: [2, 2], segmentChars: [1, 1]),
                Candidate(text: "喜", consumed: 2, tokens: [1], units: "",
                          segmentKeys: [2], segmentChars: [1]),
                Candidate(text: "欢", consumed: 2, tokens: [2], units: "",
                          segmentKeys: [2], segmentChars: [1])
            ]
        }
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)
        "xihr".forEach { composition.append(String($0)) }
        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "xihr")
        XCTAssertEqual(composition.candidates.map(\.text), ["喜欢", "喜", "欢", "xihr"])
    }

    func testShuangpinIndexReceivesCompleteRawCodes() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { raw in
            raw == "livb"
                ? [Candidate(text: "利州", consumed: raw.count, tokens: [], units: "",
                             segmentKeys: [2, 2], segmentChars: [1, 1])]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)
        "livb".forEach { composition.append(String($0)) }
        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "livb")
        XCTAssertEqual(composition.candidates.first?.text, "利州")
    }

    func testShuangpinCorrectionUsesRawKeyColumnAndDecoderResults() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { raw in
            raw == "uiyu"
                ? [Candidate(text: "是语", consumed: raw.count, tokens: [1, 2], units: "",
                             segmentKeys: [2, 2], segmentChars: [1, 1])]
                : []
        }
        decoder.correctionResult = [
            Candidate(text: "始于", consumed: 4, tokens: [3, 4], units: "",
                      segmentKeys: [2, 2], segmentChars: [1, 1]),
            Candidate(text: "视域", consumed: 4, tokens: [9, 10], units: "",
                      segmentKeys: [2, 2], segmentChars: [1, 1])
        ]
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)
        "uiyu".forEach { composition.append(String($0)) }
        composition.activateCharacter(0)

        XCTAssertEqual(decoder.correctionCalls.last?.pinyin, "uiyu")
        XCTAssertEqual(decoder.correctionCalls.last?.prefixSyllables, 0)
        XCTAssertEqual(composition.displayCandidates.map(\.text), ["始于", "视域"])
    }


    func testNormalCandidateOrderIsNotResortedByComposition() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { _ in
            [
                Candidate(text: "中国", consumed: 8, tokens: [1], units: "zhong'guo", score: -6),
                Candidate(text: "中过", consumed: 8, tokens: [2, 3], units: "zhong'guo", score: -13),
                Candidate(text: "种过", consumed: 8, tokens: [4], units: "zhong'guo", score: -15)
            ]
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        "zhongguo".forEach { composition.append(String($0)) }

        XCTAssertEqual(composition.displayCandidates.map(\.text), ["中国", "中过", "种过", "zhongguo"])
        XCTAssertEqual(composition.displayCandidates.map(\.score), [-6, -13, -15, 0])
    }

    func testLiteralFallbackPreservesDecoderOrderForEitherCase() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { raw in
            [Candidate(text: "engine-\(raw)", consumed: raw.count, tokens: [], units: raw),
             Candidate(text: "啊", consumed: raw.count, tokens: [1], units: "a")]
        }

        for raw in ["app", "App"] {
            let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
            raw.forEach { composition.append(String($0)) }
            XCTAssertEqual(decoder.decodeCalls.last?.pinyin, raw)
            XCTAssertEqual(composition.candidates.map(\.text), ["engine-\(raw)", "啊", raw])
        }
    }

    func testUppercaseInputPassesUnchangedAndKeepsDecoderOrder() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { raw in
            guard raw == "Hi" else { return [] }
            return [Candidate(text: "你好", consumed: 2, tokens: [1, 2], units: "ni'hao"),
                    Candidate(text: "Hi", consumed: 2, tokens: [], units: "Hi", isEnglish: true)]
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        ["H", "i"].forEach { composition.append($0) }
        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "Hi")
        XCTAssertEqual(composition.candidates.map(\.text), ["你好", "Hi"])
        XCTAssertEqual(composition.select(0), "你好")
        XCTAssertFalse(composition.isComposing)
    }

    func testShuangpinLiteralEnglishCandidateIsRawKeys() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { _ in [] }
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        // The literal fallback is returned by the decoder adapter for any
        // input the engine cannot decode; it preserves the complete raw keys.
        ["A", "p", "p"].forEach { composition.append($0) }
        XCTAssertEqual(composition.candidates.first?.text, "App")
        XCTAssertEqual(composition.select(0), "App")
        XCTAssertFalse(composition.isComposing)
    }

    func testMixedPinyinAndUppercaseEnglishAreDecodedTogether() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { raw in
            raw == "nihaoApp"
                ? [Candidate(text: "你好App", consumed: raw.count, tokens: [1, 2],
                             units: "ni'hao'App")]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        "nihaoApp".forEach { composition.append(String($0)) }

        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "nihaoApp")
        XCTAssertEqual(composition.candidates.first?.text, "你好App")
        XCTAssertEqual(composition.preedit, "ni hao App")
        XCTAssertEqual(composition.select(0), "你好App")
        XCTAssertFalse(composition.isComposing)
    }

    func testMixedEnglishPrefixMapsChineseTapToItsSyllable() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { _ in
            [Candidate(text: "fix一下", consumed: 8, tokens: [], units: "fix'yi'xia")]
        }
        decoder.correctionResultsByPrefix[1] = [
            Candidate(text: "一", consumed: 2, tokens: [], units: "yi")
        ]
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "fixyixia".forEach { composition.append(String($0)) }

        composition.activateCharacter(3)
        composition.activateCharacter(3)

        XCTAssertEqual(composition.activeCharacterIndex, 3)
        XCTAssertEqual(composition.displayCandidates.first?.text, "一")
        XCTAssertEqual(composition.activeEnteredKeys, "yi")
        XCTAssertEqual(composition.selectionLocation, 6)
    }

    func testMixedEnglishFinalCorrectionCommitsCorrectSentence() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { _ in
            [Candidate(text: "fix一下", consumed: 8, tokens: [], units: "fix'yi'xia")]
        }
        decoder.correctionResultsByPrefix[2] = [
            Candidate(text: "塔", consumed: 0, tokens: [], units: "ta")
        ]
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "fixyixia".forEach { composition.append(String($0)) }
        composition.activateCharacter(4)
        XCTAssertEqual(composition.selectDisplayed(0), "fix一塔")
        XCTAssertFalse(composition.isComposing)
    }

    func testMixedEnglishAnchorLiteralCommitPreservesWord() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { _ in
            [Candidate(text: "item他", consumed: 6, tokens: [], units: "item'ta")]
        }
        decoder.correctionResult = [
            Candidate(text: "它", consumed: 0, tokens: [], units: "item")
        ]
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "itemta".forEach { composition.append(String($0)) }
        composition.activateCharacter(0)
        XCTAssertNil(composition.selectDisplayed(0))
        XCTAssertEqual(composition.commitPreeditLiterally(), "它他")
    }

}

final class CompositionContextTests: XCTestCase {
    func testHostContextIsTokenizedAndPassedToDecode() {
        let decoder = RecordingPinyinDecoder()
        decoder.tokenizedText["已经输入"] = [7, 8]
        decoder.decodeResult = { _ in
            [Candidate(text: "你", consumed: 2, tokens: [9], units: "ni")]
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        composition.updateHostContext(from: "已经输入")
        composition.append("n")
        composition.append("i")

        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "ni")
        XCTAssertEqual(decoder.decodeCalls.last?.context, [7, 8])
        XCTAssertEqual(decoder.decodeCalls.last?.limit, 60)
    }

    func testLocalCommittedTokensFeedTheNextComposition() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            switch pinyin {
            case "ni":
                return [Candidate(text: "你", consumed: 2, tokens: [11], units: "ni")]
            case "hao":
                return [Candidate(text: "好", consumed: 3, tokens: [22], units: "hao")]
            default:
                return []
            }
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        "ni".forEach { composition.append(String($0)) }
        XCTAssertEqual(composition.select(0), "你")
        "hao".forEach { composition.append(String($0)) }

        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "hao")
        XCTAssertEqual(decoder.decodeCalls.last?.context, [11])
    }

    func testHostContextSupersedesTheLocalFallbackForDecode() {
        let decoder = RecordingPinyinDecoder()
        decoder.tokenizedText["宿主文本"] = [90, 91]
        decoder.decodeResult = { pinyin in
            [Candidate(text: pinyin, consumed: pinyin.count, tokens: [11], units: pinyin)]
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        "ni".forEach { composition.append(String($0)) }
        XCTAssertEqual(composition.select(0), "ni")
        composition.updateHostContext(from: "宿主文本")
        composition.append("h")

        XCTAssertEqual(decoder.decodeCalls.last?.context, [90, 91])
    }

    func testEquivalentHostTokensDoNotDecodeAgain() {
        let decoder = RecordingPinyinDecoder()
        decoder.tokenizedText["第一种文本"] = [7, 8]
        decoder.tokenizedText["相同分词文本"] = [7, 8]
        decoder.decodeResult = { _ in
            [Candidate(text: "你", consumed: 2, tokens: [9], units: "ni")]
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "ni".forEach { composition.append(String($0)) }

        composition.updateHostContext(from: "第一种文本")
        let callsAfterFirstUpdate = decoder.decodeCalls.count
        composition.updateHostContext(from: "相同分词文本")

        XCTAssertEqual(decoder.decodeCalls.count, callsAfterFirstUpdate)
        XCTAssertEqual(decoder.decodeCalls.last?.context, [7, 8])
    }

    func testPredictionContextIsBoundedToTheMostRecent32Tokens() {
        let decoder = RecordingPinyinDecoder()
        let tokens = (0..<40).map(UInt32.init)
        decoder.decodeResult = { _ in
            [Candidate(text: "长上下文", consumed: 2, tokens: tokens, units: "ni")]
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        "ni".forEach { composition.append(String($0)) }
        XCTAssertEqual(composition.select(0), "长上下文")

        XCTAssertEqual(decoder.predictionCalls.last?.context, Array(tokens.suffix(32)))
    }

    func testPredictionSelectionContinuesTheLocalTokenContext() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { _ in
            [Candidate(text: "你", consumed: 2, tokens: [11], units: "ni")]
        }
        decoder.predictionResult = { context in
            if context == [11] {
                return [Candidate(text: "好", consumed: 0, tokens: [22])]
            }
            if context == [11, 22] {
                return [Candidate(text: "吗", consumed: 0, tokens: [33])]
            }
            return []
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        "ni".forEach { composition.append(String($0)) }
        XCTAssertEqual(composition.select(0), "你")
        XCTAssertEqual(composition.displayCandidates.map(\.text), ["好"])
        XCTAssertEqual(composition.selectDisplayed(0), "好")

        XCTAssertEqual(decoder.predictionCalls.map(\.context), [[11], [11, 22]])
        XCTAssertEqual(composition.displayCandidates.map(\.text), ["吗"])
    }

    func testPredictionCanBeDisabled() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { _ in
            [Candidate(text: "你", consumed: 2, tokens: [11], units: "ni")]
        }
        decoder.predictionResult = { _ in
            [Candidate(text: "好", consumed: 0, tokens: [22])]
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        composition.predictionEnabled = false

        "ni".forEach { composition.append(String($0)) }
        XCTAssertEqual(composition.select(0), "你")
        // No prediction query is issued and the bar stays empty when off.
        XCTAssertTrue(decoder.predictionCalls.isEmpty)
        XCTAssertTrue(composition.displayCandidates.isEmpty)
    }

    func testCompletionPredictionShowsAndInsertsOnlyTheTail() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { _ in
            [Candidate(text: "狐", consumed: 2, tokens: [11], units: "hu")]
        }
        // Association completion: full word 狐狸 with the leading 狐 already
        // committed (consumed == 1).
        decoder.predictionResult = { _ in
            [Candidate(text: "狐狸", consumed: 1, tokens: [99])]
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        "hu".forEach { composition.append(String($0)) }
        XCTAssertEqual(composition.select(0), "狐")
        // The bar shows only the inserted tail, never the base character.
        XCTAssertEqual(composition.displayCandidates.map(\.text), ["狸"])
        // Selecting inserts just the tail.
        XCTAssertEqual(composition.selectDisplayed(0), "狸")
    }

    func testDisablingPredictionClearsExistingCandidates() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { _ in
            [Candidate(text: "你", consumed: 2, tokens: [11], units: "ni")]
        }
        decoder.predictionResult = { _ in
            [Candidate(text: "好", consumed: 0, tokens: [22])]
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        "ni".forEach { composition.append(String($0)) }
        XCTAssertEqual(composition.select(0), "你")
        XCTAssertEqual(composition.displayCandidates.map(\.text), ["好"])

        composition.predictionEnabled = false
        XCTAssertTrue(composition.displayCandidates.isEmpty)
    }
}

final class CompositionEditingTests: XCTestCase {
    func testSpaceCommitsTopSentenceAndDiscardsPartialConsumptionTail() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            [Candidate(text: "你好", consumed: 2, tokens: [1, 2], units: "ni'hao")]
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        "nihao".forEach { composition.append(String($0)) }

        XCTAssertEqual(composition.commitBestOrRaw(), "你好")
        XCTAssertFalse(composition.isComposing)
        XCTAssertEqual(composition.raw, "")
        XCTAssertEqual(composition.candidates.count, 0)
    }

    func testSelectingFinalMultiSyllableCorrectionCommitsImmediately() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "jiyixia"
                ? [Candidate(text: "及以下", consumed: pinyin.count,
                             tokens: [1, 2, 3], units: "ji'yi'xia")]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        "jiyixia".forEach { composition.append(String($0)) }
        decoder.correctionResultsByPrefix = [
            0: [Candidate(text: "记", consumed: 0, tokens: [4], units: "ji")],
            1: [Candidate(text: "一下", consumed: 0, tokens: [5, 6], units: "yi'xia")]
        ]
        composition.activateCharacter(0)
        XCTAssertNil(composition.selectDisplayed(0))
        XCTAssertEqual(composition.activeCharacterIndex, 1)

        XCTAssertEqual(composition.selectDisplayed(0), "记一下")
        XCTAssertFalse(composition.isComposing)
    }

    func testSelectingFinalCorrectionCharacterCommitsImmediately() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "nihao"
                ? [Candidate(text: "你好", consumed: pinyin.count,
                             tokens: [1, 2], units: "ni'hao")]
                : []
        }
        decoder.correctionResult = [
            Candidate(text: "号", consumed: 0, tokens: [3], units: "hao")
        ]
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        "nihao".forEach { composition.append(String($0)) }
        composition.activateCharacter(1)

        XCTAssertEqual(composition.selectDisplayed(0), "你号")
        XCTAssertFalse(composition.isComposing)
    }

    func testSelectingFinalCorrectionSpanLeavesTrailingSyllablesEditable() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { raw in
            raw == "wjqrlixmma"
                ? [Candidate(text: "完全离线吗", consumed: raw.count,
                             tokens: [1, 2, 3, 4, 5], units: "",
                             segmentKeys: [2, 2, 2, 2, 2],
                             segmentChars: [1, 1, 1, 1, 1])]
                : []
        }
        decoder.correctionResult = [
            Candidate(text: "离线", consumed: 0, tokens: [30, 31], units: "",
                      segmentKeys: [2, 2], segmentChars: [1, 1])
        ]
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        "wjqrlixmma".forEach { composition.append(String($0)) }
        composition.activateCharacter(2)
        XCTAssertNil(composition.selectDisplayed(0))

        // Return commits the decoded sentence with the anchor, not the raw keys.
        XCTAssertEqual(composition.commitPreeditLiterally(), "完全离线吗")
        XCTAssertFalse(composition.isComposing)
    }

    func testCorrectionInsideMultiSyllableAnchorKeepsUntouchedSyllables() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "shiyushurufama"
                ? [Candidate(text: "始于输入法吗", consumed: pinyin.count,
                             tokens: [1, 2, 3, 4, 5, 6],
                             units: "shi'yu'shu'ru'fa'ma")]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "shiyushurufama".forEach { composition.append(String($0)) }

        // Select a five-syllable correction and leave the trailing 吗 editable.
        decoder.correctionResult = [
            Candidate(text: "是与输入法", consumed: 14,
                      tokens: [6, 7], units: "shi'yu'shu'ru'fa")
        ]
        composition.activateCharacter(0)
        XCTAssertNil(composition.selectDisplayed(0))

        // Re-choosing one interior character must split the anchor, not drop
        // it: 是 and 输入法 stay locked even with unaligned tokens.
        decoder.correctionResult = [
            Candidate(text: "语", consumed: 4, tokens: [11], units: "yu")
        ]
        composition.activateCharacter(1)
        XCTAssertNil(composition.selectDisplayed(0))

        XCTAssertEqual(composition.commitPreeditLiterally(), "是语输入法吗")
    }

    func testDecoderBindingKeepsFullPinyinAndShuangpinInputsDistinct() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { raw in
            if raw == "uiyu" {
                return [Candidate(text: "是语", consumed: 4, tokens: [1, 2], units: "",
                                  segmentKeys: [2, 2], segmentChars: [1, 1])]
            }
            if raw == "nihao" {
                return [Candidate(text: "你好", consumed: 5, tokens: [1, 2],
                                  units: "ni'hao")]
            }
            return []
        }
        decoder.correctionResult = [
            Candidate(text: "已于", consumed: 4, tokens: [3, 4], units: "",
                      segmentKeys: [2, 2], segmentChars: [1, 1])
        ]

        let shuangpin = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)
        "uiyu".forEach { shuangpin.append(String($0)) }
        shuangpin.activateCharacter(0)
        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "uiyu")
        XCTAssertEqual(decoder.correctionCalls.last?.pinyin, "uiyu")
        XCTAssertEqual(decoder.correctionCalls.last?.prefixSyllables, 0)

        decoder.correctionResult = [
            Candidate(text: "拟好", consumed: 5, tokens: [5, 6], units: "ni'hao")
        ]
        let fullPinyin = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "nihao".forEach { fullPinyin.append(String($0)) }
        fullPinyin.activateCharacter(0)
        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "nihao")
        XCTAssertEqual(decoder.correctionCalls.last?.pinyin, "ni'hao")
    }


    func testDeleteRemovesTheKeyBeforeTheCompositionCursor() {
        let composition = Composition(
            decoder: RecordingPinyinDecoder(), inputScheme: .fullPinyin
        )
        "nihao".forEach { composition.append(String($0)) }
        composition.moveCursor(to: 3)

        composition.delete()

        XCTAssertEqual(composition.raw, "niao")
        XCTAssertEqual(composition.cursor, 2)
        XCTAssertEqual(composition.selectionLocation, 2)
    }

    func testEmptyCompositionActionsAreNoOps() {
        let composition = Composition(
            decoder: RecordingPinyinDecoder(), inputScheme: .fullPinyin
        )

        composition.delete()

        XCTAssertNil(composition.select(0))
        XCTAssertNil(composition.commitBestOrRaw())
        XCTAssertNil(composition.commitPreeditLiterally())
        XCTAssertFalse(composition.isComposing)
    }
}

final class CompositionPreeditGroupingTests: XCTestCase {
    func testFullPinyinPreeditGroupsBySyllable() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "dayichuan"
                ? [Candidate(text: "大衣船", consumed: 9, tokens: [1, 2, 3],
                             units: "da'yi'chuan")]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        "dayichuan".forEach { composition.append(String($0)) }

        // The inline preedit reads like the first-row candidate, one group per
        // syllable. Full pinyin groups keep their own key length.
        XCTAssertEqual(composition.preedit, "da yi chuan")
    }

    func testShuangpinPreeditUsesDecoderSourceSpans() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { raw in
            raw == "xcgo"
                ? [Candidate(text: "小国", consumed: 4, tokens: [31, 32], units: "",
                             segmentKeys: [2, 2], segmentChars: [1, 1])]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        "xcgo".forEach { composition.append(String($0)) }

        XCTAssertEqual(composition.preedit, "xc go")
    }

    func testKeysBeyondTheCandidateStayAsATrailingGroup() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "nihao"
                ? [Candidate(text: "你", consumed: 2, tokens: [11], units: "ni")]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        "nihao".forEach { composition.append(String($0)) }

        // The candidate only covers "ni"; the uncovered "hao" keys remain
        // visible as their own group instead of vanishing or ungrouping all.
        XCTAssertEqual(composition.preedit, "ni hao")
    }

    func testUndecodedLiteralPinyinIsNotSplitPerCharacter() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { _ in [] }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        "niao".forEach { composition.append(String($0)) }

        // No Chinese path: the literal keys stay as one chunk, not "n i a o".
        XCTAssertEqual(composition.preedit, "niao")
    }

    func testSelectionLocationCountsGroupSeparatorsBeforeTheCursor() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "dayichuan"
                ? [Candidate(text: "大衣船", consumed: 9, tokens: [1, 2, 3],
                             units: "da'yi'chuan")]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        "dayichuan".forEach { composition.append(String($0)) }
        composition.moveCursor(to: 4) // after "dayi" -> displayed "da yi"

        // 4 raw keys + 1 separator inserted after the first group.
        XCTAssertEqual(composition.selectionLocation, 5)
    }
}
