import XCTest
@testable import Sime

/// Verifies generated key maps against the bundled decoder indexes.
final class ShuangpinCoverageTests: XCTestCase {
    private let unencodable: Set<String> = ["lo", "yo"]

    func testQuanpinListIsNonTrivial() throws {
        let syllables = try quanpinSyllables()
        XCTAssertGreaterThan(syllables.count, 390, "expected the full syllable inventory")
        XCTAssertTrue(syllables.contains("zhuang"))
        XCTAssertTrue(syllables.contains("nv"))
    }

    func testMicrosoftIndexCoversAllPinyin() throws {
        try assertIndexCoverage(.microsoftShuangpin, map: "sogou.map")
    }

    func testXiaoheIndexCoversAllPinyin() throws {
        try assertIndexCoverage(.xiaoheShuangpin, map: "xiaohe.map")
    }

    func testZiranmaIndexCoversAllPinyin() throws {
        try assertIndexCoverage(.ziranmaShuangpin, map: "ziranma.map")
    }

    private func assertIndexCoverage(_ scheme: InputScheme, map name: String) throws {
        let bundle = Bundle(for: Self.self)
        guard let indexName = scheme.shuangpinIndexName,
              let decoder = NativePinyinDecoder(bundle: bundle,
                                                indexName: indexName) else {
            throw XCTSkip("decoder index for \(scheme) is not bundled")
        }
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "txt"),
                                "missing generated map \(name).txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        var mapping: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let row = line.trimmingCharacters(in: .whitespaces)
            guard !row.isEmpty, !row.hasPrefix("#") else { continue }
            let columns = row.split(whereSeparator: \.isWhitespace)
            guard columns.count == 2 else { continue }
            mapping[String(columns[0]).replacingOccurrences(of: "ü", with: "v")] =
                String(columns[1])
        }

        let required = Set(try quanpinSyllables()).subtracting(unencodable)
        let missing = required.subtracting(mapping.keys)
        XCTAssertTrue(missing.isEmpty, "\(scheme) map misses: \(missing.sorted())")
        for syllable in required.sorted() {
            guard let keys = mapping[syllable] else { continue }
            let hasHanPath = decoder.syllableCandidates(keys).contains { candidate in
                candidate.text.contains { !$0.isASCII }
                    && candidate.segmentKeys.reduce(0, +) == keys.utf8.count
            }
            XCTAssertTrue(hasHanPath, "\(scheme) index cannot decode \(syllable) from \(keys)")
        }
    }

    private func quanpinSyllables() throws -> [String] {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "quanpin", withExtension: "txt"),
                                "quanpin.txt must be bundled as a test resource")
        let text = try String(contentsOf: url, encoding: .utf8)
        var syllables: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let row = line.trimmingCharacters(in: .whitespaces)
            guard !row.isEmpty, !row.hasPrefix("#"),
                  row.unicodeScalars.allSatisfy({ scalar in
                      let value = scalar.value
                      return (97...122).contains(value)
                          || value == 0x20 || value == 0x09 || value == 0x00FC
                  }) else { continue }
            for token in row.split(separator: " ") {
                let syllable = String(token).replacingOccurrences(of: "ü", with: "v")
                if syllable.allSatisfy({ $0.isLowercase && $0.isASCII }) {
                    syllables.append(syllable)
                }
            }
        }
        return syllables
    }
}
