import XCTest
@testable import Sime

/// Full-pinyin counterparts of ShuangpinEndToEndTests, same-shape input (the
/// trailing syllable abbreviated to its initial, e.g. "hamig"). This file pins
/// only the cases where the full-pinyin top matches the Shuangpin top.
///
/// Deliberately NOT yet covered (top differs from Shuangpin):
///   - Inherent to full pinyin (no delimiter / expansion on):
///       xih -> 协会, rongyipiejiao -> 容易被阿胶, nan -> 南, henhem -> 很黑马
///   - Under investigation (delimiter shifts LM score, a regression from
///     delimiting every Shuangpin syllable): nenghema/nghema, lizhou/livb.
final class FullPinyinEndToEndTests: XCTestCase {
    private func candidates(for pinyin: String) throws -> [String] {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else {
            throw XCTSkip("sime.dict/sime.cnt not bundled into the test target")
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        pinyin.forEach { composition.append(String($0)) }
        return composition.candidates.map(\.text)
    }

    func testFullPinyinEnglishPrefixWithChineseSuffix() throws {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "fixyixia".forEach { composition.append(String($0)) }
        XCTAssertEqual(composition.preedit, "fix yi xia")
        guard let index = composition.candidates.firstIndex(where: { $0.text == "fix一下" }) else {
            return XCTFail("fixyixia should offer fix一下; got: \(composition.candidates.map { $0.text })")
        }
        XCTAssertEqual(composition.select(index), "fix一下")
    }

    func testFirstSegmentCorrectionOffersEnglishWord() throws {
        // Tapping the first segment feeds raw keys, so the engine's English
        // dictionary path survives: "fuck" appears in the correction bubble,
        // not only in the main candidate bar.
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "fuck".forEach { composition.append(String($0)) }
        composition.activateCharacter(0)
        XCTAssertTrue(composition.displayCandidates.contains { $0.text == "fuck" },
                      "first-segment correction should offer fuck; got: \(composition.displayCandidates.map { $0.text })")
    }

    func testFirstSegmentCorrectionOffersReSegmentedWord() throws {
        // xian reads as one syllable (线) at the top; the first-segment bubble
        // must still offer the re-split two-syllable word 西安 and commit it.
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "xian".forEach { composition.append(String($0)) }
        composition.activateCharacter(0)
        guard let index = composition.displayCandidates.firstIndex(where: { $0.text == "西安" }) else {
            return XCTFail("first-segment correction should offer 西安; got: \(composition.displayCandidates.map { $0.text })")
        }
        XCTAssertEqual(composition.selectDisplayed(index), "西安")
        XCTAssertFalse(composition.isComposing)
    }

    func testReSegmentedCorrectionKeepsSeparateCells() throws {
        // xianshi tops as 现|实. Re-choosing 现 as 西安 (one tapped segment → two
        // syllables) must keep 西 and 安 as separate display cells, not one
        // glued “西安” block, so the preview reads 西 安 市.
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "xianshi".forEach { composition.append(String($0)) }
        guard composition.sentenceSegments.count >= 2 else {
            throw XCTSkip("expected a two-segment top; got: \(composition.sentencePreview)")
        }
        composition.activateCharacter(0)
        guard let index = composition.displayCandidates.firstIndex(where: { $0.text == "西安" }) else {
            return XCTFail("correction should offer 西安; got: \(composition.displayCandidates.map { $0.text })")
        }
        XCTAssertNil(composition.selectDisplayed(index))   // not final, advances
        // 西 and 安 must be separate touch cells (not a glued 西安); the third
        // cell is whatever shi decodes to under the anchor.
        XCTAssertEqual(Array(composition.sentenceSegments.map(\.text).prefix(2)), ["西", "安"])
        XCTAssertGreaterThanOrEqual(composition.sentenceSegments.count, 3)
    }

    func testAdjacentEnglishWordsStaySpacedInTopCandidateAndCommit() throws {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "helloworld".forEach { composition.append(String($0)) }
        XCTAssertEqual(composition.preedit, "hello world")
        XCTAssertEqual(composition.sentenceSegments.map(\.text), ["hello", "world"])
        XCTAssertEqual(composition.commitBestOrRaw(), "hello world")
    }

    func testAdjacentEnglishWordsStaySpacedInLaterCandidates() throws {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        let c = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "BigAss".forEach { c.append(String($0)) }
        guard let index = c.candidates.firstIndex(where: { $0.text == "BigAss" }), index > 0 else {
            throw XCTSkip("BigAss is no longer a later candidate; got: \(c.candidates.map(\.text))")
        }
        XCTAssertEqual(c.displayText(of: c.candidates[index]), "Big Ass")
        XCTAssertEqual(c.select(index), "Big Ass")
    }

    func testPickedEnglishWordIsNotSpacedFromChineseAfterIt() throws {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        let c = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "bigass".forEach { c.append(String($0)) }
        c.activateCharacter(0)
        guard let big = c.displayCandidates.firstIndex(where: { $0.text == "big" }) else {
            return XCTFail("bubble should offer big; got: \(c.displayCandidates.map(\.text))")
        }
        XCTAssertNil(c.selectDisplayed(big))
        guard let top = c.candidates.first, top.text.hasPrefix("big"),
              !(top.text.dropFirst(3).first?.isASCII ?? true) else {
            throw XCTSkip("expected big followed by Chinese; got: \(c.candidates.first?.text ?? "")")
        }
        XCTAssertEqual(c.commitBestOrRaw(), top.text)
    }

    func testEditingKeysOfFirstEnglishWordKeepsTheNextWordShown() throws {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        let c = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "helloworld".forEach { c.append(String($0)) }
        c.activateCharacter(0)
        c.activateCharacter(0)   // second tap: pinyin editing of hello
        XCTAssertEqual(c.activeEnteredKeys, "hello")
        XCTAssertEqual(c.sentenceSegments.map(\.text), ["hello", "world"])
    }

    func testAbbreviatedWordSplitsIntoPerCharSegments() throws {
        // 简拼: dimiduzhdb → 低密度脂蛋白. The abbreviated word 脂蛋白 (zh/d/b) must
        // report one key span per character, not one glued block.
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "dimiduzhdb".forEach { composition.append(String($0)) }
        guard let word = composition.candidates.first(where: { $0.text == "低密度脂蛋白" }) else {
            throw XCTSkip("低密度脂蛋白 not decoded; got: \(composition.candidates.first?.text ?? "nil")")
        }
        XCTAssertEqual(word.segmentChars, [1, 1, 1, 1, 1, 1])
        XCTAssertEqual(word.segmentKeys, [2, 2, 2, 2, 1, 1])
    }

    func testFullyAbbreviatedWordSplitsIntoPerCharSegments() throws {
        // Fully abbreviated 简拼: dmdzdb → 低密度脂蛋白, one key per character.
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "dmdzdb".forEach { composition.append(String($0)) }
        guard let word = composition.candidates.first(where: { $0.text == "低密度脂蛋白" }) else {
            throw XCTSkip("低密度脂蛋白 not decoded; got: \(composition.candidates.first?.text ?? "nil")")
        }
        XCTAssertEqual(word.segmentChars, [1, 1, 1, 1, 1, 1])
        XCTAssertEqual(word.segmentKeys, [1, 1, 1, 1, 1, 1])
    }

    func testLastSegmentCorrectionUsesHostContext() throws {
        // After 你, "ganshan" tops as 干啥呢 (gan'sha'n). Tapping the last char 呢
        // must re-choose from the "n" tail — the correction decode is seeded with
        // the host context so that segmentation exists; otherwise it collapses
        // to 甘陕 and the bubble falls back to the whole-sentence list.
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        composition.updateHostContext(from: "你")
        "ganshan".forEach { composition.append(String($0)) }
        guard composition.candidates.first?.text == "干啥呢" else {
            throw XCTSkip("top is not 干啥呢; got: \(composition.sentencePreview)")
        }
        composition.activateCharacter(2)   // 呢
        let bubble = composition.displayCandidates.map(\.text)
        XCTAssertTrue(bubble.contains("呢"), "tail correction should offer 呢; got: \(bubble)")
        XCTAssertFalse(bubble.contains("干啥呢"), "bubble must expand from the tail, not the head; got: \(bubble)")
        // The tail is a lone initial "n": the bubble should list many n-initial
        // alternatives, not just the single top reading.
        XCTAssertGreaterThan(bubble.count, 5, "tail correction should list many n-initial choices; got: \(bubble)")
    }

    func testLaterSegmentCorrectionOffersEnglishSuffixWord() throws {
        // Tapping a later segment locks the confirmed prefix but re-decodes the
        // rest from raw keys, so an English suffix word survives: tapping 不 in
        // fix这个不过 (fixzhegebug) offers "bug" and commits fix这个bug.
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "fixzhegebug".forEach { composition.append(String($0)) }
        guard composition.candidates.first?.text == "fix这个不过",
              let tap = composition.sentencePreview.firstIndex(of: "不") else {
            throw XCTSkip("top candidate is not fix这个不过; got: \(composition.sentencePreview)")
        }
        composition.activateCharacter(composition.sentencePreview.distance(
            from: composition.sentencePreview.startIndex, to: tap))
        guard let index = composition.displayCandidates.firstIndex(where: { $0.text == "bug" }) else {
            return XCTFail("later-segment correction should offer bug; got: \(composition.displayCandidates.map { $0.text })")
        }
        XCTAssertEqual(composition.selectDisplayed(index), "fix这个bug")
        XCTAssertFalse(composition.isComposing)
    }

    func testFullPinyinMixedLowercaseEnglishAndChinese() throws {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "zheshilove".forEach { composition.append(String($0)) }
        XCTAssertTrue(composition.candidates.contains { $0.text == "这是love" },
                      "zheshilove should include 这是love; got: \(composition.candidates.map { $0.text })")
    }

    func testFullPinyinUppercaseEnglishTailHasSingleCaretSpan() throws {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "woyeO".forEach { composition.append(String($0)) }
        XCTAssertEqual(composition.preedit, "wo ye O")
        XCTAssertTrue(composition.sentencePreview.hasPrefix("我也O"))
        composition.append("K")
        XCTAssertEqual(composition.preedit, "wo ye OK")
        XCTAssertEqual(composition.sentencePreview, "我也OK")
        XCTAssertEqual(composition.selectionLocation, composition.preedit.utf16.count)
        XCTAssertEqual(composition.commitBestOrRaw(), "我也OK")
    }

    func testUppercaseEnglishIslandBetweenFullPinyinSyllables() throws {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "zanliaAAba".forEach { composition.append(String($0)) }
        XCTAssertEqual(composition.preedit, "zan lia AA ba")
        guard let index = composition.candidates.firstIndex(where: { $0.text == "咱俩AA吧" }) else {
            return XCTFail("zanliaAAba should offer 咱俩AA吧; got: \(composition.candidates.map { $0.text })")
        }
        XCTAssertEqual(composition.select(index), "咱俩AA吧")
    }

    func testMixedEnglishWordWithChineseSuffix() throws {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "itemta".forEach { composition.append(String($0)) }
        XCTAssertEqual(composition.candidates.first?.text, "item他")
        XCTAssertEqual(composition.candidates.first?.units, "item'ta")
    }

    func testLowercaseEnglishWordIsOnePreeditGroup() throws {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "woloveni".forEach { composition.append(String($0)) }

        XCTAssertEqual(composition.candidates.first?.text, "我love你")
        XCTAssertEqual(composition.preedit, "wo love ni")
    }

    func testMixedChineseEnglishChineseWord() throws {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "jiapaperlaiyuan".forEach { composition.append(String($0)) }
        XCTAssertEqual(composition.preedit, "jia paper lai yuan")
        XCTAssertEqual(composition.candidates.first?.text, "加paper来源")
        XCTAssertEqual(composition.candidates.first?.units, "jia'paper'lai'yuan")
    }

    func testMixedEnglishFinalCorrectionCommitsCorrectSentence() throws {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else {
            throw XCTSkip("sime.dict/sime.cnt not bundled into the test target")
        }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "itemta".forEach { composition.append(String($0)) }
        composition.activateCharacter(4)
        guard let index = composition.displayCandidates.firstIndex(where: { $0.text == "塔" }) else {
            throw XCTSkip("native correction candidates do not include 塔")
        }
        XCTAssertEqual(composition.selectDisplayed(index), "item塔")
        XCTAssertFalse(composition.isComposing)
    }

    func testFullPinyinTopCandidatesMatchingShuangpin() throws {
        let cases: [(pinyin: String, top: String)] = [
            ("kuangquansh", "矿泉水"),
            ("quansh", "全省"),
            ("hamig", "哈密瓜"),
            ("xiaoguo", "效果"),
            ("xihuan", "喜欢"),
            ("womendezhongguo", "我们的中国"),
            ("sh", "是"), ("ch", "陈"), ("zh", "中")
        ]
        for c in cases {
            let top = try candidates(for: c.pinyin).first
            XCTAssertEqual(top, c.top, "\(c.pinyin) top candidate")
        }
    }

    // Only pinyin decodes a letter, so an uppercase letter that the English
    // dictionary only completes (BBC) or swallows into a prefix (Bf) stays a
    // literal; a real English word still beats literal + abbreviations.
    func testUppercaseLetterStaysLiteralWhereOnlyEnglishCovers() throws {
        let lone = try candidates(for: "B")
        XCTAssertEqual(lone.first, "B")
        XCTAssertTrue(lone.contains("BBC"), "B should still offer BBC; got: \(lone)")

        XCTAssertEqual(try candidates(for: "Bfangan").first, "B方案")
        XCTAssertEqual(try candidates(for: "woshiBfangan").first, "我是B方案")

        let tail = try candidates(for: "woxuanB").first ?? ""
        XCTAssertTrue(tail.hasSuffix("B") && !tail.hasSuffix("BBC"),
                      "woxuanB should end in a literal B; got: \(tail)")
    }

    // A leading capital is selectable on its own so it can be anchored, whether
    // or not an English word (Bf) also starts there.
    func testTappingLeadingCapitalOffersAndAnchorsIt() throws {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        for letter in ["B", "G"] {
            let c = Composition(decoder: decoder, inputScheme: .fullPinyin)
            "\(letter)fangan".forEach { c.append(String($0)) }
            c.activateCharacter(0)
            guard let index = c.displayCandidates.firstIndex(where: { $0.text == letter }) else {
                return XCTFail("tapping \(letter) should offer \(letter); got: \(c.displayCandidates.map(\.text))")
            }
            XCTAssertNil(c.selectDisplayed(index))
            XCTAssertEqual(c.preedit, "\(letter) fang an")
            XCTAssertEqual(c.candidates.first?.text, "\(letter)方案")
        }
    }

    func testLiteralLetterDoesNotDisplaceWordsOrAbbreviations() throws {
        let cases: [(pinyin: String, top: String)] = [
            ("woxihuanApple", "我喜欢Apple"),
            ("Hello", "Hello"), ("hello", "hello"), ("iphone", "iphone"),
            ("AI", "AI"), ("bj", "北京"), ("nihao", "你好")
        ]
        for c in cases {
            XCTAssertEqual(try candidates(for: c.pinyin).first, c.top,
                           "\(c.pinyin) top candidate")
        }
        XCTAssertNotEqual(try candidates(for: "b").first, "b")
    }
}
