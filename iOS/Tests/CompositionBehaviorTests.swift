import XCTest
@testable import Sime

private final class RecordingPinyinDecoder: PinyinDecoder {
    var decodeCalls: [(pinyin: String, context: [UInt32], limit: Int)] = []
    var predictionCalls: [(context: [UInt32], limit: Int)] = []
    var decodeResult: (String) -> [Candidate] = { _ in [] }
    var correctionResult: [Candidate] = []
    var tokenizedText: [String: [UInt32]] = [:]
    var predictionResult: ([UInt32]) -> [Candidate] = { _ in [] }

    func decode(_ pinyin: String, limit: Int) -> [Candidate] {
        decode(pinyin, context: [], limit: limit)
    }

    func decode(_ pinyin: String, context: [UInt32], limit: Int) -> [Candidate] {
        decodeCalls.append((pinyin, context, limit))
        return Array(decodeResult(pinyin).prefix(limit))
    }

    func correctionCandidates(_ pinyin: String, fixedPrefix: String,
                              prefixSyllables: Int, limit: Int) -> [Candidate] {
        Array(correctionResult.prefix(limit))
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
