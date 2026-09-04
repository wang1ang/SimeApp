import XCTest
@testable import Sime

private final class CtxRecordingDecoder: PinyinDecoder {
    var decodeCalls: [(pinyin: String, context: [UInt32])] = []
    var associateCalls: [[UInt32]] = []
    var decodeResult: (String) -> [Candidate] = { _ in [] }
    var associateResult: ([UInt32]) -> [Candidate] = { _ in [] }
    var tokenized: [String: [UInt32]] = [:]

    func decode(_ pinyin: String, limit: Int) -> [Candidate] {
        decode(pinyin, context: [], limit: limit, expansion: true)
    }
    func decode(_ pinyin: String, context: [UInt32], limit: Int) -> [Candidate] {
        decode(pinyin, context: context, limit: limit, expansion: true)
    }
    func decode(_ pinyin: String, context: [UInt32], limit: Int,
                expansion: Bool) -> [Candidate] {
        decodeCalls.append((pinyin, context))
        return Array(decodeResult(pinyin).prefix(limit))
    }
    func correctionCandidates(_ pinyin: String, fixedPrefix: String,
                              prefixSyllables: Int, limit: Int) -> [Candidate] { [] }
    func correctionCandidates(_ pinyin: String, fixedPrefix: String,
                              prefixSyllables: Int, limit: Int,
                              expansion: Bool) -> [Candidate] { [] }
    func tokenize(_ text: String) -> [UInt32] { tokenized[text] ?? [] }
    func predict(_ context: [UInt32], limit: Int) -> [Candidate] {
        associateCalls.append(context)
        return Array(associateResult(context).prefix(limit))
    }
    func associate(_ context: [UInt32], limit: Int) -> [Candidate] {
        predict(context, limit: limit)
    }
}

final class ContextBugFixTests: XCTestCase {

    // BUG 2 fixed: a fixed prefix segment feeds the re-decode of the leftover.
    func testFixedPrefixEntersLeftoverDecodeContext() {
        let decoder = CtxRecordingDecoder()
        decoder.decodeResult = { pinyin in
            switch pinyin {
            case "beijingdaxue":
                return [Candidate(text: "北京", consumed: 7,
                                  tokens: [100, 101], units: "bei'jing")]
            case "daxue":
                return [Candidate(text: "大学", consumed: 5,
                                  tokens: [200, 201], units: "da'xue")]
            default: return []
            }
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "beijingdaxue".forEach { composition.append(String($0)) }

        XCTAssertNil(composition.select(0))
        XCTAssertEqual(composition.raw, "daxue")
        let leftover = decoder.decodeCalls.last { $0.pinyin == "daxue" }
        XCTAssertEqual(leftover?.context, [100, 101])
    }

    // BUG 3 fixed: consecutive association taps accumulate context.
    func testConsecutiveAssociationAccumulatesContext() {
        let decoder = CtxRecordingDecoder()
        decoder.tokenized = ["我": [1]]
        decoder.decodeResult = { pinyin in
            pinyin == "ai"
                ? [Candidate(text: "爱", consumed: 2, tokens: [7], units: "ai")]
                : []
        }
        decoder.associateResult = { _ in
            [Candidate(text: "你", consumed: 0, tokens: [9], units: "")]
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        composition.predictionEnabled = true

        composition.updateHostContext(from: "我")
        "ai".forEach { composition.append(String($0)) }
        XCTAssertEqual(composition.select(0), "爱")
        XCTAssertEqual(decoder.associateCalls.last, [1, 7])

        _ = composition.selectDisplayed(0)
        XCTAssertEqual(decoder.associateCalls.last, [1, 7, 9])
    }
}
