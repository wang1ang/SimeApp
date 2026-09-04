import XCTest
@testable import Sime

/// Verifies every standard Mandarin pinyin syllable in `quanpin.txt` can be
/// produced by each Shuangpin layout. This is the executable coverage contract
/// for the layouts: a missing syllable means a key→final table gap.
final class ShuangpinCoverageTests: XCTestCase {
    // Two rare interjections that double pinyin fundamentally cannot encode:
    // there is no key for a bare `o` after these initials, so `lo`→luo and
    // `yo`→yuo. They stay in quanpin.txt (the full inventory) but are excluded
    // from the required-coverage set for every scheme.
    private let unencodable: Set<String> = ["lo", "yo"]

    private let keys = Array("abcdefghijklmnopqrstuvwxyz;")

    /// Every pinyin string producible by a two-key syllable in `layout`.
    private func reachableSyllables(_ layout: ShuangpinLayout) -> Set<String> {
        var reachable = Set<String>()
        for k1 in keys {
            for k2 in keys {
                reachable.insert(layout.expand(String([k1, k2])))
            }
        }
        return reachable
    }

    /// The full-pinyin inventory from quanpin.txt, with ü normalized to Sime's
    /// `v` notation and the header/comment lines stripped.
    private func quanpinSyllables() throws -> [String] {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "quanpin", withExtension: "txt"),
                                "quanpin.txt must be bundled as a test resource")
        let text = try String(contentsOf: url, encoding: .utf8)
        var syllables: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Keep only pure syllable rows: drop blanks, Markdown headings
            // (start with `#`), and any prose line — prose always carries a
            // non-ASCII character other than the pinyin `ü` (Chinese text,
            // full-width punctuation, or `ê`).
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let isSyllableRow = trimmed.unicodeScalars.allSatisfy { $0.isASCII || $0 == "\u{fc}" }
            guard isSyllableRow else { continue }
            for token in trimmed.split(separator: " ") {
                let syllable = String(token).replacingOccurrences(of: "ü", with: "v")
                if syllable.allSatisfy({ $0.isLowercase && $0.isASCII }) {
                    syllables.append(syllable)
                }
            }
        }
        return syllables
    }

    func testQuanpinListIsNonTrivial() throws {
        // Guards against a mis-parsed or unbundled resource silently passing
        // the coverage assertions on an empty list.
        let syllables = try quanpinSyllables()
        XCTAssertGreaterThan(syllables.count, 390, "expected the full ~410 inventory")
        XCTAssertTrue(syllables.contains("zhuang"))
        XCTAssertTrue(syllables.contains("nv"))
    }

    func testMicrosoftCoversAllPinyin() throws { try assertCoverage(.microsoft, "微软/搜狗") }
    func testXiaoheCoversAllPinyin() throws { try assertCoverage(.xiaohe, "小鹤") }
    func testZiranmaCoversAllPinyin() throws { try assertCoverage(.ziranma, "自然码") }

    private func assertCoverage(_ layout: ShuangpinLayout, _ name: String) throws {
        let reachable = reachableSyllables(layout)
        let required = try quanpinSyllables().filter { !unencodable.contains($0) }
        let missing = required.filter { !reachable.contains($0) }.sorted()
        XCTAssertTrue(missing.isEmpty, "\(name) 无法覆盖以下全拼音节: \(missing)")
    }
}
