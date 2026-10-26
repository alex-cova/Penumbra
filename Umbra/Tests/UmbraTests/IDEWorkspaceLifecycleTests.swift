import Foundation
import XCTest
@testable import Umbra

/// What happens when a window closes or the app quits (`IDEWorkspace.teardown`, `confirmQuit`).
@MainActor
final class IDEWorkspaceLifecycleTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Never restore or overwrite the developer's real session files from a test.
        IDEWorkspace.isSessionPersistenceEnabled = false
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    // MARK: - Quit prompt

    func testNothingToAskWhenEveryEditorIsSaved() {
        XCTAssertNil(IDEWindowRegistry.quitPromptText(unsavedPerWindow: []))
        XCTAssertNil(IDEWindowRegistry.quitPromptText(unsavedPerWindow: [0, 0]))
    }

    func testOneEditorInOneWindow() {
        XCTAssertEqual(
            IDEWindowRegistry.quitPromptText(unsavedPerWindow: [0, 1]),
            "1 open editor has unsaved changes that will be lost."
        )
    }

    func testSeveralEditorsInOneWindow() {
        XCTAssertEqual(
            IDEWindowRegistry.quitPromptText(unsavedPerWindow: [3]),
            "3 open editors have unsaved changes that will be lost."
        )
    }

    func testEditorsInSeveralWindowsAreAskedAboutOnce() {
        XCTAssertEqual(
            IDEWindowRegistry.quitPromptText(unsavedPerWindow: [2, 0, 1]),
            "3 open editors have unsaved changes in 2 windows that will be lost."
        )
    }

    // MARK: - Teardown

    func testTearDownTwiceIsHarmless() {
        let workspace = IDEWorkspace()
        workspace.teardown()
        workspace.teardown()
        XCTAssertTrue(workspace.isTornDown)
    }

    func testATornDownWorkspaceStopsBeingATarget() {
        let registry = IDEWindowRegistry.shared
        let keeper = IDEWorkspace()
        let closing = IDEWorkspace()
        registry.register(keeper)
        registry.register(closing)
        XCTAssertTrue(registry.workspaces.contains { $0 === closing })

        closing.windowWillClose()

        XCTAssertFalse(registry.workspaces.contains { $0 === closing })
        XCTAssertTrue(closing.isTornDown)
        registry.unregister(keeper)
    }

    /// A closed window's workspace must be freed. Anything that keeps it alive keeps the project's
    /// editors, indexes and watchers with it, for the rest of the run.
    func testAClosedWindowsWorkspaceIsFreed() async throws {
        let registry = IDEWindowRegistry.shared
        // Another window is open, so the workspace under test starts empty instead of restoring.
        let keeper = IDEWorkspace()
        registry.register(keeper)
        defer { registry.unregister(keeper) }

        weak var weakWorkspace: IDEWorkspace?
        do {
            let workspace = IDEWorkspace()
            workspace.bootstrap()
            weakWorkspace = workspace
            workspace.windowWillClose()
        }

        for _ in 0..<50 where weakWorkspace != nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(weakWorkspace, "the closed window's workspace is still alive")
    }
}
