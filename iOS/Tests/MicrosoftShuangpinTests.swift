import XCTest
@testable import Sime

final class MicrosoftShuangpinTests: XCTestCase {
    func testMicrosoftAndSogouShareThePrebuiltIndex() {
        XCTAssertEqual(InputScheme.microsoftShuangpin.shuangpinIndexName, "sime.sp")
        XCTAssertEqual(InputScheme.sogouShuangpin.shuangpinIndexName, "sime.sp")
        XCTAssertTrue(InputScheme.microsoftShuangpin.usesSemicolonKey)
        XCTAssertTrue(InputScheme.sogouShuangpin.usesSemicolonKey)
    }
}
