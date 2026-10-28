import XCTest
@testable import BixkuCore

final class BixkuCoreTests: XCTestCase {
    func testVersionIsSemver() {
        let parts = BixkuCore.version.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil })
    }
}
