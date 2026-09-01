import XCTest
@testable import Sime

/// True end-to-end Microsoft Shuangpin tests: real keystrokes go through
/// Composition into the real C++ decoder (ncnn GRU reranker off in this
/// target) backed by the bundled sime.dict/sime.cnt. Each case is a raw key
/// sequence a user types; assertions look at the actual candidate texts.
final class ShuangpinEndToEndTests: XCTestCase {
    private func candidates(for keys: String) throws -> [String] {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else {
            throw XCTSkip("sime.dict/sime.cnt not bundled into the test target")
        }
        let composition = Composition(decoder: decoder,
                                      inputScheme: .microsoftShuangpin)
        keys.forEach { composition.append(String($0)) }
        return composition.candidates.map(\.text)
    }

    // A lone trailing initial completes exactly one syllable, using the
    // preceding syllables as context. kdqru = kuang(kd)+quan(qr)+sh(u), and
    // must not spill into an extra syllable (矿泉水厂) nor split sh into s+h
    // (矿全社会).
    func testKdqruReachesKuangQuanShui() throws {
        let c = try candidates(for: "kdqru")
        XCTAssertTrue(c.contains("矿泉水"), "kdqru should complete to 矿泉水")
        XCTAssertFalse(c.contains("矿泉水厂"), "a lone initial must not add 厂")
        XCTAssertFalse(c.contains { $0.contains("社会") }, "sh must not split into s+h")
    }

    func testQruReachesQuanShen() throws {
        XCTAssertTrue(try candidates(for: "qru").contains("全身"),
                      "qru should offer 全身")
    }

    // hamig = ha+mi+the initial of gua; the completed ha/mi stay exact.
    func testHamigReachesHaMiGua() throws {
        XCTAssertTrue(try candidates(for: "hamig").contains("哈密瓜"),
                      "hamig should complete to 哈密瓜")
    }

    // nghem = neng(ng)+he(he)+the initial of ma; the completed "he" must stay
    // 喝/和 and never be lengthened to 黑/很.
    func testNghemKeepsHeLocked() throws {
        let c = try candidates(for: "nghem")
        XCTAssertTrue(c.contains("能喝"), "nghem should offer 能喝")
        XCTAssertFalse(c.contains { $0.contains("黑") }, "he must not become hei/黑")
    }

    func testNghemaReachesNengHeMa() throws {
        XCTAssertTrue(try candidates(for: "nghema").contains("能喝吗"),
                      "nghema (fully typed) should offer 能喝吗")
    }

    // nan = na + the initial of ni; "na" must stay locked, never merging into
    // "nan" (南) nor the word 南宁.
    func testNanKeepsNaLocked() throws {
        let c = try candidates(for: "nan")
        XCTAssertTrue(c.contains("那你"), "nan should offer 那你")
        XCTAssertFalse(c.contains("南宁"), "na must not lengthen to nan")
    }

    // hfhem = hen(hf)+he(he)+the initial of ma: legal pinyin, must not be empty
    // and must keep "he" locked.
    func testHfhemIsNotEmptyAndKeepsHeLocked() throws {
        let c = try candidates(for: "hfhem")
        XCTAssertTrue(c.contains("很"), "hfhem should offer 很…")
        XCTAssertFalse(c.contains { $0.contains("黑") }, "he must not become 黑")
    }

    // xih = xi + the initial of a huan/hu… syllable; "xi" stays locked (西/喜),
    // never lengthened to xian (先).
    func testXihKeepsXiLocked() throws {
        let c = try candidates(for: "xih")
        XCTAssertTrue(c.contains("喜欢"), "xih should offer 喜欢")
        XCTAssertFalse(c.contains { $0.contains("先") }, "xi must not become xian/先")
    }

    // A lone v/i/u maps to the retroflex initial zh/ch/sh, so it decodes as
    // Chinese, not the literal letter (which surfaced English up/us).
    func testLoneVIUMapToZhChShNotEnglish() throws {
        let u = try candidates(for: "u")
        XCTAssertTrue(u.contains("是"), "u -> sh should offer 是")
        XCTAssertFalse(u.contains("up"), "u must not surface English up")
        XCTAssertFalse(u.contains("us"), "u must not surface English us")
        XCTAssertTrue(try candidates(for: "i").contains("陈"), "i -> ch should offer 陈")
        XCTAssertTrue(try candidates(for: "v").contains("中"), "v -> zh should offer 中")
    }
}
