import XCTest
@testable import Sime

/// True end-to-end Microsoft Shuangpin tests: real keystrokes go through
/// Composition into the real C++ decoder (ncnn GRU reranker off in this
/// target) backed by the bundled sime.dict/sime.cnt. Guards the full seam
/// (key mapping -> apostrophe-delimited pinyin -> engine completion) that the
/// fake-decoder wiring tests and the require/Sime C++ tests each cover only
/// on one side.
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

    func testKdqruReachesKuangQuanShui() throws {
        // kdqru = kuang(kd) + quan(qr) + the lone initial of shui (u -> sh).
        XCTAssertTrue(try candidates(for: "kdqru").contains("矿泉水"),
                      "kdqru should complete to 矿泉水")
    }

    func testQruReachesQuanShen() throws {
        // qru = quan(qr) + the lone initial of shen (u -> sh).
        XCTAssertTrue(try candidates(for: "qru").contains("全身"),
                      "qru should offer 全身")
    }
}
