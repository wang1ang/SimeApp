import XCTest
@testable import Sime

/// End-to-end anchor split against the real C++ decoder + bundled dict:
/// anchor a 5-syllable phrase, then re-choose one interior character. The
/// anchor must be split, not dropped, so untouched characters stay locked.
final class AnchorEndToEndTests: XCTestCase {
    func testInteriorReselectionKeepsRestOfMultiSyllableAnchor() throws {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else {
            throw XCTSkip("sime.dict/sime.cnt not bundled into the test target")
        }
        let c = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "shiyushurufa".forEach { c.append(String($0)) }
        XCTAssertEqual(c.candidates.first?.text, "始于输入法")

        // Tap the first character, pick the whole-sentence candidate: this
        // anchors all five syllables as one segment (是 replaces 始).
        c.activateCharacter(0)
        guard let whole = c.displayCandidates.firstIndex(where: { $0.text == "是与输入法" }) else {
            throw XCTSkip("engine no longer offers 是与输入法")
        }
        XCTAssertNil(c.selectDisplayed(whole))
        XCTAssertEqual(c.sentencePreview, "是与输入法")

        // Re-choose only the second character (与 -> 语), inside that anchor.
        c.activateCharacter(1)
        guard let yu = c.displayCandidates.firstIndex(where: { $0.text == "语" }) else {
            throw XCTSkip("engine no longer offers 语 at position 1")
        }
        XCTAssertNil(c.selectDisplayed(yu))

        // Split, not drop: 是/输入法 stay locked; the head must not revert to 始.
        XCTAssertEqual(c.sentencePreview, "是语输入法")
    }
}
