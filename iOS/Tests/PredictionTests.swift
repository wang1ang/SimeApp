import XCTest
@testable import Sime

/// Association-bar (联想) prediction contract for the native Sime decoder.
/// The n-gram model's single most frequent successor of almost any token is
/// punctuation (，。、！？ …); an unfiltered prediction floods the bar with
/// punctuation and pushes useful word suggestions out of the visible slots.
/// `NativePinyinDecoder.predict` must therefore return real words only.
final class PredictionTests: XCTestCase {
    private func decoder() throws -> NativePinyinDecoder {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else {
            throw XCTSkip("sime.dict/sime.cnt not bundled into the test target")
        }
        return decoder
    }

    private func isPunctuationOnly(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        return text.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
                || CharacterSet.symbols.contains($0)
                || CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    func testPredictionsDropPunctuationOnlySuggestions() throws {
        let decoder = try decoder()
        for word in ["你", "我", "是", "中国"] {
            let context = decoder.tokenize(word)
            try XCTSkipIf(context.isEmpty, "no token for \(word)")
            let predictions = decoder.predict(context, limit: 9)
            XCTAssertFalse(predictions.isEmpty, "\(word) produced no predictions")
            XCTAssertLessThanOrEqual(predictions.count, 9)
            for candidate in predictions {
                XCTAssertFalse(
                    isPunctuationOnly(candidate.text),
                    "\(word) prediction \"\(candidate.text)\" is punctuation only"
                )
            }
        }
    }

    func testPredictionRespectsTheRequestedLimit() throws {
        let decoder = try decoder()
        let context = decoder.tokenize("你")
        try XCTSkipIf(context.isEmpty, "no token for 你")
        XCTAssertLessThanOrEqual(decoder.predict(context, limit: 3).count, 3)
    }
}
