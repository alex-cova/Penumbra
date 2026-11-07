import XCTest
@testable import Umbra

/// Settings takes the keyboard when it opens, and its sidebar moves like the other lists.
@MainActor
final class IDEPreferencesKeyboardTests: XCTestCase {
    private var workspace: IDEWorkspace!

    override func setUp() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        workspace = IDEWorkspace()
        workspace.bootstrap()
    }

    override func tearDown() async throws {
        workspace?.windowWillClose()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
    }

    func testArrowKeysStayOnTheEndsOfTheSettingsSidebar() {
        let pages = IDEPreferencesDomain.ordered(with: [])
        XCTAssertEqual(IDEPreferencesDomain.moving(from: .general, in: pages, by: -1), .general)
        XCTAssertEqual(IDEPreferencesDomain.moving(from: .general, in: pages, by: 1), .editor)
        XCTAssertEqual(IDEPreferencesDomain.moving(from: .agent, in: pages, by: 1), .agent)
        XCTAssertEqual(IDEPreferencesDomain.moving(from: .agent, in: pages, by: -1).id, "project")
    }

    func testAnUnknownPageStartsFromTheFirstVisibleRow() {
        let pages = [IDEPreferencesDomain.editor, IDEPreferencesDomain.saving]
        let moved = IDEPreferencesDomain.moving(from: .agent, in: pages, by: 1)
        XCTAssertEqual(moved, .saving)
    }

    func testOpeningSettingsTakesTheEditorOutOfTheKeyLoop() {
        let host = workspace.host(for: workspace.workbench.activePaneID)
        XCTAssertTrue(host.textView.participatesInKeyViewLoop)

        workspace.showSettings()

        XCTAssertTrue(workspace.isSettingsVisible)
        XCTAssertTrue(workspace.isEditorCoveredByOverlay)
        XCTAssertFalse(host.textView.participatesInKeyViewLoop)
    }

    func testClosingSettingsPutsTheEditorBackInTheKeyLoop() {
        let host = workspace.host(for: workspace.workbench.activePaneID)
        workspace.showSettings()
        workspace.hideSettings()

        XCTAssertFalse(workspace.isSettingsVisible)
        XCTAssertTrue(host.textView.participatesInKeyViewLoop)
    }

    func testTheAgentPageTakesTheEditorOutOfTheKeyLoopAndClosingItBringsItBack() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-key-loop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        workspace.project.setRoot(directory)
        let settings = workspace.agent.settings
        let original = settings.opensAsPage
        defer { settings.opensAsPage = original }
        settings.opensAsPage = true
        let host = workspace.host(for: workspace.workbench.activePaneID)

        workspace.agent.showPanel()
        XCTAssertTrue(workspace.isEditorCoveredByOverlay)
        XCTAssertFalse(host.textView.participatesInKeyViewLoop, "no wait for SwiftUI's next update")

        workspace.hideAgentPage()
        XCTAssertFalse(workspace.isEditorCoveredByOverlay)
        XCTAssertTrue(host.textView.participatesInKeyViewLoop, "re-enabled before the editor is focused")
    }

    func testADockedAgentPanelLeavesTheEditorInTheKeyLoop() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-docked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        workspace.project.setRoot(directory)
        let settings = workspace.agent.settings
        let original = settings.opensAsPage
        defer { settings.opensAsPage = original }
        settings.opensAsPage = false
        let host = workspace.host(for: workspace.workbench.activePaneID)

        workspace.agent.showPanel()

        XCTAssertFalse(workspace.isEditorCoveredByOverlay)
        XCTAssertTrue(host.textView.participatesInKeyViewLoop)
    }

    func testExplorerFilterEscapeClearsBeforeItDismisses() {
        XCTAssertTrue(IDEExplorerFilterEscape.shouldClearQuery("Main"))
        XCTAssertTrue(IDEExplorerFilterEscape.shouldClearQuery("  foo  "))
        XCTAssertFalse(IDEExplorerFilterEscape.shouldClearQuery(""))
        XCTAssertFalse(IDEExplorerFilterEscape.shouldClearQuery("   "))
    }
}
