import XCTest
@testable import Sime

/// End-to-end correction against the real C++ decoder and bundled dictionary.
final class AnchorEndToEndTests: XCTestCase {
    func testSelectingWholeSentenceCorrectionCommitsImmediately() throws {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else {
            throw XCTSkip("sime.dict/sime.cnt not bundled into the test target")
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "shiyushurufa".forEach { composition.append(String($0)) }
        XCTAssertEqual(composition.candidates.first?.text, "始于输入法")

        composition.activateCharacter(0)
        guard let whole = composition.displayCandidates.firstIndex(where: { $0.text == "是与输入法" }) else {
            throw XCTSkip("engine no longer offers 是与输入法")
        }
        XCTAssertEqual(composition.selectDisplayed(whole), "是与输入法")
        XCTAssertFalse(composition.isComposing)
    }

    func testSelectingPartOfCapitalRunKeepsTheRest() throws {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else {
            throw XCTSkip("sime.dict/sime.cnt not bundled into the test target")
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "NTP".forEach { composition.append(String($0)) }
        guard let nt = composition.candidates.firstIndex(where: { $0.text == "NT" }) else {
            return XCTFail("NTP should offer NT; got: \(composition.candidates.map { $0.text })")
        }
        XCTAssertNil(composition.select(nt))
        XCTAssertTrue(composition.isComposing)
        XCTAssertEqual(composition.sentenceSegments.first?.text, "NT")
        XCTAssertEqual(composition.candidates.first?.text, "NTP")
    }

    func testTappingRestOfCapitalRunOffersItsLetters() throws {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else {
            throw XCTSkip("sime.dict/sime.cnt not bundled into the test target")
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "NTP".forEach { composition.append(String($0)) }
        let nt = try XCTUnwrap(composition.candidates.firstIndex(where: { $0.text == "NT" }))
        XCTAssertNil(composition.select(nt))
        composition.activateCharacter(2)
        XCTAssertEqual(composition.displayCandidates.first?.text, "P",
                       "tapping P after NT should list P; got: \(composition.displayCandidates.map { $0.text })")
    }

    func testSelectingAPartialSentenceCandidateAdvancesToTheNextCharacter() throws {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else {
            throw XCTSkip("sime.dict/sime.cnt not bundled into the test target")
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "tuoguanshi".forEach { composition.append(String($0)) }
        let tuoguan = try XCTUnwrap(composition.displayCandidates.firstIndex { $0.text == "托管" },
                                    "got: \(composition.displayCandidates.map(\.text))")

        XCTAssertNil(composition.selectDisplayed(tuoguan))
        XCTAssertEqual(composition.activeCharacterIndex, 2)
        XCTAssertTrue(composition.displayCandidates.contains { $0.text == "式" },
                      "got: \(composition.displayCandidates.map(\.text))")
    }
}
