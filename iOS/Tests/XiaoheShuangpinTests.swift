import XCTest
@testable import Sime

final class XiaoheShuangpinTests: XCTestCase {
    private let layout = ShuangpinLayout.xiaohe

    func testCommonSyllables() {
        // zh/ch/sh initials on v/i/u, plus Xiaohe's own final layout.
        XCTAssertEqual(layout.expand("vs"), "zhong")   // 中
        XCTAssertEqual(layout.expand("ui"), "shi")     // 是
        XCTAssertEqual(layout.expand("wo"), "wo")      // 我 (w + o -> o)
        XCTAssertEqual(layout.expand("de"), "de")
        XCTAssertEqual(layout.expand("hc"), "hao")     // 好 (c -> ao)
        XCTAssertEqual(layout.expand("ni"), "ni")
        XCTAssertEqual(layout.expand("jq"), "jiu")     // 就 (q -> iu)
        XCTAssertEqual(layout.expand("fw"), "fei")     // 飞 (w -> ei)
    }

    func testAmbiguousFinalRules() {
        XCTAssertEqual(layout.expand("ul"), "shuang")  // sh + l(iang/uang) -> uang
        XCTAssertEqual(layout.expand("xl"), "xiang")   // x + l -> iang
        XCTAssertEqual(layout.expand("kk"), "kuai")    // k + k(uai/ing) -> uai
        XCTAssertEqual(layout.expand("xk"), "xing")    // x + k -> ing
        XCTAssertEqual(layout.expand("xx"), "xia")     // x + x(ia/ua) -> ia
        XCTAssertEqual(layout.expand("gx"), "gua")     // g + x -> ua
        XCTAssertEqual(layout.expand("js"), "jiong")   // j + s(ong/iong) -> iong
        XCTAssertEqual(layout.expand("ys"), "yong")    // y + s -> ong
        XCTAssertEqual(layout.expand("bo"), "bo")      // b + o -> o
        XCTAssertEqual(layout.expand("lo"), "luo")     // l + o -> uo
    }

    func testVFinalAndUeUsesSimeNotation() {
        XCTAssertEqual(layout.expand("gv"), "gui")     // g + v -> ui
        XCTAssertEqual(layout.expand("nv"), "nv")      // n + v -> v (ü)
        XCTAssertEqual(layout.expand("lt"), "lve")     // l + t(ue/üe) -> ve
        XCTAssertEqual(layout.expand("jt"), "jue")     // j + t -> ue
        XCTAssertEqual(layout.expand("lr"), "luan")    // l + r -> uan
        XCTAssertEqual(layout.expand("ly"), "lun")     // l + y(un) -> un
    }

    func testZeroInitialUsesVowelLetter() {
        XCTAssertEqual(layout.expand("aa"), "a")       // 啊
        XCTAssertEqual(layout.expand("oo"), "o")       // 哦
        XCTAssertEqual(layout.expand("ee"), "e")       // 鹅
        XCTAssertEqual(layout.expand("ad"), "ai")      // 爱 (a + d)
        XCTAssertEqual(layout.expand("aj"), "an")      // 安 (a + j)
        XCTAssertEqual(layout.expand("ah"), "ang")     // 昂 (a + h)
        XCTAssertEqual(layout.expand("ac"), "ao")      // 奥 (a + c)
        XCTAssertEqual(layout.expand("ew"), "ei")      // (e + w)
        XCTAssertEqual(layout.expand("ef"), "en")      // 恩 (e + f)
        XCTAssertEqual(layout.expand("eg"), "eng")     // (e + g)
        XCTAssertEqual(layout.expand("er"), "er")      // 儿
        XCTAssertEqual(layout.expand("oz"), "ou")      // 欧 (o + z)
    }

    func testTrailingLoneKeyStaysLiteral() {
        XCTAssertEqual(layout.expand("v"), "v")        // pending zh initial
        XCTAssertEqual(layout.expand("hcn"), "haon")   // 好 + lone n
        XCTAssertEqual(layout.initial(for: "u"), "sh") // lone u -> sh (水)
    }
}
