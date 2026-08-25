import XCTest
@testable import Sime

private struct CorrectionCandidateDecoder: PinyinDecoder {
    func decode(_ pinyin: String, limit: Int) -> [Candidate] {
        [Candidate(text: "性价比", consumed: pinyin.count, tokens: [], units: "xing'jia'bi")]
    }

    func decode(_ pinyin: String, context: [UInt32], limit: Int) -> [Candidate] {
        decode(pinyin, limit: limit)
    }

    func exactCandidates(_ pinyin: String, limit: Int) -> [Candidate] {
        decode(pinyin, limit: limit)
    }

    func correctionCandidates(_ pinyin: String, fixedPrefix: String,
                              prefixSyllables: Int, limit: Int) -> [Candidate] {
        XCTAssertEqual(pinyin, "xing'jia'bi")
        XCTAssertEqual(fixedPrefix, "性")
        XCTAssertEqual(prefixSyllables, 1)
        return ["价比", "假币", "家比", "强", "将", "家"].map {
            Candidate(text: $0, consumed: 0, tokens: [], units: "jia")
        }
    }

    func tokenize(_ text: String) -> [UInt32] { [] }
    func syllableCandidates(_ pinyin: String) -> [Candidate] { [] }
    func predict(_ context: [UInt32], limit: Int) -> [Candidate] { [] }
}

final class CompositionCorrectionTests: XCTestCase {
    func testTappingJiaInXingJiaBiShowsConstrainedCandidates() {
        let composition = Composition(
            decoder: CorrectionCandidateDecoder(), inputScheme: .fullPinyin
        )
        "xingjiabi".forEach { composition.append(String($0)) }
        XCTAssertEqual(composition.sentencePreview, "性价比")

        composition.activateCharacter(1)
        XCTAssertEqual(
            composition.displayCandidates.map(\.text),
            ["价比", "假币", "家比", "强", "将", "家"]
        )
    }
}
