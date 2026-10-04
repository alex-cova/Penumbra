import AgentKit
import EditorIntelligence
import Foundation
import XCTest
@testable import Umbra

/// Offsets from the agent become line/column edits; a closed file goes through `WorkspaceEdit.apply`,
/// so that is the reference for what the translation must produce.
final class IDEAgentEditTranslatorTests: XCTestCase {
    private func check(_ text: String, _ edits: [AgentTextEdit], file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try AgentTextEdit.apply(edits, to: text)
        let translated = try IDEAgentEditTranslator.textEdits(edits, in: text)
        XCTAssertEqual(try WorkspaceEdit.apply(translated, to: text), expected, file: file, line: line)
    }

    func testLFTextWithEditsOnSeveralLines() throws {
        let text = "alpha\nbeta\ngamma\n"
        try check(text, [
            AgentTextEdit(location: 0, length: 5, replacement: "A"),
            AgentTextEdit(location: 6, length: 4, replacement: "B\nB"),
            AgentTextEdit(location: 17, length: 0, replacement: "tail\n"),
        ])
    }

    func testCRLFLoneCRAndEmoji() throws {
        try check("one\r\ntwo\r\nthree", [AgentTextEdit(location: 5, length: 3, replacement: "2")])
        try check("one\rtwo\rthree", [AgentTextEdit(location: 4, length: 3, replacement: "2")])
        // The emoji is two UTF-16 units; columns count units, as the editor does.
        let text = "😀 x\n😀 target\n"
        let location = (text as NSString).range(of: "target").location
        try check(text, [AgentTextEdit(location: location, length: 6, replacement: "goal")])
    }

    func testWholeFileReplacementAndEmptyText() throws {
        let text = "a\nb\n"
        try check(text, [AgentTextEdit(location: 0, length: (text as NSString).length, replacement: "z\n")])
        try check("", [AgentTextEdit(location: 0, length: 0, replacement: "new")])
    }

    func testPositionsAreOneLineAndColumnPerOffset() throws {
        let edits = try IDEAgentEditTranslator.textEdits([AgentTextEdit(location: 7, length: 2, replacement: "x")], in: "ab\ncd\nefgh")
        XCTAssertEqual(edits[0].range.start, TextPosition(line: 2, column: 1, utf16Offset: 7))
        XCTAssertEqual(edits[0].range.end, TextPosition(line: 2, column: 3, utf16Offset: 9))
    }

    func testBadEditsAreRefusedBeforeAnythingIsApplied() {
        XCTAssertThrowsError(try IDEAgentEditTranslator.textEdits([AgentTextEdit(location: 3, length: 5, replacement: "")], in: "abc"))
        XCTAssertThrowsError(try IDEAgentEditTranslator.textEdits([
            AgentTextEdit(location: 0, length: 2, replacement: ""), AgentTextEdit(location: 1, length: 1, replacement: ""),
        ], in: "abc"))
    }
}

@MainActor
private final class CreatingHost: IDEWorkspaceEditHost {
    let editProjectRoot: URL?
    var created: [URL: String] = [:]

    init(root: URL) { editProjectRoot = root }

    func editTarget(for url: URL) async -> IDEWorkspaceEditTarget { .closed }
    func renameFile(from: URL, to: URL) throws {}
    func moveFile(from: URL, to: URL) throws {}
    func deleteFile(at: URL) throws {}
    func createFile(at url: URL, contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        created[url] = contents
    }
}

@MainActor
final class WorkspaceEditCreationTests: XCTestCase {
    private var project: URL!

    override func setUpWithError() throws {
        project = FileManager.default.temporaryDirectory
            .appendingPathComponent("create-project-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let project { try? FileManager.default.removeItem(at: project) }
    }

    func testAnEditCanCreateAFileInANewFolder() async {
        let host = CreatingHost(root: project)
        let url = project.appendingPathComponent("src/new/Hello.java")
        let result = await IDEWorkspaceEditApplier(host: host).apply(WorkspaceEdit(fileCreations: [(url, "class Hello {}\n")]))
        XCTAssertTrue(result.isSuccess, "\(result.failures)")
        XCTAssertEqual(result.createdFiles, [url])
        XCTAssertEqual(host.created[url], "class Hello {}\n")
    }

    func testAnExistingFileIsNeverOverwrittenByACreation() async throws {
        let host = CreatingHost(root: project)
        let url = project.appendingPathComponent("A.txt")
        try "keep".write(to: url, atomically: true, encoding: .utf8)
        let result = await IDEWorkspaceEditApplier(host: host).apply(WorkspaceEdit(fileCreations: [(url, "clobber")]))
        XCTAssertNotNil(result.failures[url])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "keep")
    }

    func testCreationsOutsideTheProjectAreRefusedEvenThroughASymlink() async throws {
        let host = CreatingHost(root: project)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("link"), withDestinationURL: outside)

        for url in [outside.appendingPathComponent("x.txt"), project.appendingPathComponent("link/x.txt"), project.appendingPathComponent("link/deep/x.txt")] {
            let result = await IDEWorkspaceEditApplier(host: host).apply(WorkspaceEdit(fileCreations: [(url, "x")]))
            XCTAssertNotNil(result.failures[url], "\(url.path) should be refused")
        }
        XCTAssertTrue(host.created.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("x.txt").path))
    }

    func testCreatingTheSameFileTwiceIsInvalidAndChangesNothing() async {
        let host = CreatingHost(root: project)
        let url = project.appendingPathComponent("A.txt")
        let result = await IDEWorkspaceEditApplier(host: host).apply(WorkspaceEdit(fileCreations: [(url, "1"), (url, "2")]))
        XCTAssertNotNil(result.failures[url])
        XCTAssertTrue(host.created.isEmpty)
    }

    func testAHostWithoutCreationSupportSaysSo() async {
        let host = ClosedHost(root: project)
        let url = project.appendingPathComponent("A.txt")
        let result = await IDEWorkspaceEditApplier(host: host).apply(WorkspaceEdit(fileCreations: [(url, "x")]))
        XCTAssertNotNil(result.failures[url])
    }

    func testAnEditWithOnlyCreationsIsNotEmpty() {
        XCTAssertFalse(WorkspaceEdit(fileCreations: [(URL(fileURLWithPath: "/a"), "")]).isEmpty)
        XCTAssertTrue(WorkspaceEdit().isEmpty)
    }
}

@MainActor
private final class ClosedHost: IDEWorkspaceEditHost {
    let editProjectRoot: URL?
    init(root: URL) { editProjectRoot = root }
    func editTarget(for url: URL) async -> IDEWorkspaceEditTarget { .closed }
    func renameFile(from: URL, to: URL) throws {}
    func moveFile(from: URL, to: URL) throws {}
    func deleteFile(at: URL) throws {}
}

/// The whole path on a real workspace: the model's tool calls, the applier, the checkpoint log, and
/// Revert Run. No editor is open, so every file is changed on disk.
@MainActor
final class IDEAgentEditingTests: XCTestCase {
    private var project: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        project = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-project-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.project.setRoot(project)
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        if let project { try? FileManager.default.removeItem(at: project) }
    }

    private func write(_ path: String, _ text: String) throws {
        let url = project.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func disk(_ path: String) -> String? {
        try? String(contentsOf: project.appendingPathComponent(path), encoding: .utf8)
    }

    private func makeController(_ turns: [MockTurn]) -> IDEAgentController {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        let client = MockLLMClient(turns: turns)
        let controller = IDEAgentController(settings: settings, clientFactory: { _ in client })
        controller.attach(host: workspace)
        return controller
    }

    private func run(_ controller: IDEAgentController, _ message: String) async {
        controller.draft = message
        controller.send()
        for _ in 0..<500 where controller.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(controller.isRunning, "the run should have finished")
    }

    private func waitFor(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    private func changesEntry(_ controller: IDEAgentController) -> IDEAgentEntry? {
        controller.entries.last { $0.kind == .changes }
    }

    func testEditingCreatingAndRevertingAWholeRun() async throws {
        try write("src/A.java", "class A {\n  int x = 1;\n}\n")
        let controller = makeController([
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"src/A.java"}"#)),
            .toolCalls(
                (id: "e", name: "edit_file", arguments: #"{"path":"src/A.java","old_string":"int x = 1;","new_string":"int x = 2;"}"#),
                (id: "w", name: "write_file", arguments: #"{"path":"src/B.java","content":"class B {}\n"}"#)),
            .text("Done."),
        ])
        await run(controller, "change A and add B")

        XCTAssertEqual(disk("src/A.java"), "class A {\n  int x = 2;\n}\n")
        XCTAssertEqual(disk("src/B.java"), "class B {}\n")
        let entry = try XCTUnwrap(changesEntry(controller), "a run that changed files ends with a summary")
        XCTAssertEqual(entry.fileChanges.map(\.path), ["src/A.java", "src/B.java"])
        XCTAssertEqual(entry.fileChanges.map(\.isCreation), [false, true])
        XCTAssertEqual(entry.fileChanges[0].original, "class A {\n  int x = 1;\n}\n")

        controller.revert(entryID: entry.id)
        await waitFor("the revert finishes") { self.changesEntry(controller)?.isReverted == true }
        XCTAssertEqual(disk("src/A.java"), "class A {\n  int x = 1;\n}\n")
        XCTAssertNil(disk("src/B.java"), "a created file goes to the Trash")
        XCTAssertEqual(controller.entries.last?.text, "Reverted 2 files.")
    }

    func testAFileTheUserEditedAfterTheAgentIsLeftAloneAndListed() async throws {
        try write("src/A.java", "class A {}\n")
        try write("src/B.java", "class B {}\n")
        let controller = makeController([
            .toolCalls(
                (id: "r1", name: "read_file", arguments: #"{"path":"src/A.java"}"#),
                (id: "r2", name: "read_file", arguments: #"{"path":"src/B.java"}"#)),
            .toolCalls(
                (id: "e1", name: "edit_file", arguments: #"{"path":"src/A.java","old_string":"class A","new_string":"class A2"}"#),
                (id: "e2", name: "edit_file", arguments: #"{"path":"src/B.java","old_string":"class B","new_string":"class B2"}"#)),
            .text("Done."),
        ])
        await run(controller, "rename both")
        try write("src/A.java", "class A2 { /* the user kept working */ }\n")

        let entry = try XCTUnwrap(changesEntry(controller))
        controller.revert(entryID: entry.id)
        await waitFor("the revert finishes") { !(self.changesEntry(controller)?.conflicts.isEmpty ?? true) }

        XCTAssertEqual(disk("src/A.java"), "class A2 { /* the user kept working */ }\n", "the user's text is never overwritten")
        XCTAssertEqual(disk("src/B.java"), "class B {}\n")
        let updated = try XCTUnwrap(changesEntry(controller))
        XCTAssertEqual(updated.conflicts.map(\.path), ["src/A.java"])
        XCTAssertEqual(updated.conflicts.first?.original, "class A {}\n", "Show Diff compares with the original")
        XCTAssertFalse(updated.isReverted)
    }

    func testTheModelCannotWriteOutsideTheProjectOrIntoGit() async throws {
        try write(".git/config", "[core]\n")
        let controller = makeController([
            .toolCalls(
                (id: "a", name: "write_file", arguments: #"{"path":"../escape.txt","content":"x"}"#),
                (id: "b", name: "write_file", arguments: #"{"path":".git/hooks/pre-commit","content":"x"}"#),
                (id: "c", name: "write_file", arguments: #"{"path":"/tmp/agent-escape.txt","content":"x"}"#)),
            .text("could not"),
        ])
        await run(controller, "try to escape")
        XCTAssertNil(changesEntry(controller), "nothing changed, so there is no summary")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.deletingLastPathComponent().appendingPathComponent("escape.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/agent-escape.txt"))
        XCTAssertNil(disk(".git/hooks/pre-commit"))
        let outputs = controller.entries.compactMap { $0.output }
        XCTAssertEqual(outputs.count, 3)
        XCTAssertTrue(outputs.allSatisfy(\.isError))
    }

    func testARunThatOnlyReadsHasNoSummary() async throws {
        try write("src/A.java", "class A {}\n")
        let controller = makeController([
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"src/A.java"}"#)), .text("It is a class."),
        ])
        await run(controller, "what is A?")
        XCTAssertNil(changesEntry(controller))
    }

    func testRevertingIsRefusedWhileARunIsInProgress() async throws {
        try write("src/A.java", "class A {}\n")
        let controller = makeController([
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"src/A.java"}"#)),
            .toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"src/A.java","old_string":"A","new_string":"B"}"#)),
            MockTurn((0..<100).map { LLMEvent.textDelta("w\($0) ") } + [.finished(.completed)], delayPerEvent: .milliseconds(20)),
        ])
        controller.draft = "go"
        controller.send()
        await waitFor("the edit lands") { self.disk("src/A.java") == "class B {}\n" }
        // The summary only appears at the end of the run, so there is nothing to revert yet; stop it.
        XCTAssertNil(changesEntry(controller))
        controller.stop()
        await waitFor("the run stops") { !controller.isRunning }
        let entry = try XCTUnwrap(changesEntry(controller), "a stopped run that changed files still gets its summary")
        controller.revert(entryID: entry.id)
        await waitFor("the revert finishes") { self.changesEntry(controller)?.isReverted == true }
        XCTAssertEqual(disk("src/A.java"), "class A {}\n")
    }

    // MARK: - The real workspace's command and build hooks

    func testGradleOnAProjectThatIsNotGradleEndsWithANotStartedOutcomeInsteadOfHanging() async throws {
        let outcome = await workspace.agentRunGradle(tasks: ["test"], options: [], timeout: 30)
        guard case .notStarted(let reason) = outcome else { return XCTFail("expected notStarted, got \(outcome)") }
        XCTAssertTrue(reason.contains("not a Gradle project"), reason)
        XCTAssertFalse(workspace.agent.isGradleRunActive, "the flag is cleared on every exit")
    }

    func testFreshProblemsSaysWhyWhenNoCompilerIsConfigured() async throws {
        let result = await workspace.agentFreshProblems(relativePaths: ["src/A.java", "notes.md"])
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertNotNil(result.unavailable, "no compiler is not the same as no problems")
        let none = await workspace.agentFreshProblems(relativePaths: ["notes.md"])
        XCTAssertNil(none.unavailable, "nothing Java was asked about, so nothing to apologise for")
    }

    func testTheCommandEnvironmentIsBuiltAndCarriesTheUsersExtras() async throws {
        IDEAgentSettings.shared.commandEnvironmentText = "AGENT_TEST_EXTRA=1"
        defer { IDEAgentSettings.shared.commandEnvironmentText = "" }
        let environment = await workspace.agentCommandEnvironment()
        XCTAssertEqual(environment["AGENT_TEST_EXTRA"], "1")
        XCTAssertEqual(environment["TERM"], "dumb")
        XCTAssertTrue(environment["PATH"]?.contains("/usr/bin") == true)
    }

    func testSavingABufferThatIsNotOpenIsHarmless() async throws {
        try write("src/A.java", "class A {}\n")
        await workspace.agentSaveBuffers(relativePaths: ["src/A.java", "does/not/exist.java"])
        XCTAssertEqual(disk("src/A.java"), "class A {}\n")
    }

    func testTheAgentSeesTheTextItWroteWithoutReReading() async throws {
        try write("src/A.java", "a b\n")
        let controller = makeController([
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"src/A.java"}"#)),
            .toolCalls((id: "e1", name: "edit_file", arguments: #"{"path":"src/A.java","old_string":"a","new_string":"x"}"#)),
            .toolCalls((id: "e2", name: "edit_file", arguments: #"{"path":"src/A.java","old_string":"b","new_string":"y"}"#)),
            .text("ok"),
        ])
        await run(controller, "two edits")
        XCTAssertEqual(disk("src/A.java"), "x y\n")
        XCTAssertEqual(changesEntry(controller)?.fileChanges.count, 1, "two edits to one file are one change")
        XCTAssertEqual(changesEntry(controller)?.fileChanges.first?.original, "a b\n")
    }
}
