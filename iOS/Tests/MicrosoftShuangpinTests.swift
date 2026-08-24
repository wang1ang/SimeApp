import XCTest
@testable import Sime

final class MicrosoftShuangpinTests: XCTestCase {
    func testCommonSyllables() {
        XCTAssertEqual(MicrosoftShuangpin.expand("wo"), "wo")
        XCTAssertEqual(MicrosoftShuangpin.expand("xcgo"), "xiaoguo")
        XCTAssertEqual(MicrosoftShuangpin.expand("xigw"), "xigua")
        XCTAssertEqual(MicrosoftShuangpin.expand("gv"), "gui")
        XCTAssertEqual(MicrosoftShuangpin.expand("js"), "jiong")
        XCTAssertEqual(MicrosoftShuangpin.expand("gd"), "guang")
        XCTAssertEqual(MicrosoftShuangpin.expand("oa"), "a")
        XCTAssertEqual(MicrosoftShuangpin.expand("ol"), "ai")
        XCTAssertEqual(MicrosoftShuangpin.expand("oo"), "o")
    }

    func testVFinalUsesSimePinyinNotation() {
        XCTAssertEqual(MicrosoftShuangpin.expand("nv"), "nv")
        XCTAssertEqual(MicrosoftShuangpin.expand("lt"), "lve")
        XCTAssertEqual(MicrosoftShuangpin.expand("lr"), "lvan")
        XCTAssertEqual(MicrosoftShuangpin.expand("lp"), "lvn")
    }
}
