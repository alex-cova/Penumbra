import AppKit
import SwiftUI
import XCTest
@testable import Umbra

/// Puts the real root view in a real (offscreen) window, closes it, and checks the workspace is
/// freed. The only check that exercises SwiftUI's own retention rather than one known cause.
///
/// Needs a window server, so it runs only with `UMBRA_UI_TESTS=1`:
/// `UMBRA_UI_TESTS=1 swift test --filter IDEHostedWindowRetentionTests`
/// A failure here is a prompt to look, not proof: run it again and look at what holds the object.
@MainActor
final class IDEHostedWindowRetentionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    func testAClosedHostedWindowFreesItsWorkspace() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["UMBRA_UI_TESTS"] == "1",
            "set UMBRA_UI_TESTS=1 to run tests that need a window server"
        )
        let registry = IDEWindowRegistry.shared
        // Another window is open, so the workspace under test starts empty instead of restoring.
        let keeper = IDEWorkspace()
        registry.register(keeper)
        defer { registry.unregister(keeper) }

        weak var weakWorkspace: IDEWorkspace?
        weak var weakWindow: NSWindow?
        let closeGuard = IDEWindowCloseGuard()
        do {
            let workspace = IDEWorkspace()
            workspace.bootstrap()
            registry.register(workspace)
            weakWorkspace = workspace

            let window = NSWindow(
                contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 600),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: IDERootView().environment(workspace))
            closeGuard.workspace = workspace
            closeGuard.install(on: window)
            weakWindow = window
            window.orderFront(nil)

            // Let SwiftUI lay the view out and start its tasks, as it does in the app.
            try await Task.sleep(nanoseconds: 500_000_000)

            workspace.windowWillClose()
            window.delegate = nil
            window.contentView = nil
            window.close()
        }

        for _ in 0..<50 where weakWorkspace != nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(weakWorkspace, "the closed window's workspace is still alive")
        withExtendedLifetime(closeGuard) {}
    }
}
