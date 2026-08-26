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
        XCTAssertEqual(decoder.decodeCalls.last?.pinyin, "xiaog")
        XCTAssertTrue(composition.candidates.isEmpty)

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
        XCTAssertEqual(composition.candidates.map(\.text), ["喜欢", "喜", "欢"])
    }

    func testShuangpinTrailingIncompleteSyllableStillExpands() {
        let decoder = RecordingPinyinDecoder()
        decoder.decodeResult = { pinyin in
            pinyin == "xih"
                ? [
                    Candidate(text: "西红", consumed: 5, tokens: [1, 5], units: "xi'hong"),
                    Candidate(text: "喜", consumed: 2, tokens: [1], units: "xi")
                ]
                : []
        }
        let composition = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)

        // Odd key count: "xi" is locked but the trailing "h" is still an
        // incomplete syllable, so its final may expand.
        "xih".forEach { composition.append(String($0)) }

        XCTAssertEqual(composition.candidates.map(\.text), ["西红", "喜"])
        // The fake decoder ignores the expansion flag, so this alone cannot
        // prove the engine completes a trailing initial. Guard the wiring
        // that makes it possible: main decode must request expansion (the
        // engine semantics itself is covered by require/Sime correction_test).
        XCTAssertEqual(decoder.decodeExpansions.last, true)
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

        XCTAssertEqual(composition.displayCandidates.map(\.text), ["中国", "中过", "种过"])
        XCTAssertEqual(composition.displayCandidates.map(\.score), [-6, -13, -15])
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

        // Correction faces already-complete syllables, so it disables
        // expansion to stop a locked final being abbreviation-matched to a
        // longer syllable (this is what removed 石原/十元). Main decode must
        // keep expansion so a lone Shuangpin initial still completes.
        let shuangpin = Composition(decoder: decoder, inputScheme: .microsoftShuangpin)
        "uiyu".forEach { shuangpin.append(String($0)) }
        shuangpin.activateCharacter(0)
        XCTAssertEqual(decoder.decodeExpansions, [true, true, true, true],
                       "main decode must keep expansion for lone-initial completion")
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
