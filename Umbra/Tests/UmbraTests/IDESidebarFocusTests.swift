import Foundation
import XCTest
@testable import Umbra

/// Tool-window shortcuts focus the pane they show and restore the editor when they hide it.
/// Mouse clicks on the tab bar (`showSidebarTab`) leave the keyboard where it is.
@MainActor
final class IDESidebarFocusTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace!

    override func setUp() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-focus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.bootstrap()
        workspace.project.setRoot(directory)
        workspace.isSidebarVisible = true
    }

    override func tearDown() async throws {
        workspace?.windowWillClose()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: directory)
    }

    func testShowingASidebarTabRequestsFocusOnThatTab() {
        XCTAssertTrue(workspace.showsSidebar)
        workspace.toggleSidebarTab(.structure)

        XCTAssertTrue(workspace.isSidebarVisible)
        XCTAssertEqual(workspace.selectedSidebarTab, .structure)
        XCTAssertEqual(workspace.pendingSidebarFocusTab, .structure)
        XCTAssertEqual(workspace.sidebarFocusRequestID, 1)
    }

    func testShowingBookmarksOrHistoryRequestsFocusOnThatTab() {
        for tab in [IDESidebarTab.bookmarks, .history] {
            workspace.showSidebarTab(.explorer)
            workspace.pendingSidebarFocusTab = nil
            workspace.toggleSidebarTab(tab)
            XCTAssertEqual(workspace.pendingSidebarFocusTab, tab, tab.rawValue)
            XCTAssertTrue(workspace.consumeSidebarFocusIfNeeded(for: tab), tab.rawValue)
        }
    }

    func testHidingASidebarTabClearsTheFocusRequest() {
        workspace.toggleSidebarTab(.structure)
        XCTAssertEqual(workspace.sidebarFocusRequestID, 1)
        XCTAssertEqual(workspace.pendingSidebarFocusTab, .structure)

        workspace.toggleSidebarTab(.structure)

        XCTAssertFalse(workspace.isSidebarVisible)
        XCTAssertNil(workspace.pendingSidebarFocusTab)
        XCTAssertEqual(workspace.sidebarFocusRequestID, 1, "hiding does not bump the request")
    }

    func testSwitchingTabsRequestsFocusOnTheNewTab() {
        workspace.toggleSidebarTab(.structure)
        XCTAssertEqual(workspace.pendingSidebarFocusTab, .structure)

        workspace.toggleSidebarTab(.explorer)

        XCTAssertTrue(workspace.isSidebarVisible)
        XCTAssertEqual(workspace.selectedSidebarTab, .explorer)
        XCTAssertEqual(workspace.pendingSidebarFocusTab, .explorer)
        XCTAssertEqual(workspace.sidebarFocusRequestID, 2)
    }

    func testClickingATabDoesNotRequestFocus() {
        workspace.showSidebarTab(.structure)

        XCTAssertEqual(workspace.selectedSidebarTab, .structure)
        XCTAssertTrue(workspace.isSidebarVisible)
        XCTAssertNil(workspace.pendingSidebarFocusTab)
        XCTAssertEqual(workspace.sidebarFocusRequestID, 0)
    }

    func testToggleSidebarShowRequestsFocus() {
        workspace.isSidebarVisible = false
        workspace.toggleSidebar()

        XCTAssertTrue(workspace.isSidebarVisible)
        XCTAssertEqual(workspace.pendingSidebarFocusTab, .explorer)
        XCTAssertEqual(workspace.sidebarFocusRequestID, 1)
    }

    func testToggleSidebarHideClearsTheFocusRequest() {
        workspace.toggleSidebar()

        XCTAssertFalse(workspace.isSidebarVisible)
        XCTAssertNil(workspace.pendingSidebarFocusTab)
        XCTAssertEqual(workspace.sidebarFocusRequestID, 0)
    }

    func testConsumingFocusClearsThePendingTab() {
        workspace.toggleSidebarTab(.structure)
        XCTAssertTrue(workspace.consumeSidebarFocusIfNeeded(for: .structure))
        XCTAssertNil(workspace.pendingSidebarFocusTab)
        XCTAssertFalse(workspace.consumeSidebarFocusIfNeeded(for: .structure))
        XCTAssertFalse(workspace.consumeSidebarFocusIfNeeded(for: .explorer))
    }

    func testAConsumedRequestIsNotTakenByAnotherTab() {
        workspace.toggleSidebarTab(.structure)
        XCTAssertFalse(workspace.consumeSidebarFocusIfNeeded(for: .explorer))
        XCTAssertEqual(workspace.pendingSidebarFocusTab, .structure)
        XCTAssertTrue(workspace.consumeSidebarFocusIfNeeded(for: .structure))
    }

    func testGoToToolWindowFocusesTheChosenSidebarTab() {
        let structure = workspace.toolWindowEntries().first { $0.id == "structure" }
        XCTAssertNotNil(structure)
        structure?.action()

        XCTAssertEqual(workspace.selectedSidebarTab, .structure)
        XCTAssertEqual(workspace.pendingSidebarFocusTab, .structure)
        XCTAssertEqual(workspace.sidebarFocusRequestID, 1)
    }

    func testToggleProjectSidebarShowRequestsFocus() {
        workspace.isProjectSidebarVisible = false
        workspace.toggleProjectSidebar()

        XCTAssertTrue(workspace.isProjectSidebarVisible)
        XCTAssertTrue(workspace.wantsProjectSidebarFocus)
        XCTAssertEqual(workspace.projectSidebarFocusRequestID, 1)
    }

    func testToggleProjectSidebarHideClearsTheFocusRequest() {
        workspace.isProjectSidebarVisible = true
        workspace.toggleProjectSidebar()

        XCTAssertFalse(workspace.isProjectSidebarVisible)
        XCTAssertFalse(workspace.wantsProjectSidebarFocus)
        XCTAssertEqual(workspace.projectSidebarFocusRequestID, 0)
    }
}
