import AgentKit
import XCTest
@testable import Umbra

@MainActor
private final class FakeAgentHost: IDEAgentHost {
    var agentProjectRoot: URL?
    var unsaved: [String: String] = [:]
    var problems: [IDEAgentProblem] = []

    init(root: URL?) { agentProjectRoot = root }

    func agentUnsavedBuffers() -> [String: String] { unsaved }
    func agentEditorContext() -> String { "[Editor state, for orientation only]\nActive file: A.java\n[End editor state]" }
    func agentProblems() -> [IDEAgentProblem] { problems }
    func agentReplaceText(relativePath: String, expecting: String, edits: [AgentTextEdit]) async throws { throw AgentWorkspaceError.readOnly }
    func agentCreateFile(relativePath: String, contents: String) async throws { throw AgentWorkspaceError.readOnly }
    func agentTrashFile(relativePath: String) async throws { throw AgentWorkspaceError.readOnly }
    func agentShowDiff(relativePath: String, original: String?) {}
    func agentCommandEnvironment() async -> [String: String] { AgentCommandEnvironment.make(javaHome: nil) }
    func agentSaveBuffers(relativePaths: [String]) async {}
    var agentIsGradleProject: Bool { false }
    func agentRunGradle(tasks: [String], options: [String], timeout: TimeInterval) async -> IDEGradleRunOutcome {
        .notStarted("not a Gradle project")
    }
    func agentCancelGradle() {}
    func agentFreshProblems(relativePaths: [String]) async -> IDEAgentFreshProblems { IDEAgentFreshProblems() }
}

@MainActor
private func makeSettings(key: String? = "sk-test", disclosed: Bool = true, defaults: UserDefaults? = nil) -> IDEAgentSettings {
    let defaults = defaults ?? UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!
    let store = IDEAgentMemoryKeyStore()
    let settings = IDEAgentSettings(defaults: defaults, keyStore: store)
    if let key { settings.saveAPIKey(key) }
    if disclosed { settings.acceptDisclosure() }
    return settings
}

private func tempProject() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-agent-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Waits for `condition`, spinning the main actor. Fails the test on timeout.
@MainActor
private func eventually(_ message: String, timeout: Double = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), message)
}

@MainActor
final class IDEAgentSettingsTests: XCTestCase {
    func testKeysAndDisclosureAreKeptPerEndpointHost() {
        let settings = makeSettings(key: "sk-openai", disclosed: true)
        XCTAssertTrue(settings.hasAPIKey)
        XCTAssertTrue(settings.hasAcceptedDisclosure)

        settings.baseURL = "https://example.azure.com/openai/v1"
        settings.refreshKeyState()
        XCTAssertFalse(settings.hasAPIKey, "another host has its own key")
        XCTAssertFalse(settings.hasAcceptedDisclosure, "and its own consent")

        settings.baseURL = IDEAgentSettings.defaultBaseURL
        settings.refreshKeyState()
        XCTAssertTrue(settings.hasAPIKey)
        XCTAssertTrue(settings.hasAcceptedDisclosure)
    }

    func testSettingsPersistAndTheKeyNeverReachesUserDefaults() {
        let defaults = UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!
        let settings = makeSettings(key: "sk-super-secret", defaults: defaults)
        settings.model = "my-model"
        settings.reasoningEffort = "high"

        let reloaded = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        XCTAssertEqual(reloaded.model, "my-model")
        XCTAssertEqual(reloaded.reasoningEffort, "high")
        XCTAssertTrue(reloaded.hasAcceptedDisclosure)
        for (_, value) in defaults.dictionaryRepresentation() {
            XCTAssertFalse("\(value)".contains("sk-super-secret"))
        }
    }

    func testMakeClientReportsWhatIsMissing() {
        let noKey = makeSettings(key: nil)
        XCTAssertThrowsError(try noKey.makeClient()) {
            XCTAssertEqual($0 as? IDEAgentSettings.ConfigurationError, .missingAPIKey(host: "api.openai.com"))
        }
        let badURL = makeSettings()
        badURL.baseURL = "not a url"
        XCTAssertThrowsError(try badURL.makeClient()) {
            XCTAssertEqual($0 as? IDEAgentSettings.ConfigurationError, .invalidBaseURL)
        }
        let noModel = makeSettings()
        noModel.model = "  "
        XCTAssertThrowsError(try noModel.makeClient()) {
            XCTAssertEqual($0 as? IDEAgentSettings.ConfigurationError, .missingModel)
        }
        XCTAssertNoThrow(try makeSettings().makeClient())
    }

    func testReasoningOffSendsNoEffortAndAChangeChangesTheFingerprint() {
        let settings = makeSettings()
        settings.reasoningEffort = "off"
        XCTAssertNil(settings.effectiveReasoningEffort)
        let before = settings.fingerprint
        settings.reasoningEffort = "low"
        XCTAssertEqual(settings.effectiveReasoningEffort, "low")
        XCTAssertNotEqual(settings.fingerprint, before)
    }

    func testTheKeychainStoreRoundTripsAndOverwrites() throws {
        let store = IDEAgentMemoryKeyStore()
        try store.save("  one  ", account: "host")
        XCTAssertEqual(try store.load(account: "host"), "one")
        try store.save("two", account: "host")
        XCTAssertEqual(try store.load(account: "host"), "two")
        try store.save("   ", account: "host")
        XCTAssertNil(try store.load(account: "host"), "saving an empty key removes it")
    }
}

final class IDEAgentToolSummaryTests: XCTestCase {
    func testTitlesNameTheFileOrPatternTheCallIsAbout() {
        XCTAssertEqual(IDEAgentToolSummary.title(name: "read_file", arguments: #"{"path":"src/A.java"}"#), "read_file  src/A.java")
        XCTAssertEqual(
            IDEAgentToolSummary.title(name: "read_file", arguments: #"{"path":"A.java","offset":10,"limit":5}"#),
            "read_file  A.java :10–14")
        XCTAssertEqual(IDEAgentToolSummary.title(name: "grep", arguments: #"{"pattern":"foo"}"#), "grep  “foo”")
        XCTAssertEqual(IDEAgentToolSummary.title(name: "list_dir", arguments: #"{"path":""}"#), "list_dir  .")
        XCTAssertEqual(IDEAgentToolSummary.title(name: "glob", arguments: #"{"pattern":"**/*.java"}"#), "glob  **/*.java")
    }

    func testUnreadableArgumentsFallBackToTheToolName() {
        XCTAssertEqual(IDEAgentToolSummary.title(name: "read_file", arguments: ""), "read_file")
        XCTAssertEqual(IDEAgentToolSummary.title(name: "mystery", arguments: #"{"x":1}"#), "mystery")
    }

    func testOnlyAbnormalEndingsProduceANotice() {
        XCTAssertNil(IDEAgentToolSummary.endingMessage(.completed, iterationLimit: 40))
        XCTAssertEqual(IDEAgentToolSummary.endingMessage(.stopped, iterationLimit: 40)?.isError, false)
        XCTAssertTrue(IDEAgentToolSummary.endingMessage(.iterationCap, iterationLimit: 40)!.text.contains("40 steps"))
        XCTAssertEqual(IDEAgentToolSummary.endingMessage(.failed("boom"), iterationLimit: 40)?.text, "boom")
        XCTAssertEqual(IDEAgentToolSummary.endingMessage(.failed("boom"), iterationLimit: 40)?.isError, true)
    }
}

final class IDEDiagnosticsToolTests: XCTestCase {
    private func run(_ tool: IDEDiagnosticsTool, _ arguments: String) async throws -> ToolOutput {
        let project = try tempProject()
        defer { try? FileManager.default.removeItem(at: project) }
        return await tool.execute(
            argumentsJSON: arguments,
            context: ToolContext(workspace: DiskAgentWorkspace(root: project), ledger: ReadLedger(), callID: "c"))
    }

    func testListsProblemsAsPathLineSeveritySourceMessage() async throws {
        let tool = IDEDiagnosticsTool(problems: {
            [
                IDEAgentProblem(path: "A.java", line: 3, severity: "error", source: "javac", message: "cannot find symbol"),
                IDEAgentProblem(path: "B.java", line: 9, severity: "warning", source: "java-inspection", message: "unused"),
            ]
        })
        let all = try await run(tool, "{}")
        XCTAssertEqual(all.text, "A.java:3: error [javac]: cannot find symbol\nB.java:9: warning [java-inspection]: unused")
        let one = try await run(tool, #"{"path":"B.java"}"#)
        XCTAssertEqual(one.text, "B.java:9: warning [java-inspection]: unused")
    }

    func testAnEmptyResultSaysWhatItDoesNotCover() async throws {
        let output = try await run(IDEDiagnosticsTool(problems: { [] }), "{}")
        XCTAssertTrue(output.text.contains("open files, the last Gradle build and the files compiled just now"))
        XCTAssertFalse(output.isError)
    }

    func testLongListsAreCapped() async throws {
        let many = (0..<150).map { IDEAgentProblem(path: "A.java", line: $0 + 1, severity: "warning", source: "x", message: "m") }
        let output = try await run(IDEDiagnosticsTool(problems: { many }), "{}")
        XCTAssertTrue(output.text.hasSuffix("[50 more problems not shown. Pass a path.]"))
    }
}

@MainActor
final class IDEAgentControllerTests: XCTestCase {
    /// The controller holds its host weakly, as it must, so the test keeps the fakes alive.
    private var hosts: [FakeAgentHost] = []

    private func makeController(
        turns: [MockTurn], settings: IDEAgentSettings? = nil, root: URL? = nil
    ) throws -> (IDEAgentController, MockLLMClient, FakeAgentHost) {
        let client = MockLLMClient(turns: turns)
        let project = try root ?? tempProject()
        let host = FakeAgentHost(root: project)
        let controller = IDEAgentController(settings: settings ?? makeSettings(), clientFactory: { _ in client })
        controller.attach(host: host)
        hosts.append(host)
        return (controller, client, host)
    }

    func testAToolRunShowsUpAsUserToolCardAndAnswer() async throws {
        let project = try tempProject()
        try Data("class A {}\n".utf8).write(to: project.appendingPathComponent("A.java"))
        let (controller, client, _) = try makeController(
            turns: [
                .toolCalls((id: "c1", name: "read_file", arguments: #"{"path":"A.java"}"#)),
                .text("It declares class A."),
            ], root: project)

        controller.draft = "what is in A.java?"
        controller.send()
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(controller.draft, "")
        await eventually("the run should finish") { !controller.isRunning }

        XCTAssertEqual(controller.entries.map(\.kind), [.user, .toolCall(name: "read_file"), .assistant])
        XCTAssertEqual(controller.entries[0].text, "what is in A.java?", "the transcript shows the message, not the framing")
        XCTAssertEqual(controller.entries[1].output?.text.contains("     1\tclass A {}"), true)
        XCTAssertEqual(controller.entries[2].text, "It declares class A.")
        XCTAssertFalse(controller.entries[2].isStreaming)

        // The model got the editor state in front of the message.
        guard case .user(let sent) = client.requests[0].items[0] else { return XCTFail("first item should be the user message") }
        XCTAssertTrue(sent.hasPrefix("[Editor state"))
        XCTAssertTrue(sent.hasSuffix("what is in A.java?"))
        XCTAssertEqual(client.requests[0].tools.map(\.name), ["read_file", "list_dir", "glob", "grep", "edit_file", "write_file", "apply_patch", "run_command", "todo", "ask_user", "diagnostics"])
    }

    func testTheModelReadsUnsavedEditsNotTheStaleDiskCopy() async throws {
        let project = try tempProject()
        let file = project.appendingPathComponent("A.java")
        try Data("old text\n".utf8).write(to: file)
        let (controller, _, host) = try makeController(
            turns: [.toolCalls((id: "c", name: "read_file", arguments: #"{"path":"A.java"}"#)), .text("done")], root: project)
        host.unsaved = [file.standardizedFileURL.path: "unsaved text\n"]

        controller.draft = "read it"
        controller.send()
        await eventually("the run should finish") { !controller.isRunning }
        XCTAssertEqual(controller.entries[1].output?.text.contains("unsaved text"), true)
        XCTAssertEqual(controller.entries[1].output?.text.contains("old text"), false)
    }

    func testNothingIsSentUntilTheDisclosureIsAccepted() throws {
        let (controller, client, _) = try makeController(turns: [.text("hi")], settings: makeSettings(disclosed: false))
        controller.draft = "hello"
        XCTAssertFalse(controller.canSend)
        controller.send()
        XCTAssertFalse(controller.isRunning)
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertEqual(controller.draft, "hello", "the draft is kept")
    }

    func testAMissingKeyIsReportedInTheTranscriptAndNothingRuns() async throws {
        let host = FakeAgentHost(root: try tempProject())
        hosts.append(host)
        let controller = IDEAgentController(settings: makeSettings(key: nil))
        controller.attach(host: host)
        controller.draft = "hello"
        controller.send()
        await eventually("the error should appear") { !controller.isRunning && controller.entries.count == 2 }
        XCTAssertEqual(controller.entries.last?.kind, .error)
        XCTAssertTrue(controller.entries.last?.text.contains("API key") == true)
    }

    func testWithoutAProjectFolderTheAgentSaysSo() throws {
        let host = FakeAgentHost(root: nil)
        hosts.append(host)
        let controller = IDEAgentController(settings: makeSettings(), clientFactory: { _ in MockLLMClient(turns: []) })
        controller.attach(host: host)
        controller.draft = "hello"
        controller.send()
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.entries.last?.kind, .error)
    }

    func testAProviderFailureBecomesAnErrorRowAndTheNextMessageWorks() async throws {
        let (controller, _, _) = try makeController(turns: [
            MockTurn([], failure: .unauthorized), .text("back"),
        ])
        controller.draft = "one"
        controller.send()
        await eventually("first run ends") { !controller.isRunning }
        XCTAssertEqual(controller.entries.map(\.kind), [.user, .error])

        controller.draft = "two"
        controller.send()
        await eventually("second run ends") { !controller.isRunning }
        XCTAssertEqual(controller.entries.last?.text, "back")
    }

    func testStopEndsTheRunWithANoticeAndKeepsTheTranscript() async throws {
        let events = (0..<100).map { LLMEvent.textDelta("w\($0) ") } + [.finished(.completed)]
        let (controller, _, _) = try makeController(turns: [MockTurn(events, delayPerEvent: .milliseconds(20))])
        controller.draft = "talk"
        controller.send()
        await eventually("text starts streaming") { controller.entries.contains { $0.kind == .assistant } }
        controller.stop()
        await eventually("the run stops") { !controller.isRunning }

        XCTAssertEqual(controller.entries.last?.text, "Stopped.")
        XCTAssertEqual(controller.entries.last?.kind, .notice)
        XCTAssertTrue(controller.entries.contains { $0.kind == .assistant && !$0.isStreaming }, "no entry is left streaming")
    }

    func testStreamedTextIsCoalescedIntoOneEntry() async throws {
        let (controller, _, _) = try makeController(turns: [])
        for piece in ["He", "llo", ", ", "world"] { controller.handle(.textDelta(piece)) }
        XCTAssertTrue(controller.entries.isEmpty, "deltas are buffered, not applied one by one")
        await eventually("the flush timer fires") { controller.entries.count == 1 }
        XCTAssertEqual(controller.entries[0].text, "Hello, world")
        XCTAssertTrue(controller.entries[0].isStreaming)
        controller.handle(.assistantMessage("Hello, world"))
        XCTAssertFalse(controller.entries[0].isStreaming)
        XCTAssertEqual(controller.entries.count, 1)
    }

    /// A real model says something, then calls a tool. The text must appear once, before the card.
    func testTextBeforeAToolCallIsNotShownTwice() async throws {
        let (controller, _, _) = try makeController(turns: [])
        controller.handle(.stateChanged(.streaming))
        controller.handle(.textDelta("Let me look. "))
        controller.handle(.toolCallStarted(id: "c1", name: "read_file"))
        controller.handle(.toolCallArguments(id: "c1", name: "read_file", arguments: #"{"path":"A.java"}"#))
        controller.handle(.toolCallFinished(id: "c1", name: "read_file", output: ToolOutput("contents")))
        controller.handle(.assistantMessage("Let me look. "))
        XCTAssertEqual(controller.entries.map(\.kind), [.assistant, .toolCall(name: "read_file")])
        XCTAssertEqual(controller.entries[0].text, "Let me look. ")
        XCTAssertFalse(controller.entries[0].isStreaming)

        // The next turn's text is a new entry, after the card.
        controller.handle(.stateChanged(.streaming))
        controller.handle(.textDelta("Found it."))
        controller.handle(.assistantMessage("Found it."))
        XCTAssertEqual(controller.entries.map(\.kind), [.assistant, .toolCall(name: "read_file"), .assistant])
        XCTAssertEqual(controller.entries.last?.text, "Found it.")
    }

    func testATurnWithOnlyToolCallsStillGetsNoAssistantEntry() async throws {
        let (controller, _, _) = try makeController(turns: [])
        controller.handle(.stateChanged(.streaming))
        controller.handle(.toolCallStarted(id: "c1", name: "grep"))
        controller.handle(.toolCallFinished(id: "c1", name: "grep", output: ToolOutput("x")))
        XCTAssertEqual(controller.entries.map(\.kind), [.toolCall(name: "grep")])
    }

    func testARetriedTurnDropsItsPartialEntries() async throws {
        let (controller, _, _) = try makeController(turns: [])
        controller.handle(.stateChanged(.streaming))
        controller.handle(.textDelta("partial"))
        controller.handle(.toolCallStarted(id: "x", name: "grep"))
        XCTAssertEqual(controller.entries.count, 2)
        controller.handle(.turnRestarted)
        XCTAssertTrue(controller.entries.isEmpty)
    }

    func testClearResetsTheConversation() async throws {
        let (controller, client, _) = try makeController(turns: [.text("one"), .text("two")])
        controller.draft = "first"
        controller.send()
        await eventually("run ends") { !controller.isRunning }
        controller.clear()
        XCTAssertTrue(controller.entries.isEmpty)
        controller.draft = "second"
        controller.send()
        await eventually("run ends") { !controller.isRunning }
        XCTAssertEqual(client.requests[1].items.count, 1, "a cleared conversation starts from scratch")
    }

    func testChangingTheModelKeepsTheConversationButDropsProviderItems() async throws {
        let settings = makeSettings()
        let reasoning = OpaqueItem(provider: "openai-responses", payload: ["type": "reasoning"])
        let (controller, client, _) = try makeController(
            turns: [
                MockTurn([.opaqueItem(reasoning), .textDelta("first"), .finished(.completed)]),
                .text("second"),
            ], settings: settings)
        controller.draft = "q1"
        controller.send()
        await eventually("run ends") { !controller.isRunning }

        settings.model = "another-model"
        controller.draft = "q2"
        controller.send()
        await eventually("run ends") { !controller.isRunning }

        let items = client.requests[1].items
        XCTAssertFalse(items.contains { if case .opaque = $0 { true } else { false } })
        XCTAssertTrue(items.contains(.assistant("first")), "the conversation itself carries over")
        XCTAssertEqual(client.requests[1].model, "another-model")
    }

    /// A session mid-run must not keep the window alive: tools reach it weakly, and teardown
    /// ends the run.
    func testARunningSessionDoesNotKeepTheWorkspaceAlive() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        defer { IDEWorkspace.isSessionPersistenceEnabled = true }
        let project = try tempProject()
        let events = (0..<500).map { LLMEvent.textDelta("w\($0) ") } + [.finished(.completed)]
        let client = MockLLMClient(turns: [MockTurn(events, delayPerEvent: .milliseconds(10))])
        let controller = IDEAgentController(settings: makeSettings(), clientFactory: { _ in client })

        weak var weakWorkspace: IDEWorkspace?
        do {
            let workspace = IDEWorkspace()
            workspace.project.setRoot(project)
            weakWorkspace = workspace
            controller.attach(host: workspace)
            controller.draft = "go"
            controller.send()
            await eventually("streaming starts") { controller.entries.contains { $0.kind == .assistant } }
            XCTAssertTrue(controller.isRunning)
            workspace.teardown()
        }
        controller.teardown()
        await eventually("the workspace is freed", timeout: 5) { weakWorkspace == nil }
        XCTAssertNil(weakWorkspace)
        XCTAssertFalse(controller.isRunning)
    }

    func testAnIdleSessionDoesNotKeepTheWorkspaceAliveEither() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        defer { IDEWorkspace.isSessionPersistenceEnabled = true }
        let project = try tempProject()
        let controller = IDEAgentController(
            settings: makeSettings(), clientFactory: { _ in MockLLMClient(turns: [.text("hi")]) })
        weak var weakWorkspace: IDEWorkspace?
        do {
            let workspace = IDEWorkspace()
            workspace.project.setRoot(project)
            weakWorkspace = workspace
            controller.attach(host: workspace)
            controller.draft = "go"
            controller.send()
            await eventually("run ends") { !controller.isRunning }
            workspace.teardown()
        }
        await eventually("the workspace is freed") { weakWorkspace == nil }
        XCTAssertNil(weakWorkspace)
    }
}
