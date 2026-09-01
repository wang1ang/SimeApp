import XCTest
@testable import Sime

private final class RecordingPinyinDecoder: PinyinDecoder {
    var decodeCalls: [(pinyin: String, context: [UInt32], limit: Int)] = []
    var decodeExpansions: [Bool] = []
    var correctionExpansions: [Bool] = []
    var predictionCalls: [(context: [UInt32], limit: Int)] = []
    var decodeResult: (String) -> [Candidate] = { _ in [] }
    var correctionResult: [Candidate] = []
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
        return Array(correctionResult.prefix(limit))
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
    func testFullPinyinPartialCandidateConsumesOnlyItsSourceRange() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            switch pinyin {
            case "nihao":
                return [Candidate(text: "你", consumed: 2, tokens: [11], units: "ni")]
            case "hao":
                return [Candidate(text: "好", consumed: 3, tokens: [22], units: "hao")]
            default:
                return []
            }
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        "nihao".forEach { composition.append(String($0)) }

        XCTAssertNil(composition.select(0))
        XCTAssertEqual(composition.committed, "你")
        XCTAssertEqual(composition.raw, "hao")
        XCTAssertEqual(composition.sentencePreview, "你好")
    }

    func testMicrosoftShuangpinConsumesTwoEnteredKeysPerSyllable() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            switch pinyin {
            case "xiaoguo":
                return [Candidate(text: "小", consumed: 4, tokens: [31], units: "xiao")]
            case "guo":
                return [Candidate(text: "国", consumed: 3, tokens: [32], units: "guo")]
            default:
                return []
            }
        }
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        "xcgo".forEach { composition.append(String($0)) }

        XCTAssertNil(composition.select(0))
        XCTAssertEqual(composition.committed, "小")
        XCTAssertEqual(composition.raw, "go")
        XCTAssertEqual(composition.sentencePreview, "小国")
    }

    func testActiveCorrectionLabelRetainsLiteralShuangpinKeys() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "xiaoguo"
                ? [Candidate(text: "小国", consumed: 7, tokens: [31, 32], units: "xiao'guo")]
                : []
        }
        decoder.correctionResult = [
            Candidate(text: "晓", consumed: 0, tokens: [33], units: "xiao")
        ]
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        "xcgo".forEach { composition.append(String($0)) }
        composition.activateCharacter(0)

        XCTAssertEqual(composition.activeEnteredKeys, "xc")
        XCTAssertEqual(composition.displayCandidates.map(\.text), ["晓"])
    }

    func testOddShuangpinKeyRemainsInCompositionUntilPairCompletes() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "xiaoguo"
                ? [Candidate(text: "小国", consumed: 7, tokens: [31, 32], units: "xiao'guo")]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        "xcg".forEach { composition.append(String($0)) }

        XCTAssertEqual(composition.raw, "xcg")
        XCTAssertEqual(composition.cursor, 3)
        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "xiao'g")
        // No Chinese path yet, so only the literal English fallback competes.
        XCTAssertEqual(composition.candidates.map(\.text), ["xcg"])
        XCTAssertEqual(composition.candidates.first?.isEnglish, true)

        composition.append("o")

        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "xiaoguo")
        XCTAssertEqual(composition.select(0), "小国")
        XCTAssertFalse(composition.isComposing)
    }

    func testLongShuangpinSentencePreservesAllSyllableBoundaries() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "womendezhongguo"
                ? [Candidate(
                    text: "我们的中国",
                    consumed: pinyin.count,
                    tokens: [1, 2, 3, 4, 5],
                    units: "wo'men'de'zhong'guo"
                )]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        "womfdevsgo".forEach { composition.append(String($0)) }

        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "womendezhongguo")
        XCTAssertEqual(composition.sentencePreview, "我们的中国")
        XCTAssertEqual(composition.select(0), "我们的中国")
        XCTAssertEqual(decoder.predictionCalls.last?.context, [1, 2, 3, 4, 5])
    }

    func testShuangpinLocksCompletedFinalsAgainstShorterExpansions() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "xihuan"
                ? [
                    // Correct locked path and single-character alternatives.
                    Candidate(text: "喜欢", consumed: 6, tokens: [1, 2], units: "xi'huan"),
                    Candidate(text: "喜", consumed: 2, tokens: [1], units: "xi"),
                    Candidate(text: "欢", consumed: 6, tokens: [2], units: "huan"),
                    // Under-expanded finals the engine offers for full pinyin
                    // but which Shuangpin has already locked out.
                    Candidate(text: "喜互", consumed: 4, tokens: [1, 3], units: "xi'hu"),
                    Candidate(text: "喜花", consumed: 5, tokens: [1, 4], units: "xi'hua")
                ]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        // xi = "xi", huan = "hr" (h + uan) in Microsoft Shuangpin.
        "xihr".forEach { composition.append(String($0)) }

        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "xihuan")
        // The under-expanded two-syllable paths are dropped; the locked path
        // and single-character alternatives survive.
        XCTAssertEqual(composition.candidates.map(\.text), ["喜欢", "喜", "欢", "xihr"])
    }

    func testShuangpinTrailingLoneInitialDecodesDelimitedWithExpansion() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "xi'h"
                ? [
                    Candidate(text: "西红", consumed: 3, tokens: [1, 5], units: "xi'h"),
                    Candidate(text: "西", consumed: 2, tokens: [1], units: "xi")
                ]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        // Odd key count: the head "xi" and lone initial "h" are sent as one
        // delimited buffer with expansion on; the engine locks "xi" and
        // completes only "h" (locking asserted in require/Sime correction_test).
        "xih".forEach { composition.append(String($0)) }

        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "xi'h")
        XCTAssertEqual(decoder.decodeExpansions.last, true)
        XCTAssertEqual(composition.candidates.map(\.text), ["西红", "西", "xih"])
    }

    func testShuangpinNghemDecodesNengHeMaDelimited() {
        // Regression (能喝吗 once surfaced 能很忙/能黑马): head delimited from the
        // lone "m", expansion on; engine locks neng/he (correction_test).
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "nenghe'm"
                ? [
                    Candidate(text: "能喝吗", consumed: 7, tokens: [1, 2, 3], units: "neng'he'm"),
                    Candidate(text: "能喝", consumed: 6, tokens: [1, 2], units: "neng'he")
                ]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        "nghem".forEach { composition.append(String($0)) }

        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "nenghe'm")
        XCTAssertEqual(decoder.decodeExpansions.last, true)
        XCTAssertEqual(composition.candidates.map(\.text), ["能喝吗", "能喝", "nghem"])
    }

    func testShuangpinHamigDecodesHaMiGua() {
        // Regression (哈密瓜): ha + mi + the lone initial of gua. Head delimited
        // from "g", expansion on; the engine keeps ha/mi exact and completes
        // g -> gua (word-alignment asserted in require/Sime correction_test).
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "hami'g"
                ? [
                    Candidate(text: "哈密瓜", consumed: 6, tokens: [1], units: "ha'mi'g"),
                    Candidate(text: "哈密", consumed: 4, tokens: [2], units: "ha'mi")
                ]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        "hamig".forEach { composition.append(String($0)) }

        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "hami'g")
        XCTAssertEqual(decoder.decodeExpansions.last, true)
        XCTAssertEqual(composition.candidates.map(\.text), ["哈密瓜", "哈密", "hamig"])
    }

    func testShuangpinTrailingInitialDecodesWithExplicitBoundary() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "na'n"
                ? [
                    Candidate(text: "那你", consumed: 3, tokens: [1, 2], units: "na'n"),
                    Candidate(text: "那", consumed: 2, tokens: [1], units: "na")
                ]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        // 那你: na + lone n sent as "na'n" with expansion; engine keeps "na"
        // locked (no merge into 南/南宁 — asserted in correction_test).
        "nan".forEach { composition.append(String($0)) }

        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "na'n")
        XCTAssertEqual(decoder.decodeExpansions.last, true)
        XCTAssertEqual(composition.candidates.map(\.text), ["那你", "那", "nan"])
        XCTAssertEqual(composition.preedit, "na n")
    }

    func testShuangpinCompleteSyllablesDecodeWithoutExpansion() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { _ in [] }
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        // Even key count: "li" + "vb"(zhou) are both complete syllables, so the
        // engine must NOT expand (expansion would invent 柳州/凉州 whose units
        // echo the typed li'zhou and slip past the locked-final filter).
        "livb".forEach { composition.append(String($0)) }

        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "lizhou")
        XCTAssertEqual(decoder.decodeExpansions.last, false)
    }

    func testShuangpinNghemaDecodesFullNengHeMa() {
        // Even key count: ng(neng)+he(he)+ma(ma) is fully typed, so it decodes
        // the joined pinyin without expansion.
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "nenghema"
                ? [Candidate(text: "能喝吗", consumed: 8, tokens: [1, 2, 3], units: "neng'he'ma")]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        "nghema".forEach { composition.append(String($0)) }

        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "nenghema")
        XCTAssertEqual(decoder.decodeExpansions.last, false)
        XCTAssertEqual(composition.candidates.map(\.text), ["能喝吗", "nghema"])
    }

    func testShuangpinCorrectionCandidatesRespectLockedFinals() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "shiyu"
                ? [Candidate(text: "是语", consumed: 5, tokens: [1, 2], units: "shi'yu")]
                : []
        }
        // Second-row corrections for the tapped first character span into the
        // locked second syllable "yu"; 石原/诗云 expand it to yuan/yun.
        decoder.correctionResult = [
            Candidate(text: "始于", consumed: 5, tokens: [3, 4], units: "shi'yu"),
            Candidate(text: "石原", consumed: 7, tokens: [5, 6], units: "shi'yuan"),
            Candidate(text: "诗云", consumed: 6, tokens: [7, 8], units: "shi'yun"),
            Candidate(text: "视域", consumed: 5, tokens: [9, 10], units: "shi'yu")
        ]
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        // shi = "ui" (sh + i), yu = "yu" in Microsoft Shuangpin.
        "uiyu".forEach { composition.append(String($0)) }
        composition.activateCharacter(0)

        // Corrections that lengthen the locked "yu" final are dropped.
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

    func testLowercaseAppendsLiteralEnglishCandidateAfterChinese() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { _ in
            [Candidate(text: "啊", consumed: 1, tokens: [1], units: "a")]
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        "app".forEach { composition.append(String($0)) }

        // Chinese ranks first; the literal English candidate competes from the
        // tail (and would be first if no Chinese path existed).
        let candidates = composition.candidates
        XCTAssertEqual(candidates.map(\.text), ["啊", "app"])
        XCTAssertEqual(candidates.last?.isEnglish, true)
    }

    func testLeadingCapitalRanksLiteralEnglishFirstAndCommits() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { _ in [] }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        // A one-shot Shift capitalises the first letter; the rest stay as
        // typed. The literal string (case preserved) ranks first and commits
        // through the same path as a Chinese word.
        ["H", "i"].forEach { composition.append($0) }
        XCTAssertEqual(composition.candidates.first?.text, "Hi")
        XCTAssertEqual(composition.candidates.first?.isEnglish, true)
        XCTAssertEqual(composition.select(0), "Hi")
        XCTAssertFalse(composition.isComposing)
    }

    func testShuangpinLiteralEnglishCandidateIsRawKeys() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { _ in [] }
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        // In Shuangpin the literal candidate is the raw keys, not the
        // expanded pinyin, and consumes every key on commit.
        ["A", "p", "p"].forEach { composition.append($0) }
        XCTAssertEqual(composition.candidates.first?.text, "App")
        XCTAssertEqual(composition.select(0), "App")
        XCTAssertFalse(composition.isComposing)
    }

    func testMixedPinyinPrefixWithEnglishTail() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "nihao"
                ? [Candidate(text: "你好", consumed: 5, tokens: [1, 2], units: "ni'hao")]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        // Lowercase pinyin then a capitalised English tail: decode the pinyin
        // prefix and keep the tail literal, combined into one candidate.
        "nihao".forEach { composition.append(String($0)) }
        ["A", "A"].forEach { composition.append($0) }

        // The tail must not pollute the pinyin decode.
        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "nihao")
        XCTAssertEqual(composition.candidates.first?.text, "你好AA")
        // Inline preedit groups the pinyin prefix by syllable and aligns one
        // group per literal English-tail character.
        XCTAssertEqual(composition.preedit, "ni hao A A")
        XCTAssertEqual(composition.select(0), "你好AA")
        XCTAssertFalse(composition.isComposing)
    }

    func testSelectingAllSegmentsUsesEveryFixedTokenForPrediction() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            switch pinyin {
            case "nihao":
                return [Candidate(text: "你", consumed: 2, tokens: [11], units: "ni")]
            case "hao":
                return [Candidate(text: "好", consumed: 3, tokens: [22], units: "hao")]
            default:
                return []
            }
        }
        decoder.predictionResult = { _ in
            [Candidate(text: "呀", consumed: 0, tokens: [33])]
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        "nihao".forEach { composition.append(String($0)) }
        XCTAssertNil(composition.select(0))
        XCTAssertEqual(composition.select(0), "你好")

        XCTAssertEqual(decoder.predictionCalls.last?.context, [11, 22])
        XCTAssertEqual(composition.displayCandidates.map(\.text), ["呀"])
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

    func testReturnCommitsSelectedPrefixAndRemainingPinyinLiterally() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            switch pinyin {
            case "nihao":
                return [Candidate(text: "你", consumed: 2, tokens: [1], units: "ni")]
            case "hao":
                return [Candidate(text: "好", consumed: 3, tokens: [2], units: "hao")]
            default:
                return []
            }
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)

        "nihao".forEach { composition.append(String($0)) }
        XCTAssertNil(composition.select(0))

        XCTAssertEqual(composition.commitPreeditLiterally(), "你hao")
        XCTAssertFalse(composition.isComposing)
        XCTAssertTrue(composition.displayCandidates.isEmpty)
    }

    func testReturnAfterSecondRowCorrectionDecodesRemainingSyllables() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "wanquanlixian"
                ? [Candidate(
                    text: "完全离线",
                    consumed: pinyin.count,
                    tokens: [1, 2, 3, 4],
                    units: "wan'quan'li'xian"
                )]
                : []
        }
        // Second-row replacement chosen for the tapped "离" spans two
        // syllables ("离线") starting at syllable index 2.
        decoder.correctionResult = [
            Candidate(text: "离线", consumed: 0, tokens: [30, 31], units: "li'xian")
        ]
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        "wjqrlixm".forEach { composition.append(String($0)) }
        composition.activateCharacter(2)
        XCTAssertNil(composition.selectDisplayed(0))

        // Return must not fall back to the literal keys of the un-anchored
        // "完全" prefix; it commits the decoded sentence with the anchor.
        XCTAssertEqual(composition.commitPreeditLiterally(), "完全离线")
        XCTAssertFalse(composition.isComposing)
    }

    func testShuangpinDisablesEngineExpansionForCorrectionOnly() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { _ in
            [Candidate(text: "是语", consumed: 5, tokens: [1, 2], units: "shi'yu")]
        }
        decoder.correctionResult = [
            Candidate(text: "已于", consumed: 5, tokens: [3, 4], units: "shi'yu")
        ]

        // Correction disables expansion so a locked final isn't abbreviation-
        // matched to a longer one (removed 石原/十元). Main decode expands only
        // when the buffer ends in a lone initial (odd count).
        let shuangpin = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)
        "uiyu".forEach { shuangpin.append(String($0)) }
        shuangpin.activateCharacter(0)
        XCTAssertEqual(decoder.decodeExpansions, [true, false, true, false],
                       "odd key counts (a trailing lone initial) expand; even counts do not")
        XCTAssertEqual(decoder.correctionExpansions.last, false)

        decoder.decodeExpansions.removeAll()
        decoder.correctionExpansions.removeAll()
        decoder.decodeResult = { _ in
            [Candidate(text: "你好", consumed: 5, tokens: [1, 2], units: "ni'hao")]
        }
        let fullPinyin = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "nihao".forEach { fullPinyin.append(String($0)) }
        fullPinyin.activateCharacter(0)
        XCTAssertEqual(decoder.decodeExpansions.last, true)
        XCTAssertEqual(decoder.correctionExpansions.last, true)
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

    func testShuangpinPreeditGroupsTwoKeysPerSyllable() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "xiaoguo"
                ? [Candidate(text: "小国", consumed: 7, tokens: [31, 32],
                             units: "xiao'guo")]
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
