import XCTest
@testable import Sime

final class ZiranmaShuangpinTests: XCTestCase {
    private let layout = ShuangpinLayout.ziranma

    func testSharesMicrosoftKeyAssignments() {
        // Natural Code keeps Microsoft's key assignments for these finals.
        XCTAssertEqual(layout.expand("wo"), "wo")
        XCTAssertEqual(layout.expand("xcgo"), "xiaoguo") // 效果
        XCTAssertEqual(layout.expand("xigw"), "xigua")   // 西瓜
        XCTAssertEqual(layout.expand("gv"), "gui")
        XCTAssertEqual(layout.expand("js"), "jiong")
        XCTAssertEqual(layout.expand("ys"), "yong")
        XCTAssertEqual(layout.expand("gd"), "guang")
        XCTAssertEqual(layout.expand("nv"), "nv")
        XCTAssertEqual(layout.expand("lt"), "lve")
    }

    func testIngMovesToYWithUai() {
        // ing lives on y (sharing with uai, whose initials never collide).
        XCTAssertEqual(layout.expand("jy"), "jing")   // j + y -> ing
        XCTAssertEqual(layout.expand("by"), "bing")   // b + y -> ing
        XCTAssertEqual(layout.expand("gy"), "guai")   // g + y -> uai
        XCTAssertEqual(layout.expand("ky"), "kuai")   // k + y -> uai
        XCTAssertEqual(layout.expand("yy"), "ying")   // 英 (y + y -> ing)
    }

    func testZeroInitialUsesVowelLetter() {
        XCTAssertEqual(layout.expand("aa"), "a")
        XCTAssertEqual(layout.expand("oo"), "o")
        XCTAssertEqual(layout.expand("ee"), "e")
        XCTAssertEqual(layout.expand("al"), "ai")     // 爱 (a + l)
        XCTAssertEqual(layout.expand("aj"), "an")     // 安 (a + j)
        XCTAssertEqual(layout.expand("ak"), "ao")     // 奥 (a + k)
        XCTAssertEqual(layout.expand("ez"), "ei")     // (e + z)
        XCTAssertEqual(layout.expand("ef"), "en")     // 恩 (e + f)
        XCTAssertEqual(layout.expand("eg"), "eng")    // (e + g)
        XCTAssertEqual(layout.expand("er"), "er")     // 儿
        XCTAssertEqual(layout.expand("ob"), "ou")     // 欧 (o + b)
    }
}
