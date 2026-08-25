import XCTest
@testable import Sime

private struct MinimalPinyinDecoder: PinyinDecoder {
    func decode(_ pinyin: String, limit: Int) -> [Candidate] {
        [Candidate(text: "结果", consumed: pinyin.count, tokens: [7], units: pinyin)]
    }
}

final class PinyinDecoderContractTests: XCTestCase {
    func testProtocolDefaultsPreserveTheBasicDecoderResult() {
        let decoder = MinimalPinyinDecoder()

        XCTAssertEqual(decoder.decode("ni", context: [1, 2], limit: 9).map(\.text), ["结果"])
        XCTAssertEqual(decoder.exactCandidates("ni", limit: 9).map(\.text), ["结果"])
        XCTAssertEqual(
            decoder.correctionCandidates(
                "ni", fixedPrefix: "", prefixSyllables: 0, limit: 9
            ).map(\.text),
            ["结果"]
        )
        XCTAssertEqual(decoder.syllableCandidates("ni").map(\.text), ["结果"])
        XCTAssertTrue(decoder.tokenize("上下文").isEmpty)
        XCTAssertTrue(decoder.predict([7], limit: 9).isEmpty)
    }

    func testBuiltinDecoderKeepsLongestCandidateFirst() {
        let candidates = BuiltinPinyinDecoder().decode("nihao", limit: 9)

        XCTAssertEqual(candidates.first?.text, "你好")
        XCTAssertEqual(candidates.first?.consumed, 5)
        XCTAssertEqual(Array(candidates.dropFirst().prefix(3)).map(\.text), ["你", "呢", "尼"])
    }

    func testBuiltinDecoderExpandsAnUnfinishedSyllable() {
        let candidates = BuiltinPinyinDecoder().decode("y", limit: 9)

        XCTAssertEqual(candidates.prefix(3).map(\.text), ["以", "一", "已"])
        XCTAssertTrue(candidates.contains { $0.text == "要" })
        XCTAssertTrue(candidates.allSatisfy { $0.consumed == 1 })
    }
}
