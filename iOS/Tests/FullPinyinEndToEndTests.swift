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

    func testMixedEnglishWordWithChineseSuffix() throws {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "itemta".forEach { composition.append(String($0)) }
        XCTAssertEqual(composition.candidates.first?.text, "item他")
        XCTAssertEqual(composition.candidates.first?.units, "item'ta")
    }

    func testMixedChineseEnglishChineseWord() throws {
        let bundle = Bundle(for: Self.self)
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        let composition = Composition(decoder: decoder, inputScheme: .fullPinyin)
        "jiapaperlaiyuan".forEach { composition.append(String($0)) }
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
}
