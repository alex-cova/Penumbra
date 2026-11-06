import EditorIntelligence
import Foundation
import Penumbra
import XCTest
@testable import Umbra

/// Closing the last window forgets the open folder, and Close Folder asks before dropping unsaved
/// edits and points terminals at the home directory.
@MainActor
final class IDECloseFolderTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace!

    override func setUp() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("closefolder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.bootstrap()
        workspace.project.setRoot(directory)
        workspace.addTerminalTab(cwd: directory, saveSession: false)
        workspace.addTerminalTab(cwd: directory.appendingPathComponent("nested"), saveSession: false)
    }

    override func tearDown() async throws {
        workspace?.windowWillClose()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: directory)
    }

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }


    // MARK: - Session written when the window closes

    func testClosingTheFolderDropsTheProjectAndRetargetsTerminals() {
        let paneID = UUID()
        let tabID = UUID()
        let chat = UUID()
        let session = IDEWindowSession(
            restoration: EditorRestorationState(
                activePaneID: paneID,
                layout: .pane(EditorPaneSnapshot(id: paneID, documents: []))
            ),
            projectRootBookmark: Data([1, 2, 3]),
            sidebarWidth: 280,
            isSidebarVisible: true,
            isTerminalVisible: true,
            terminalHeight: 220,
            terminalTabs: [IDETerminalTab(id: tabID, title: "project", workingDirectory: directory)],
            selectedTerminalTabID: tabID,
            isAgentPanelVisible: true,
            agentChats: [chat],
            agentSelectedChat: chat
        )

        let closed = session.closingFolder(homeDirectory: home)

        XCTAssertNil(closed.restoration)
        XCTAssertNil(closed.projectRootBookmark)
        XCTAssertFalse(closed.isSidebarVisible)
        XCTAssertEqual(closed.sidebarWidth, 280)
        XCTAssertTrue(closed.isTerminalVisible)
        XCTAssertEqual(closed.terminalHeight, 220)
        XCTAssertEqual(closed.selectedTerminalTabID, tabID)
        XCTAssertEqual(closed.terminalTabs?.map(\.id), [tabID])
        XCTAssertEqual(
            closed.terminalTabs?.map { $0.workingDirectory.standardizedFileURL.path },
            [home.standardizedFileURL.path]
        )
        XCTAssertEqual(closed.terminalTabs?.map(\.title), [IDETerminalTab.defaultTitle(for: home)])
        XCTAssertEqual(closed.isAgentPanelVisible, false)
        XCTAssertNil(closed.agentChats)
        XCTAssertNil(closed.agentSelectedChat)
    }

    func testAClosedFolderSessionRoundTripsWithoutTheProject() throws {
        let tabID = UUID()
        let session = IDEWindowSession(
            projectRootBookmark: Data([4, 5]),
            isTerminalVisible: true,
            terminalTabs: [IDETerminalTab(id: tabID, title: "project", workingDirectory: directory)],
            selectedTerminalTabID: tabID
        )
        let data = try JSONEncoder().encode(session.closingFolder(homeDirectory: home))
        let loaded = try JSONDecoder().decode(IDEWindowSession.self, from: data)

        XCTAssertNil(loaded.projectRootBookmark)
        XCTAssertNil(loaded.restoration)
        XCTAssertEqual(loaded.terminalTabs?.first?.workingDirectory.standardizedFileURL.path, home.standardizedFileURL.path)
        XCTAssertEqual(loaded.selectedTerminalTabID, tabID)
        XCTAssertTrue(loaded.isTerminalVisible)
    }

    // MARK: - Close Folder

    func testCloseFolderWithNothingUnsavedResetsTerminalsAndDoesNotAsk() {
        var asked = 0
        workspace.folderCloseResolver = { _ in
            asked += 1
            return .cancel
        }

        workspace.closeFolder()

        XCTAssertEqual(asked, 0)
        XCTAssertNil(workspace.project.rootURL)
        XCTAssertTrue(workspace.showsWelcome)
        XCTAssertFalse(workspace.isSidebarVisible)
        assertTerminalsAreHome()
    }

    /// Problems and Debug belong to the project: after Close Folder, even with an Untitled file
    /// open (⌘N), neither the tab strip nor the stripe offers them and the panel is back on the shell.
    func testCloseFolderHidesProblemsAndDebugEvenWithAnUntitledFileOpen() {
        XCTAssertTrue(workspace.showsProblemsTab)
        workspace.dapDebugSession.beginLaunch(of: "app")
        workspace.showBottomTab(.debug)
        XCTAssertTrue(workspace.showsDebugTab)

        workspace.closeFolder()
        workspace.newFile()

        XCTAssertTrue(workspace.hasOpenDocuments)
        XCTAssertFalse(workspace.showsProblemsTab)
        XCTAssertFalse(workspace.showsDebugTab)
        XCTAssertEqual(workspace.selectedBottomTab, .terminal)
        let windows = workspace.toolWindows.map(\.id)
        XCTAssertFalse(windows.contains("problems"))
        XCTAssertFalse(windows.contains("debug"))

        workspace.showBottomTab(.problems)
        XCTAssertEqual(workspace.selectedBottomTab, .terminal)
    }

    /// What the project ran or produced belongs to it: a running program is stopped and its Run tab
    /// goes, and coverage, pinned hierarchies and the SwiftUI canvas are dropped.
    func testCloseFolderStopsRunsAndClearsProjectResults() {
        let session = IDERunSession(configurationID: UUID(), title: "Main", providerID: "java")
        workspace.runs.add(session)
        workspace.showBottomTab(.run)
        workspace.coverage.beginReport(message: "Building the coverage report…")
        workspace.typeHierarchy.show(
            root: HierarchyItem(id: "Base", name: "Base", kind: .classType, origin: .project), file: nil
        )
        workspace.pinTypeHierarchy()
        workspace.isSwiftUIPreviewVisible = true
        XCTAssertTrue(workspace.showsRunTab)
        XCTAssertTrue(workspace.showsCoverageTab)
        XCTAssertTrue(workspace.showsTypeHierarchyTab)
        XCTAssertTrue(session.isActive)

        workspace.closeFolder()
        workspace.newFile()

        XCTAssertFalse(session.isActive, "a program the closed project started must not keep running")
        XCTAssertFalse(workspace.showsRunTab)
        XCTAssertFalse(workspace.showsCoverageTab)
        XCTAssertFalse(workspace.showsTypeHierarchyTab)
        XCTAssertTrue(workspace.typePins.isEmpty)
        XCTAssertFalse(workspace.isSwiftUIPreviewVisible)
        XCTAssertEqual(workspace.selectedBottomTab, .terminal)
    }

    /// Stopping a debugger that never ran must not make the Debug tab appear.
    func testStoppingAnIdleDebuggerKeepsTheDebugTabHidden() {
        workspace.stopDebugging()

        XCTAssertFalse(workspace.showsDebugTab)
    }

    /// F-20: closing the window stops an active DAP session too, not just the Java one —
    /// otherwise the adapter process and its event pumps outlive the window. (Closing the
    /// folder already retires it through `dismissProjectBottomTabs`; only teardown missed it.)
    func testTeardownStopsAnActiveDAPSession() {
        workspace.dapDebugSession.state = .running
        XCTAssertTrue(workspace.dapDebugSession.isActive)

        workspace.teardown()

        XCTAssertEqual(workspace.dapDebugSession.state, .terminated)
    }

    func testCloseFolderWithUnsavedChangesCancelKeepsTheFolderAndTheTerminal() async {
        workspace.newFile()
        workspace.workbench.activePane.selectedDocument?.isDirty = true
        var asked = 0
        workspace.folderCloseResolver = { text in
            asked += 1
            XCTAssertTrue(text.contains("unsaved"))
            return .cancel
        }

        workspace.closeFolder()

        await waitForCondition("the prompt never ran", timeout: 3) { asked == 1 }
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(workspace.project.rootURL?.standardizedFileURL.path, directory.standardizedFileURL.path)
        XCTAssertEqual(
            workspace.terminalTabs.map { $0.workingDirectory.standardizedFileURL.path },
            [directory.standardizedFileURL.path, directory.appendingPathComponent("nested").standardizedFileURL.path]
        )
        XCTAssertTrue(workspace.terminalTabs.allSatisfy { $0.restartRequestID == 0 })
    }

    func testCloseFolderDontSaveDropsEditsAndResetsTerminals() async throws {
        let (url, document, host) = try await open("Keep.txt", "old\n")
        host.textView.text = "new\n"
        document.isDirty = true
        var asked = 0
        workspace.folderCloseResolver = { _ in
            asked += 1
            return .discard
        }

        workspace.closeFolder()

        await waitForCondition("the folder never closed", timeout: 3) { self.workspace.project.rootURL == nil }
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old\n")
        XCTAssertFalse(workspace.hasOpenDocuments)
        assertTerminalsAreHome()
    }

    func testCloseFolderSaveWritesTheFileThenCloses() async throws {
        let (url, document, host) = try await open("Save.txt", "old\n")
        host.textView.text = "saved\n"
        document.isDirty = true
        workspace.folderCloseResolver = { _ in .save }

        workspace.closeFolder()

        await waitForCondition("the folder never closed", timeout: 5) { self.workspace.project.rootURL == nil }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved\n")
        assertTerminalsAreHome()
    }

    private func open(_ name: String, _ text: String) async throws -> (URL, WorkbenchDocument, IDEEditorPaneHost) {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: url)
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        let host = workspace.host(for: workspace.workbench.activePaneID)
        await waitForCondition("the editor never showed \(name)", timeout: 3) { host.textView.text == text }
        return (url, document, host)
    }

    // MARK: - Which window forgets the folder

    func testOnlyTheLastWindowWithContentForgetsTheFolder() {
        // The registry is shared by the whole test process, and tests that never close their
        // workspace leave them registered while they live: one of those with content would be the
        // session window, or the window that takes over, instead of this test's own.
        let registry = IDEWindowRegistry.shared
        for other in registry.workspaces where other !== workspace {
            registry.unregister(other)
        }
        registry.didBecomeActive(workspace)

        XCTAssertTrue(IDEWindowRegistry.shared.forgetsFolderWhenClosing(workspace))

        let extra = IDEWorkspace()
        extra.bootstrap()
        defer { extra.windowWillClose() }
        // A blank window opened beside this one does not keep the folder in the saved session.
        XCTAssertTrue(extra.isPristine)
        XCTAssertTrue(IDEWindowRegistry.shared.forgetsFolderWhenClosing(workspace))
        XCTAssertFalse(IDEWindowRegistry.shared.forgetsFolderWhenClosing(extra))

        extra.newFile()
        XCTAssertFalse(extra.isPristine)
        XCTAssertFalse(IDEWindowRegistry.shared.forgetsFolderWhenClosing(workspace))
        XCTAssertFalse(IDEWindowRegistry.shared.forgetsFolderWhenClosing(extra))
    }

    // MARK: - Quitting keeps every window

    func testQuitStoresEveryUsedWindowWithItsFolderAndLeavesOutBlankOnes() throws {
        let extra = IDEWorkspace()
        extra.bootstrap()
        defer { extra.windowWillClose() }
        XCTAssertTrue(extra.isPristine)
        let second = IDEWorkspace()
        second.bootstrap()
        defer { second.windowWillClose() }
        second.newFile()
        XCTAssertFalse(second.isPristine)

        let sessions = IDEWindowRegistry.sessionsForTermination(of: [workspace, extra, second])

        XCTAssertEqual(sessions.map(\.windowID), [workspace.windowID, second.windowID],
                       "most recently key first, the blank window left out")
        XCTAssertNotNil(sessions.first?.projectRootBookmark, "quitting does not forget the folder")
        XCTAssertEqual(sessions.first?.terminalTabs?.count, 1, "the shell that was selected comes back")
    }

    func testEachWindowKeepsItsOwnIdInItsSession() {
        let session = workspace.makeSession()

        XCTAssertEqual(session.windowID, workspace.windowID)
    }

    private func assertTerminalsAreHome() {
        let expected = home.standardizedFileURL.path
        XCTAssertEqual(workspace.terminalTabs.count, 2)
        XCTAssertTrue(workspace.terminalTabs.allSatisfy {
            $0.workingDirectory.standardizedFileURL.path == expected && $0.restartRequestID == 1
        })
        XCTAssertEqual(workspace.terminalTabs.map(\.title), [IDETerminalTab.defaultTitle(for: home), IDETerminalTab.defaultTitle(for: home)])
    }
}
