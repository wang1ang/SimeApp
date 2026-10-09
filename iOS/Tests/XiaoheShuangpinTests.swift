import XCTest
@testable import Sime

final class XiaoheShuangpinTests: XCTestCase {
    func testUsesItsOwnPrebuiltIndex() {
        XCTAssertEqual(InputScheme.xiaoheShuangpin.shuangpinIndexName,
                       "sime.xiaohe.sp")
        XCTAssertFalse(InputScheme.xiaoheShuangpin.usesSemicolonKey)
    }
}
