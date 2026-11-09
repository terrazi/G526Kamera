import XCTest
@testable import G526CameraDrive

final class BuildInfoTests: XCTestCase {
    func testVersionTextIsNeverEmpty() {
        XCTAssertFalse(BuildInfo.version.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}
