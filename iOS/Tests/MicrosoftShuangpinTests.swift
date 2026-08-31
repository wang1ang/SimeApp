import XCTest
@testable import Sime

final class MicrosoftShuangpinTests: XCTestCase {
    func testCommonSyllables() {
        XCTAssertEqual(MicrosoftShuangpin.expand("wo"), "wo")
        XCTAssertEqual(MicrosoftShuangpin.expand("xcgo"), "xiaoguo")
        XCTAssertEqual(MicrosoftShuangpin.expand("xigw"), "xigua")
        XCTAssertEqual(MicrosoftShuangpin.expand("gv"), "gui")
        XCTAssertEqual(MicrosoftShuangpin.expand("js"), "jiong")
        XCTAssertEqual(MicrosoftShuangpin.expand("ys"), "yong")
        XCTAssertEqual(MicrosoftShuangpin.expand("gd"), "guang")
        XCTAssertEqual(MicrosoftShuangpin.expand("oa"), "a")
        XCTAssertEqual(MicrosoftShuangpin.expand("ol"), "ai")
        XCTAssertEqual(MicrosoftShuangpin.expand("oo"), "o")
        XCTAssertEqual(MicrosoftShuangpin.expand("or"), "er")
    }

    func testAmbiguousFinalRules() {
        XCTAssertEqual(MicrosoftShuangpin.expand("bo"), "bo")
        XCTAssertEqual(MicrosoftShuangpin.expand("lo"), "luo")
        XCTAssertEqual(MicrosoftShuangpin.expand("xw"), "xia")
        XCTAssertEqual(MicrosoftShuangpin.expand("gw"), "gua")
        XCTAssertEqual(MicrosoftShuangpin.expand("jd"), "jiang")
    }

    func testVFinalUsesSimePinyinNotation() {
        XCTAssertEqual(MicrosoftShuangpin.expand("nv"), "nv")
        XCTAssertEqual(MicrosoftShuangpin.expand("lt"), "lve")
        XCTAssertEqual(MicrosoftShuangpin.expand("lr"), "luan")
        XCTAssertEqual(MicrosoftShuangpin.expand("lp"), "lun")
    }

    func testSpecialInitialsSemicolonAndIncompletePair() {
        XCTAssertEqual(MicrosoftShuangpin.expand("vs"), "zhong")
        XCTAssertEqual(MicrosoftShuangpin.expand("is"), "chong")
        XCTAssertEqual(MicrosoftShuangpin.expand("j;"), "jing")
        XCTAssertEqual(MicrosoftShuangpin.expand("xcg"), "xiaog")
    }
}
