import Foundation
import XCTest
@testable import Umbra

/// Launch restores every stored window: the first window queues one more for each of the others,
/// and each of those takes its stored session when it bootstraps.
@MainActor
final class IDERestoreWindowsTests: XCTestCase {
    private var opened = 0
    private let registry = IDEWindowRegistry.shared

    override func setUp() {
        registry.resetOpeningForTests()
        opened = 0
    }

    override func tearDown() {
        registry.resetOpeningForTests()
    }

    private func session(_ width: Double) -> IDEWindowSession {
        IDEWindowSession(windowID: UUID(), sidebarWidth: width)
    }

    func testEachQueuedWindowOpensOneWindowAndHandsOutItsOwnSessionInOrder() {
        registry.setOpenWindowAction { [self] in opened += 1 }

        registry.queueRestoredWindows([session(1), session(2)])

        XCTAssertEqual(opened, 2, "one window per stored session")
        XCTAssertEqual(registry.takeRestoreSession()?.sidebarWidth, 1)
        XCTAssertEqual(registry.takeRestoreSession()?.sidebarWidth, 2)
        XCTAssertNil(registry.takeRestoreSession(), "each session goes to one window")
    }

    func testWindowsQueuedBeforeOpenWindowIsWiredOpenWhenItIs() {
        registry.queueRestoredWindows([session(1), session(2), session(3)])
        XCTAssertNil(registry.takeRestoreSession(), "nothing is handed out before its window exists")

        registry.setOpenWindowAction { [self] in opened += 1 }

        XCTAssertEqual(opened, 3)
        XCTAssertEqual(registry.takeRestoreSession()?.sidebarWidth, 1)
    }

    func testQueuingNothingOpensNothing() {
        registry.setOpenWindowAction { [self] in opened += 1 }

        registry.queueRestoredWindows([])

        XCTAssertEqual(opened, 0)
        XCTAssertNil(registry.takeRestoreSession())
    }

    func testARestoreJobIsNotTakenByAFolderOrFileRequest() {
        registry.setOpenWindowAction { [self] in opened += 1 }
        registry.queueRestoredWindows([session(7)])
        // An ordinary New Window queued behind it.
        XCTAssertTrue(registry.openNewWindow())

        XCTAssertEqual(registry.takeRestoreSession()?.sidebarWidth, 7)
        XCTAssertNil(registry.takeRestoreSession(), "the plain New Window carries no session")
        XCTAssertEqual(opened, 2)
    }
}
