import XCTest
@testable import Umbra

/// The agent showing a file, the Gradle panels, and a command tab. No shell is started.
@MainActor
final class IDEAgentSurfaceTests: XCTestCase {
    private var project: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        project = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-surface-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.project.setRoot(project)
        workspace.bootstrap()
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        if let project { try? FileManager.default.removeItem(at: project) }
    }

    func testShowFileFocusesAnOpenBufferWithoutReplacingItsText() async throws {
        let file = project.appendingPathComponent("src/A.java")
        let source = "class A {\n    int x;\n}\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: file)
        let host = workspace.host(for: workspace.workbench.activePaneID)
        let dirty = source + "// unsaved\n"
        host.textView.text = dirty

        try await workspace.agentShowFile(relativePath: "src/A.java", line: 2, column: 5)

        XCTAssertEqual(workspace.workbench.allDocuments().count, 1)
        XCTAssertEqual(host.textView.text, dirty)
        XCTAssertEqual(host.textView.selectedRange, IDEWorkspace.utf16Range(ofLine: 2, column: 5, in: dirty))
    }

    func testRevealGradleShowsTheSidebarAndTheConsole() {
        workspace.isGradleSidebarVisible = false
        workspace.isTerminalVisible = false
        workspace.selectedBottomTab = .problems

        workspace.agentRevealGradle()

        XCTAssertTrue(workspace.isGradleSidebarVisible)
        XCTAssertTrue(workspace.isBottomTabSelected(.gradle))
        XCTAssertTrue(workspace.isTerminalVisible)
    }

    func testACommandOpensItsOwnTerminalTabAndADenialNeverCreatesOne() throws {
        workspace.addTerminalTab(saveSession: false)
        let shell = try XCTUnwrap(workspace.selectedTerminalTabID)
        let command = UUID()

        workspace.agentShowCommand(id: command, title: "echo hello from the agent tool", line: "$ echo hello from the agent tool\n")
        workspace.agentShowCommand(id: command, title: "echo hello from the agent tool", line: "hello\n")

        XCTAssertEqual(workspace.terminalTabs.count, 2)
        let tab = try XCTUnwrap(workspace.terminalTabs.last)
        XCTAssertNotEqual(tab.id, shell)
        XCTAssertEqual(tab.agentCommandID, command)
        XCTAssertEqual(tab.title, "echo hello from the agent tool")
        XCTAssertEqual(workspace.selectedTerminalTabID, tab.id)
        XCTAssertTrue(workspace.isTerminalVisible)
        XCTAssertTrue(workspace.isTerminalTabSelected)
        XCTAssertEqual(workspace.takeAgentCommandFeed(tabID: tab.id), "$ echo hello from the agent tool\nhello\n")

        workspace.agentShowCommand(id: command, title: "echo hello from the agent tool", line: nil)
        workspace.agentShowCommand(id: command, title: "echo hello from the agent tool", line: "late\n")
        XCTAssertEqual(workspace.takeAgentCommandFeed(tabID: tab.id), "", "a finished command accepts nothing more")
        XCTAssertEqual(workspace.terminalTabs.count, 2)

        let session = workspace.makeSession()
        XCTAssertEqual(session.terminalTabs?.map(\.id), [shell])
        XCTAssertEqual(session.selectedTerminalTabID, shell)

        workspace.restartTerminalTab(tab.id)
        XCTAssertEqual(workspace.terminalTabs.first { $0.id == tab.id }?.restartRequestID, 0)
    }
}
