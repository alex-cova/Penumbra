import XCTest
@testable import Umbra

/// F-11: the window's terminal hosts live in their own registry, not on `IDEWorkspace`.
/// Registration compacts dead views, and teardown ends every shell, without opening a window.
/// Hosts stay inactive here, so no shell ever starts.
@MainActor
final class IDETerminalHostRegistryTests: XCTestCase {
    private func makeHost() -> IDETerminalHostView {
        IDETerminalHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    func testRegisterAndActiveHost() {
        let registry = IDETerminalHostRegistry()
        XCTAssertTrue(registry.isEmpty)
        XCTAssertNil(registry.activeHost())

        let second = makeHost()
        weak var weakFirst: IDETerminalHostView?
        autoreleasepool {
            // Creation and release settle in one pool drain: AppKit autoreleases view
            // internals, and the test's own pool only drains at the end. The production
            // runloop drains constantly, so this mirrors production, not test magic.
            let first = makeHost()
            weakFirst = first
            registry.register(first)
            XCTAssertEqual(registry.count, 1)
        }
        XCTAssertNil(weakFirst)
        registry.register(second)
        XCTAssertEqual(registry.count, 1, "the dead entry compacts instead of growing")
        XCTAssertFalse(registry.isEmpty)
        XCTAssertNil(registry.activeHost(), "no tab is shown, so no host is active")

        registry.terminateAll()
        XCTAssertTrue(registry.isEmpty)
        XCTAssertEqual(registry.count, 0)
        XCTAssertFalse(second.isShownActive)
    }

    func testTerminateAllEndsShells() {
        let registry = IDETerminalHostRegistry()
        var host: IDETerminalHostView? = makeHost()
        registry.register(host!)
        host = nil
        // Only a dead weak entry remains: terminating must not crash and must empty the list.
        registry.terminateAll()
        XCTAssertTrue(registry.isEmpty)
    }
}
