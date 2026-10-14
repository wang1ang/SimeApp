import XCTest
@testable import Sime

final class CalculatorTests: XCTestCase {
    private func suggest(_ context: String) -> CalculatorSuggestion? {
        Calculator.suggestion(forContext: context)
    }

    func testBasicExpressionShowsFullEquationAndInsertsResult() {
        XCTAssertEqual(suggest("1+1"), CalculatorSuggestion(display: "1+1=2", insert: "=2"))
        XCTAssertEqual(suggest("2*3+4")?.display, "2*3+4=10")
        XCTAssertEqual(suggest("2+3*4")?.insert, "=14")
        XCTAssertEqual(suggest("（1+2）×3")?.insert, "=9")
        XCTAssertEqual(suggest("10÷4")?.insert, "=2.5")
        XCTAssertEqual(suggest("0.1+0.2")?.insert, "=0.3")
        XCTAssertEqual(suggest("1-3")?.insert, "=-2")
        XCTAssertEqual(suggest("-2*-3")?.insert, "=6")
        XCTAssertEqual(suggest("1/3")?.insert, "=0.3333333333")
    }

    func testTrailingEqualsInsertsOnlyTheResult() {
        XCTAssertEqual(suggest("1+1="), CalculatorSuggestion(display: "1+1=2", insert: "2"))
    }

    func testOnlyTheTrailingExpressionIsEvaluated() {
        XCTAssertEqual(suggest("今天花了12+30")?.display, "12+30=42")
        // After accepting, the chain continues from the result.
        XCTAssertEqual(suggest("1+1=2+3")?.display, "2+3=5")
        XCTAssertNil(suggest("1+1=2"))
    }

    func testNonCalculationsProduceNothing() {
        for text in ["", "你好", "42", "-5", "1+", "1+1 ", "(1+2", "1/0",
                     "2024-05-01", "1..2+3", "1+.5", "abc"] {
            XCTAssertNil(suggest(text), text)
        }
    }

    func testCompositionShowsAndCommitsCalculatorInPlaceOfAssociation() {
        let composition = Composition(decoder: BuiltinPinyinDecoder(), inputScheme: .fullPinyin)
        composition.predictionEnabled = true
        XCTAssertTrue(composition.updateCalculator(context: "1+1"))
        XCTAssertEqual(composition.displayCandidates.map(\.text), ["1+1=2"])
        XCTAssertEqual(composition.selectDisplayed(0), "=2")
        XCTAssertTrue(composition.displayCandidates.isEmpty)
        XCTAssertFalse(composition.updateCalculator(context: "1+1=2"))
    }

    func testCalculatorFollowsPredictionSwitch() {
        let composition = Composition(decoder: BuiltinPinyinDecoder(), inputScheme: .fullPinyin)
        composition.predictionEnabled = true
        composition.updateCalculator(context: "1+1")
        composition.predictionEnabled = false
        XCTAssertTrue(composition.displayCandidates.isEmpty)
        composition.updateCalculator(context: "2+2")
        XCTAssertNil(composition.calculatorSuggestion)
    }
}

final class NumberPagePolicyTests: XCTestCase {
    func testHalfWidthNumericSymbolsStayOnlyAfterDigit() {
        for symbol in [".", "-", "/", "*", "+", "="] {
            XCTAssertTrue(NumberPagePolicy.keepsNumberPage(afterInserting: symbol, previous: "3"), symbol)
            XCTAssertFalse(NumberPagePolicy.keepsNumberPage(afterInserting: symbol, previous: "你"), symbol)
            XCTAssertFalse(NumberPagePolicy.keepsNumberPage(afterInserting: symbol, previous: "a"), symbol)
            XCTAssertFalse(NumberPagePolicy.keepsNumberPage(afterInserting: symbol, previous: nil), symbol)
        }
    }

    func testOtherPunctuationAlwaysLeaves() {
        for symbol in ["，", "：", "（", "@", "；"] {
            XCTAssertFalse(NumberPagePolicy.keepsNumberPage(afterInserting: symbol, previous: "3"), symbol)
        }
    }
}
