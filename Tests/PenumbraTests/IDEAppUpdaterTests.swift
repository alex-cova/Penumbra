import XCTest
@testable import Umbra

@MainActor
final class IDEAppUpdaterTests: XCTestCase {
    func testDisabledOutsideAppBundle() {
        XCTAssertFalse(IDEAppUpdater.isEnabled)
        XCTAssertFalse(IDEAppUpdater.canCheckForUpdates)
    }
}
