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

    private func composition(for keys: String,
                             scheme: InputScheme = .microsoftShuangpin) throws -> Composition {
        let bundle = Bundle(for: Self.self)
        guard let indexName = scheme.shuangpinIndexName,
              let decoder = NativePinyinDecoder(bundle: bundle,
                                                indexName: indexName) else {
            throw XCTSkip("sime.dict/sime.cnt not bundled into the test target")
        }
        let composition = Composition(decoder: decoder, inputScheme: scheme)
        keys.forEach { composition.append(String($0)) }
        return composition
    }

    func testEnglishPrefixWithShuangpinChineseSuffix() throws {
        let c = try composition(for: "fixyixw") // fix + yi + xia
        XCTAssertEqual(c.preedit, "fix yi xw")
        guard let index = c.candidates.firstIndex(where: { $0.text == "fix一下" }) else {
            return XCTFail("fixyixw should offer fix一下; got: \(c.candidates.map { $0.text })")
        }
        XCTAssertEqual(c.select(index), "fix一下")
        XCTAssertFalse(c.isComposing)
    }

    func testEnglishCorrectionReplacesTheRemainingDecodedSpan() throws {
        let c = try composition(for: "veuilove") // zhe + shi + love
        XCTAssertEqual(c.candidates.first?.text, "这是裸着")
        c.activateCharacter(2)
        guard let love = c.displayCandidates.firstIndex(where: { $0.text == "love" }) else {
            return XCTFail("tapping 裸 should offer love; got: \(c.displayCandidates.map { $0.text })")
        }
        XCTAssertEqual(c.selectDisplayed(love), "这是love")
        XCTAssertFalse(c.isComposing)
    }

    func testSelectingLoveForLuoJoinsMarkedRawGroups() throws {
        let c = try composition(for: "woloveni")
        XCTAssertEqual(c.candidates.first?.text, "沃洛着你")
        c.activateCharacter(1)
        guard let love = c.displayCandidates.firstIndex(where: { $0.text == "love" }) else {
            return XCTFail("tapping 洛 should offer love; got: \(c.displayCandidates.map { $0.text })")
        }
        XCTAssertNil(c.selectDisplayed(love))
        XCTAssertEqual(c.preedit, "wo love ni")
    }

    func testEnglishCorrectionKeepsExpandedAnchorAndAdvancesToNextHan() throws {
        let c = try composition(for: "veuiloveni")
        c.activateCharacter(2)
        guard let love = c.displayCandidates.firstIndex(where: { $0.text == "love" }) else {
            return XCTFail("tapping 裸 should offer love; got: \(c.displayCandidates.map { $0.text })")
        }
        XCTAssertNil(c.selectDisplayed(love))
        XCTAssertEqual(c.sentencePreview, "这是love你")
        XCTAssertEqual(c.preedit, "ve ui love ni")
        XCTAssertEqual(c.selectionLocation, c.preedit.utf16.count)
        XCTAssertEqual(c.sentenceSegments.map(\.text), ["这", "是", "love", "你"])
        XCTAssertEqual(c.activeCharacterIndex, 6)
    }

    func testUppercaseEnglishIslandBetweenShuangpinSyllables() throws {
        let c = try composition(for: "zjlwAAba")
        XCTAssertEqual(c.preedit, "zj lw AA ba")
        guard let index = c.candidates.firstIndex(where: { $0.text == "咱俩AA吧" }) else {
            return XCTFail("zjlwAAba should offer 咱俩AA吧; got: \(c.candidates.map { $0.text })")
        }
        XCTAssertEqual(c.select(index), "咱俩AA吧")
    }

    func testLeadingUppercaseLetterDoesNotSwallowShuangpinSuffix() throws {
        // A capital letter whose code happens to spell an English prefix (Bi)
        // must stay a standalone literal so the shuangpin after it realigns
        // (ie xc = 撤销), instead of gluing into "Biex" + a stray tail.
        let c = try composition(for: "Biexc")
        XCTAssertEqual(c.preedit, "B ie xc")
        guard let index = c.candidates.firstIndex(where: { $0.text == "B撤销" }) else {
            return XCTFail("Biexc should offer B撤销; got: \(c.candidates.map { $0.text })")
        }
        XCTAssertEqual(c.select(index), "B撤销")
        XCTAssertFalse(c.isComposing)
    }

    func testSelectingBiKeepsItAsOneFirstRowSegment() throws {
        // Picking the English candidate "Bi" commits it as a prefix and
        // re-decodes the tail; the first row must show "Bi" as one cell, not
        // split into "B" + "i".
        let c = try composition(for: "Biexc")
        guard let bi = c.candidates.firstIndex(where: { $0.text == "Bi" }) else {
            return XCTFail("Biexc should offer Bi; got: \(c.candidates.map { $0.text })")
        }
        _ = c.selectDisplayed(bi)
        XCTAssertEqual(c.sentenceSegments.first?.text, "Bi")
    }

    func testCorrectionBubbleEnglishReplacementCrossingBoundaryCommits() throws {
        // Top "B撤销" segments as B|ie|xc. Tapping the leading "B" opens its
        // correction list, which offers "Bi". "Bi" is 2 keys and crosses the
        // B|ie boundary, so it can't be a per-segment anchor; selecting it must
        // commit "Bi" as a prefix and re-decode the tail (not silently fail and
        // leave the active state dirtying later taps).
        let c = try composition(for: "Biexc")
        c.activateCharacter(0)
        guard let bi = c.displayCandidates.firstIndex(where: { $0.text == "Bi" }) else {
            return XCTFail("B correction list should offer Bi; got: \(c.displayCandidates.map { $0.text })")
        }
        XCTAssertNil(c.selectDisplayed(bi))
        XCTAssertNil(c.activeCharacterIndex)
        XCTAssertEqual(c.preedit, "Biex c")
        XCTAssertTrue(c.sentencePreview.hasPrefix("Bi"))
        XCTAssertTrue(c.isComposing)
    }

    func testLeadingUppercaseRealignsRegardlessOfTheLetter() throws {
        // The realignment must not depend on which capital was typed: any
        // leading uppercase letter stays its own literal and the shuangpin
        // suffix (ie xc = 撤销) decodes the same.
        for letter in ["H", "Z", "Q"] {
            let c = try composition(for: "\(letter)iexc")
            XCTAssertEqual(c.preedit, "\(letter) ie xc")
            XCTAssertTrue(c.candidates.contains { $0.text == "\(letter)撤销" },
                          "\(letter)iexc should offer \(letter)撤销; got: \(c.candidates.map { $0.text })")
        }
    }

    func testLeadingUppercaseBeforeMultiSyllableWord() throws {
        // B + vs go = 中国: the capital stays literal and both syllables align.
        let c = try composition(for: "Bvsgo")
        XCTAssertEqual(c.preedit, "B vs go")
        guard let index = c.candidates.firstIndex(where: { $0.text == "B中国" }) else {
            return XCTFail("Bvsgo should offer B中国; got: \(c.candidates.map { $0.text })")
        }
        XCTAssertEqual(c.select(index), "B中国")
    }

    func testCapitalizedEnglishWordIsNotSplitByUppercaseBoundary() throws {
        // The uppercase-boundary edge must not break a genuine capitalized
        // English word apart: Google stays one English candidate.
        let c = try composition(for: "Google")
        XCTAssertTrue(c.candidates.contains { $0.text == "Google" },
                      "Google should stay one English candidate; got: \(c.candidates.map { $0.text })")
    }

    func testUppercaseEnglishTailKeepsMarkedTextAndCaretAligned() throws {
        let c = try composition(for: "woyeO")
        XCTAssertEqual(c.preedit, "wo ye O")
        XCTAssertEqual(c.sentencePreview, "我也O")
        XCTAssertEqual(c.selectionLocation, c.preedit.utf16.count)

        c.append("K")
        XCTAssertEqual(c.preedit, "wo ye OK")
        XCTAssertEqual(c.sentencePreview, "我也OK")
        XCTAssertEqual(c.selectionLocation, c.preedit.utf16.count)
        XCTAssertEqual(c.commitBestOrRaw(), "我也OK")
    }

    func testIndexCorrectionAtSingleCharacterShowsMultiCharacterWords() throws {
        let c = try composition(for: "x;jwbi")
        c.activateCharacter(1)
        XCTAssertTrue(c.displayCandidates.contains { $0.text == "假币" },
                      "tapping 价 should offer 假币; got: \(c.displayCandidates.map { $0.text })")
    }

    func testXiaoheIndexDecodesAndCommitsChinese() throws {
        let c = try composition(for: "nihc", scheme: .xiaoheShuangpin)
        guard let index = c.candidates.firstIndex(where: { $0.text == "你好" }) else {
            return XCTFail("Xiaohe nihc should offer 你好; got: \(c.candidates.map { $0.text })")
        }
        XCTAssertEqual(c.select(index), "你好")
    }

    func testZiranmaIndexDecodesAndCommitsChinese() throws {
        let c = try composition(for: "nihk", scheme: .ziranmaShuangpin)
        guard let index = c.candidates.firstIndex(where: { $0.text == "你好" }) else {
            return XCTFail("Ziranma nihk should offer 你好; got: \(c.candidates.map { $0.text })")
        }
        XCTAssertEqual(c.select(index), "你好")
    }

    func testExpandedTrailingInitialStillSplitsDecoderCharacterSpans() throws {
        let c = try composition(for: "kdqru")
        XCTAssertEqual(c.candidates.first?.text, "矿泉水")
        XCTAssertEqual(c.sentenceSegments.map(\.text), ["矿", "泉", "水"])
        XCTAssertEqual(c.preedit, "kd qr u")
    }

    // A lone trailing initial completes one syllable; it must not spill into an
    // extra word or split sh into s+h.
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

    func testLoneShuangpinInitialOffersChineseIndexCandidates() throws {
        for keys in ["u", "i", "v"] {
            let results = try candidates(for: keys)
            XCTAssertTrue(results.first?.contains(where: { !$0.isASCII }) == true,
                          "\(keys) should lead with a Chinese index candidate")
        }
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

    func testIndexWordsStillExposeOneTappableSegmentPerChineseCharacter() throws {
        let c = try composition(for: "womfdevsgo")
        XCTAssertEqual(c.candidates.first?.text, "我们的中国")
        XCTAssertEqual(c.sentenceSegments.map(\.text), ["我", "们", "的", "中", "国"])
        XCTAssertEqual(c.preedit, "wo mf de vs go")
        c.activateCharacter(1)
        c.activateCharacter(1)
        XCTAssertEqual(c.activeEnteredKeys, "mf")
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

    // The first tap highlights the character; a second tap on the same
    // character exposes its literal two-key code.
    func testCorrectionRetainsLiteralKeys() throws {
        let composition = try composition(for: "xcgo")
        composition.activateCharacter(0)
        XCTAssertNil(composition.activeEnteredKeys)
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
        ]
        for c in cases {
            let top = try candidates(for: c.keys).first
            XCTAssertEqual(top, c.top, "\(c.keys) top candidate")
        }
    }
}
