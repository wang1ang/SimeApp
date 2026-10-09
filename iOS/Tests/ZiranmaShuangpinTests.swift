import XCTest
@testable import Sime

final class ZiranmaShuangpinTests: XCTestCase {
    func testUsesItsOwnPrebuiltIndex() {
        XCTAssertEqual(InputScheme.ziranmaShuangpin.shuangpinIndexName,
                       "sime.ziranma.sp")
        XCTAssertFalse(InputScheme.ziranmaShuangpin.usesSemicolonKey)
    }
}
