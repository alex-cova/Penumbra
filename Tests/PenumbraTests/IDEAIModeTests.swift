import Foundation
import XCTest
@testable import Umbra

/// AI mode is a window mode: it covers the editor, is saved with the window, and leaves the
/// editor's own state alone.
@MainActor
final class IDEAIModeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    /// Going back to the editor focuses a text view, which needs the adapter `bootstrap()` wires (the window runs it when it appears).
    private func makeWorkspace() -> IDEWorkspace {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        return workspace
    }

    func testAWindowStartsInTheEditorAndTheModeToggles() {
        let workspace = makeWorkspace()
        XCTAssertEqual(workspace.windowMode, .editor)
        XCTAssertFalse(workspace.isAIMode)

        workspace.toggleAIMode()
        XCTAssertTrue(workspace.isAIMode)
        workspace.toggleAIMode()
        XCTAssertEqual(workspace.windowMode, .editor)
    }

    func testShowingAIModeOpensTheRequestedTabAndKeepsItWhenGoingBackAndForth() {
        let workspace = makeWorkspace()
        workspace.showAIMode(tab: .chat)
        XCTAssertEqual(workspace.aiTab, .chat)
        workspace.showEditorMode()
        workspace.showAIMode()
        XCTAssertEqual(workspace.aiTab, .chat, "no tab asked for: it comes back where it was")

        // Asking for a tab while already in AI mode switches it.
        workspace.showAIMode(tab: .code)
        XCTAssertEqual(workspace.aiTab, .code)
        XCTAssertTrue(workspace.isAIMode)
    }

    func testAIModeClosesSettingsWhichBelongToTheEditor() {
        let workspace = makeWorkspace()
        workspace.showSettings()
        XCTAssertTrue(workspace.isSettingsVisible)
        workspace.showAIMode()
        XCTAssertFalse(workspace.isSettingsVisible)
    }

    func testLeavingAIModeForTheEditorNeedsNoFocusAndOnlyActsInAIMode() {
        let workspace = makeWorkspace()
        workspace.leaveAIModeForEditor()
        XCTAssertEqual(workspace.windowMode, .editor)
        workspace.showAIMode()
        workspace.leaveAIModeForEditor()
        XCTAssertEqual(workspace.windowMode, .editor)
    }

    func testTheModeAndTabAreSavedWithTheWindow() throws {
        let workspace = makeWorkspace()
        workspace.showAIMode(tab: .chat)
        let session = workspace.makeSession()
        XCTAssertEqual(session.windowMode, .ai)
        XCTAssertEqual(session.aiTab, .chat)

        let decoded = try JSONDecoder().decode(IDEWindowSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.windowMode, .ai)
        XCTAssertEqual(decoded.aiTab, .chat)
    }

    func testASessionFromBeforeAIModeOpensInTheEditorAndASurvivingModeIsNotForgottenWithTheFolder() throws {
        let old = try JSONDecoder().decode(IDEWindowSession.self, from: Data(#"{"sidebarWidth":250}"#.utf8))
        XCTAssertNil(old.windowMode)
        XCTAssertNil(old.aiTab)

        // A value this build does not know decodes as none, not as a failure that loses the window.
        let future = try JSONDecoder().decode(
            IDEWindowSession.self, from: Data(#"{"sidebarWidth":250,"windowMode":"hologram","aiTab":"voice"}"#.utf8))
        XCTAssertNil(future.windowMode)
        XCTAssertEqual(future.sidebarWidth, 250)

        let closed = IDEWindowSession(windowMode: .ai, aiTab: .chat).closingFolder(homeDirectory: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(closed.windowMode, .ai, "Chat needs no folder, so closing one does not leave AI mode")
        XCTAssertEqual(closed.aiTab, .chat)
    }

    func testTheModePaletteCommandsAreRegisteredAndWork() {
        let workspace = makeWorkspace()
        let registry = workspace.paletteController!.commandRegistry
        XCTAssertEqual(registry.command(id: "app.toggleAIMode")?.title, "Toggle AI Mode")

        registry.command(id: "app.aiChat")?.action()
        XCTAssertEqual(workspace.windowMode, .ai)
        XCTAssertEqual(workspace.aiTab, .chat)
        registry.command(id: "app.aiCode")?.action()
        XCTAssertEqual(workspace.aiTab, .code)
        registry.command(id: "app.toggleAIMode")?.action()
        XCTAssertEqual(workspace.windowMode, .editor)
    }

    func testAFolderOpenedForAIModeLandsInAIModeOnTheCodeTab() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ai-open-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let workspace = makeWorkspace()
        workspace.aiTab = .chat
        workspace.pendingAIOpen = IDEAIOpenRequest()
        workspace.openProjectFolder(folder)
        XCTAssertEqual(workspace.windowMode, .ai)
        XCTAssertEqual(workspace.aiTab, .code)
        XCTAssertNil(workspace.pendingAIOpen, "the request is used once")
        XCTAssertEqual(workspace.project.rootURL?.standardizedFileURL, folder.standardizedFileURL)
        workspace.teardown()
    }

    func testAFolderOpenedTheOrdinaryWayStaysInTheEditor() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plain-open-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let workspace = makeWorkspace()
        workspace.openProjectFolder(folder)
        XCTAssertEqual(workspace.windowMode, .editor)
        workspace.teardown()
    }

    func testAProjectThatIsAlreadyOpenIsShownInAIModeWithoutGoingThroughTheRegistry() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("same-open-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let workspace = makeWorkspace()
        workspace.openProjectFolder(folder)
        workspace.openProjectInAIMode(folder)
        XCTAssertEqual(workspace.windowMode, .ai)
        XCTAssertEqual(workspace.aiTab, .code)
        workspace.teardown()
    }

    func testOpeningAFileFromTheAgentLeavesAIMode() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("show-open-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "hello".write(to: folder.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: folder) }

        let workspace = makeWorkspace()
        workspace.openProjectFolder(folder)
        workspace.showAIMode()
        await workspace.openAgentCitedFile(IDEAgentFileLinks.Reference(path: "A.txt", line: nil, column: nil))
        XCTAssertEqual(workspace.windowMode, .editor, "a file is shown in the editor")
        workspace.teardown()
    }
}

