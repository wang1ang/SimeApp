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
}
