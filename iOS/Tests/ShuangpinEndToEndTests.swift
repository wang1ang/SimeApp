import XCTest
@testable import Sime

/// True end-to-end Microsoft Shuangpin tests: real keystrokes go through
/// Composition into the real C++ decoder (ncnn GRU reranker off in this
/// target) backed by the bundled sime.dict/sime.cnt. Each case is a raw key
/// sequence a user types; assertions look at the actual candidate texts.
final class ShuangpinEndToEndTests: XCTestCase {
    private func candidates(for keys: String) throws -> [String] {
        try composition(for: keys).candidates.map(\.text)
    }

    private func composition(for keys: String) throws -> Composition {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else {
            throw XCTSkip("sime.dict/sime.cnt not bundled into the test target")
        }
        let composition = Composition(decoder: decoder,
                                      inputScheme: .microsoftShuangpin)
        keys.forEach { composition.append(String($0)) }
        return composition
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

    // rsyipxjc = rong(rs)+yi(yi)+pie(px)+jiao(jc). Each syllable is delimited,
    // so the engine must not re-segment the pie chunk into pi+e (容易被阿胶);
    // 撇 must be reachable.
    func testRongYiPieJiaoCanProducePie() throws {
        let c = try candidates(for: "rsyipxjc")
        XCTAssertTrue(c.contains { $0.contains("撇") },
                      "rsyipxjc should offer a candidate containing 撇")
        XCTAssertFalse(c.contains { $0.contains("被阿") },
                      "pie must not split into pi+e (被阿)")
    }

    // Each syllable is two keys: the preedit groups xc|go and 效果 decodes.
    func testTwoKeysPerSyllable() throws {
        let composition = try composition(for: "xcgo")
        XCTAssertEqual(composition.preedit, "xc go")
        XCTAssertTrue(composition.candidates.map(\.text).contains("效果"),
                      "xcgo should decode 效果")
    }

    // An odd trailing key stays in the composition until its pair completes.
    func testOddKeyRemainsUntilPairCompletes() throws {
        let composition = try composition(for: "xcg")
        XCTAssertEqual(composition.raw, "xcg")
        XCTAssertTrue(composition.isComposing)
        XCTAssertEqual(composition.candidates.last?.text, "xcg",
                       "the literal English fallback trails the candidates")
        composition.append("o")
        XCTAssertTrue(composition.candidates.map(\.text).contains("效果"))
    }

    // A long sentence keeps every syllable boundary through to commit.
    func testLongSentenceCommits() throws {
        // womfdevsgo = wo+men+de+zhong+guo.
        let composition = try composition(for: "womfdevsgo")
        let texts = composition.candidates.map(\.text)
        guard let index = texts.firstIndex(of: "我们的中国") else {
            return XCTFail("womfdevsgo should offer 我们的中国; got \(texts)")
        }
        XCTAssertEqual(composition.select(index), "我们的中国")
        XCTAssertFalse(composition.isComposing)
    }

    // Activating the first character exposes its literal two-key code.
    func testCorrectionRetainsLiteralKeys() throws {
        let composition = try composition(for: "xcgo")
        composition.activateCharacter(0)
        XCTAssertEqual(composition.activeEnteredKeys, "xc")
    }

    // 双拼 -> 首选: pin the real top candidate for each key sequence so any
    // decode/segmentation regression shows up here (candidates.first is the
    // top Chinese path; the literal English fallback trails it).
    func testShuangpinTopCandidates() throws {
        let cases: [(keys: String, top: String)] = [
            ("xcgo", "效果"),        // xiao guo
            ("xihr", "喜欢"),        // xi huan
            ("livb", "利州"),        // li zhou (complete syllables, no expand)
            ("womfdevsgo", "我们的中国"),
            ("rsyipxjc", "容易撇较"),  // rong yi pie jiao
            ("nghem", "能喝吗"),      // neng he m(a)
            ("nghema", "能喝吗"),
            ("nan", "那你"),         // na n(i)
            ("hamig", "哈密瓜"),
            ("kdqru", "矿泉水"),
            ("qru", "全省"),         // quan sh(...)
            ("xih", "喜欢"),
            ("hfhem", "很盒马"),
            ("u", "是"), ("i", "陈"), ("v", "中")
        ]
        for c in cases {
            let top = try candidates(for: c.keys).first
            XCTAssertEqual(top, c.top, "\(c.keys) top candidate")
        }
    }
}
