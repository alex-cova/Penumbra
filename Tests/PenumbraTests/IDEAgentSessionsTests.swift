import AgentKit
import Foundation
import XCTest
@testable import Umbra

@MainActor
final class IDEAgentSessionsTests: XCTestCase {
    private var project: URL!
    private var storeDirectory: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-sessions-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = base.appendingPathComponent("project", isDirectory: true)
        storeDirectory = base.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.project.setRoot(project)
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        if let base = project?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: base) }
    }

    private func makeSettings() -> IDEAgentSettings {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        return settings
    }

    private func makeController(
        _ turns: [MockTurn], settings: IDEAgentSettings? = nil, client: MockLLMClient? = nil
    ) -> (IDEAgentController, MockLLMClient) {
        let client = client ?? MockLLMClient(turns: turns)
        let controller = IDEAgentController(
            settings: settings ?? makeSettings(), store: SessionStore(directory: storeDirectory), clientFactory: { _ in client })
        controller.attach(host: workspace)
        return (controller, client)
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

    // MARK: - Persistence and resume

    func testAConversationIsSavedAndComesBackInANewController() async throws {
        try "hello\n".write(to: project.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        let (first, _) = makeController([
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)), .text("It says hello."),
        ])
        await run(first, "what does A.txt say?")
        XCTAssertEqual(first.history.count, 1)

        let secondClient = MockLLMClient(turns: [.text("Same as before.")])
        let (second, _) = makeController([], client: secondClient)
        second.restoreLatestIfNeeded()
        XCTAssertEqual(second.entries.map(\.text).filter { !$0.isEmpty }.first, "what does A.txt say?")
        XCTAssertEqual(second.entries.last?.text, "It says hello.")
        XCTAssertEqual(second.conversationID, first.conversationID)
        let tool = try XCTUnwrap(second.entries.first { $0.kind == .toolCall(name: "read_file") })
        XCTAssertEqual(tool.output?.isError, false)
        XCTAssertTrue(tool.output?.text.contains("hello") == true)

        await run(second, "and again?")
        let items = try XCTUnwrap(secondClient.requests.first).items
        XCTAssertEqual(items.count, 5, "the earlier turns went back to the model: user, call, output, answer, new user")
        guard case .user(let sent) = items[0] else { return XCTFail("first item should be the original message") }
        XCTAssertTrue(sent.hasSuffix("what does A.txt say?"))
        XCTAssertEqual(second.history.count, 1, "the resumed conversation is updated, not duplicated")
    }

    func testNewConversationKeepsTheOldOneInTheHistory() async {
        let (controller, _) = makeController([.text("one"), .text("two")])
        await run(controller, "first")
        let firstID = controller.conversationID
        controller.newConversation()
        XCTAssertTrue(controller.entries.isEmpty)
        XCTAssertNotEqual(controller.conversationID, firstID)
        XCTAssertEqual(controller.conversations.count, 2, "a new chat is a new tab")
        await run(controller, "second")
        XCTAssertEqual(Set(controller.history.map(\.id)), [firstID, controller.conversationID])

        controller.resume(firstID)
        XCTAssertEqual(controller.entries.first?.text, "first", "the tab that has it is shown")
        XCTAssertEqual(controller.conversations.count, 2)
        controller.deleteConversation(firstID)
        XCTAssertEqual(controller.history.count, 1)
        XCTAssertEqual(controller.conversations.count, 1, "deleting a conversation closes the tab showing it")
        XCTAssertEqual(controller.entries.first?.text, "second", "and the neighbor is shown")
    }

    func testClearHistoryRemovesEveryConversationOfTheProject() async {
        let (controller, _) = makeController([.text("one")])
        await run(controller, "hello")
        XCTAssertEqual(controller.history.count, 1)
        controller.clearHistory()
        XCTAssertTrue(controller.history.isEmpty)
        let (fresh, _) = makeController([])
        fresh.restoreLatestIfNeeded()
        XCTAssertTrue(fresh.entries.isEmpty)
    }

    func testSendingInAFreshWindowContinuesTheLatestConversationThePanelShows() async {
        let (first, _) = makeController([.text("saved")])
        await run(first, "old question")
        let (second, client) = makeController([.text("fresh")])
        await run(second, "new question")
        XCTAssertEqual(second.entries.first?.text, "old question")
        XCTAssertEqual(second.entries.filter { $0.kind == .user }.map(\.text), ["old question", "new question"])
        XCTAssertEqual(second.history.count, 1, "one conversation, continued")
        XCTAssertEqual(client.requests.first?.items.count, 3, "and the model saw the earlier exchange")

        second.newConversation()
        await run(second, "unrelated")
        XCTAssertEqual(second.history.count, 2, "New Conversation really starts another")
    }

    func testNoStoreMeansNothingIsWritten() async throws {
        let client = MockLLMClient(turns: [.text("hi")])
        let controller = IDEAgentController(settings: makeSettings(), clientFactory: { _ in client })
        controller.attach(host: workspace)
        await run(controller, "hello")
        XCTAssertTrue(controller.history.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeDirectory.path))
    }

    func testSavedFilesAreReadableByTheUserOnly() async throws {
        let (controller, _) = makeController([.text("hi")])
        await run(controller, "hello")
        let folder = SessionStore(directory: storeDirectory).projectDirectory(for: project.path)
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("sk-test"), "no credential is written")
    }

    // MARK: - Persisted rows

    func testPersistedEntriesKeepTheTranscriptAndDropWhatCannotSurvive() {
        var finished = IDEAgentEntry(kind: .toolCall(name: "grep"), text: #"{"pattern":"x"}"#, callID: "c1")
        finished.output = ToolOutput("a:1: x", isError: false)
        finished.liveOutput = "live"
        let unfinished = IDEAgentEntry(kind: .toolCall(name: "run_command"), text: "{}", callID: "c2")
        var changes = IDEAgentEntry(kind: .changes, text: "")
        changes.fileChanges = [IDEAgentFileChange(path: "A", original: nil)]
        let rows = [IDEAgentEntry(kind: .user, text: "q"), finished, unfinished, changes,
                    IDEAgentEntry(kind: .error, text: "boom"), IDEAgentEntry(kind: .notice, text: "n")]

        let restored = IDEAgentPersistedEntry.decode(IDEAgentPersistedEntry.encode(rows))
        XCTAssertEqual(restored.map(\.kind), [.user, .toolCall(name: "grep"), .error, .notice])
        XCTAssertEqual(restored[1].callID, "c1")
        XCTAssertEqual(restored[1].output, ToolOutput("a:1: x"))
        XCTAssertEqual(restored[1].liveOutput, "", "live output is not kept")
        XCTAssertEqual(IDEAgentPersistedEntry.decode(nil), [])
        XCTAssertEqual(IDEAgentPersistedEntry.decode(Data("garbage".utf8)), [])
    }

    // MARK: - Project instructions

    func testAGENTSmdGoesToTheModelAndFallsBackToCLAUDEmd() async throws {
        try "Use tabs. Never edit generated code.\n".write(to: project.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "claude only".write(to: project.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        let (controller, client) = makeController([.text("ok")])
        await run(controller, "hi")
        let system = try XCTUnwrap(client.requests.first).system
        XCTAssertTrue(system.contains("Use tabs. Never edit generated code."))
        XCTAssertFalse(system.contains("claude only"), "AGENTS.md wins when both exist")

        try FileManager.default.removeItem(at: project.appendingPathComponent("AGENTS.md"))
        XCTAssertEqual(IDEAgentProjectNotes.load(root: project), "claude only")
        try FileManager.default.removeItem(at: project.appendingPathComponent("CLAUDE.md"))
        XCTAssertNil(IDEAgentProjectNotes.load(root: project))
    }

    func testProjectNotesAreCappedAndSymlinksAreNotFollowed() throws {
        try String(repeating: "é", count: 20_000).write(to: project.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let notes = try XCTUnwrap(IDEAgentProjectNotes.load(root: project))
        XCTAssertLessThan(notes.utf8.count, IDEAgentProjectNotes.byteLimit + 100)
        XCTAssertFalse(notes.contains("\u{FFFD}"), "a character cut in half is dropped, not shown as garbage")
        XCTAssertTrue(notes.hasSuffix("the rest was left out.]"))

        try FileManager.default.removeItem(at: project.appendingPathComponent("AGENTS.md"))
        let outside = project.deletingLastPathComponent().appendingPathComponent("outside.md")
        try "private".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("AGENTS.md"), withDestinationURL: outside)
        XCTAssertNil(IDEAgentProjectNotes.load(root: project))
    }

    // MARK: - Modes

    func testApproveEachEditShowsTheDiffAndAppliesOnApply() async throws {
        try "one\ntwo\nthree\n".write(to: project.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        let settings = makeSettings()
        settings.mode = .manual
        let (controller, _) = makeController([
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)),
            .toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"two","new_string":"2"}"#)),
            .text("done"),
        ], settings: settings)
        controller.draft = "change it"
        controller.send()
        await waitFor("an edit approval is requested") { controller.entries.contains { $0.approval != nil } }
        let request = try XCTUnwrap(controller.entries.compactMap(\.approval).first)
        XCTAssertEqual(request.title, "Apply edit")
        XCTAssertTrue(request.diff?.contains("-two") == true && request.diff?.contains("+2") == true)
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("A.txt"), encoding: .utf8), "one\ntwo\nthree\n", "nothing changes before Apply")

        controller.decide(callID: request.callID, .approve)
        await waitFor("the run ends") { !controller.isRunning }
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("A.txt"), encoding: .utf8), "one\n2\nthree\n")
    }

    func testPlanOnlyKeepsEditToolsOutOfTheRequest() async throws {
        let settings = makeSettings()
        settings.mode = .plan
        let (controller, client) = makeController([.text("Plan: change A.")], settings: settings)
        await run(controller, "fix it")
        let names = try XCTUnwrap(client.requests.first).tools.map(\.name)
        XCTAssertFalse(names.contains("edit_file") || names.contains("write_file") || names.contains("run_command"))
        XCTAssertTrue(names.contains("read_file"))
        XCTAssertTrue(try XCTUnwrap(client.requests.first).system.contains("Plan mode"))
    }

    func testChangingTheChatsModeKeepsTheSessionAndTellsTheModel() async throws {
        let settings = makeSettings()
        let (controller, client) = makeController([.text("one"), .text("two")], settings: settings)
        await run(controller, "first")
        let session = try XCTUnwrap(controller.currentSessionForTesting)

        controller.selected.setMode(.plan)
        await run(controller, "second")

        XCTAssertTrue(controller.currentSessionForTesting === session, "a mode change is not a new session")
        let second = try XCTUnwrap(client.requests.last)
        XCTAssertFalse(second.tools.map(\.name).contains("edit_file"), "plan withholds the edit tools from the next request")
        XCTAssertEqual(second.items.count, 4, "the first exchange carried over, then the second message and the mode note")
        guard case .user(let note) = second.items[3] else { return XCTFail("expected the mode note, got \(second.items[3])") }
        XCTAssertTrue(note.hasPrefix("[Note from the editor, not from the user]") && note.contains("Plan"))
    }

    func testANewChatStartsInTheSettingsModeAndTheSettingDoesNotMoveARunningChat() async throws {
        let settings = makeSettings()
        settings.mode = .manual
        let (controller, _) = makeController([.text("one")], settings: settings)
        XCTAssertEqual(controller.selected.mode, .manual)

        settings.mode = .auto
        XCTAssertEqual(controller.selected.mode, .manual, "the setting is the default for new chats only")
        controller.newConversation()
        XCTAssertEqual(controller.selected.mode, .manual, "a fresh conversation in the same chat keeps the chat's mode")
    }

    func testProtectedFilePatternsReachTheReadTool() async throws {
        try "token=1\n".write(to: project.appendingPathComponent("prod.vault"), atomically: true, encoding: .utf8)
        let settings = makeSettings()
        settings.secretFilePatternsText = "*.vault\n"
        let (controller, _) = makeController([
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"prod.vault"}"#)), .text("refused"),
        ], settings: settings)
        await run(controller, "read it")
        let tool = try XCTUnwrap(controller.entries.first { $0.callID == "r" })
        XCTAssertEqual(tool.output?.isError, true)
        XCTAssertTrue(tool.output?.text.contains("credentials") == true)
    }

    // MARK: - Compaction notice and settings

    func testCompactionNoticeSaysWhatWasDoneAndNothingWhenNothingWas() {
        var report = CompactionReport()
        XCTAssertNil(IDEAgentConversation.compactionNotice(report))
        report.stubbedOutputs = 3
        XCTAssertEqual(IDEAgentConversation.compactionNotice(report), "Context was getting full: cleared 3 old tool outputs.")
        report.summarizedItems = 12
        report.summaryFailed = true
        let text = IDEAgentConversation.compactionNotice(report)
        XCTAssertTrue(text?.contains("cleared 3 old tool outputs and summarized 12 earlier messages") == true)
        XCTAssertTrue(text?.contains("could not be written") == true)
    }

    func testContextWindowComesFromTheLocalSettingTheOverrideOrTheModelTable() {
        let settings = makeSettings()
        settings.model = "gpt-5.1-codex"
        XCTAssertEqual(settings.contextWindow, 400_000)
        settings.model = "some-unknown-model"
        XCTAssertNil(settings.contextWindow, "unknown hosted models compact on the server's overflow report")
        settings.contextWindowOverride = 65_536
        XCTAssertEqual(settings.contextWindow, 65_536)
        settings.provider = .ollama
        settings.localContextLength = 16_384
        XCTAssertEqual(settings.contextWindow, 16_384, "a local model uses what was requested from it")
    }

    func testBehaviorSettingsPersistAndChangeTheFingerprint() {
        let defaults = UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!
        let settings = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        XCTAssertEqual(settings.mode, .acceptEdits)
        XCTAssertEqual(settings.iterationCap, IDEAgentSettings.defaultIterationCap)
        let before = settings.fingerprint
        settings.mode = .manual
        settings.iterationCap = 80
        settings.contextWindowOverride = 100_000
        settings.secretFilePatternsText = "*.vault"
        XCTAssertNotEqual(settings.fingerprint, before)

        let reloaded = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        XCTAssertEqual(reloaded.mode, .manual)
        XCTAssertEqual(reloaded.iterationCap, 80)
        XCTAssertEqual(reloaded.contextWindowOverride, 100_000)
        XCTAssertEqual(reloaded.secretFilePatterns, ["*.vault"])
    }
}
