import AgentKit
import EditorIntelligence
import XCTest
@testable import Umbra

@MainActor
private final class FakeAgentHost: IDEAgentHost {
    var agentProjectRoot: URL?
    var unsaved: [String: String] = [:]
    var problems: [IDEAgentProblem] = []
    /// What the user answers when asked about the project's MCP servers; nothing by default.
    var mcpAnswer: ([MCPServerConfig]) -> Set<String> = { _ in [] }
    var mcpQuestions = 0
    /// What the user answers when asked whether a project's skill may pre-approve its tools; no by default.
    var skillToolsAnswer: (String) -> Bool = { _ in false }
    var skillToolsQuestions: [String] = []
    var navigator: (any IDEAgentNavigating)?
    var symbolSearch: (any IDEAgentSymbolSearching)?
    var hoverEngine: HoverEngine?
    var renameProvider: (any RenameProviding)?

    init(root: URL?) { agentProjectRoot = root }

    func agentJavaNavigator() -> (any IDEAgentNavigating)? { navigator }
    func agentSymbolSearch() -> (any IDEAgentSymbolSearching)? { symbolSearch }
    func agentHoverEngine() -> HoverEngine? { hoverEngine }
    func agentRenameProvider() -> (any RenameProviding)? { renameProvider }

    func agentConfirmMCPServers(_ servers: [MCPServerConfig]) async -> Set<String> {
        mcpQuestions += 1
        return mcpAnswer(servers)
    }

    func agentConfirmSkillTools(kind: String, name: String, source: String, tools: [String]) async -> Bool {
        skillToolsQuestions.append("\(kind):\(name)")
        return skillToolsAnswer(name)
    }

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

private struct NoNavigation: IDEAgentNavigating {
    func definitions(file: URL, source: String, utf16Offset: Int) async -> [IDEAgentCodeLocation] { [] }
    func usages(file: URL, source: String, utf16Offset: Int) async -> [IDEAgentCodeLocation] { [] }
}

private struct NoRename: RenameProviding {
    func prepareRename(_ context: NavigationContext) async -> RenameTarget? { nil }
    func rename(_ context: NavigationContext, to newName: String) async throws -> RenamePlan { RenamePlan() }
}

private struct NoSearch: IDEAgentSymbolSearching {
    func symbols(matching query: String, exactName: Bool, limit: Int) async -> [IDEAgentSymbol] { [] }
    func liveText(of file: URL) async -> String? { nil }
    func structure(file: URL, source: String) async -> [StructureNode] { [] }
    func indexReadiness() async -> IDEAgentIndexReadiness { .ready }
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

    func testUserInstructionsStayOutUntilTheUserOptsIn() {
        let settings = makeSettings()
        XCTAssertFalse(settings.loadsUserInstructions)
        XCTAssertNil(IDEAgentProjectNotes.loadUser(settings: settings))
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
        XCTAssertTrue(IDEAgentToolSummary.endingMessage(.degenerateOutput, iterationLimit: 40)!.text.contains("repeating itself"))
        XCTAssertTrue(IDEAgentToolSummary.endingMessage(.iterationCap, iterationLimit: 40)!.text.contains("40 steps"))
        XCTAssertEqual(IDEAgentToolSummary.endingMessage(.budget, iterationLimit: 40)?.isError, false)
        XCTAssertEqual(IDEAgentToolSummary.endingMessage(.failed("boom"), iterationLimit: 40)?.text, "boom")
        XCTAssertEqual(IDEAgentToolSummary.endingMessage(.failed("boom"), iterationLimit: 40)?.isError, true)
    }

    func testANetworkFailureOffersRetryAndOtherFailuresDoNot() {
        XCTAssertTrue(IDEAgentNetworkFailure.offersRetry("Could not connect to localhost."))
        XCTAssertTrue(IDEAgentNetworkFailure.offersRetry("Could not connect to 127.0.0.1."))
        XCTAssertTrue(IDEAgentNetworkFailure.offersRetry("The connection to the API was lost: The request timed out."))
        XCTAssertTrue(IDEAgentNetworkFailure.offersRetry("Ollama isn't running at localhost:11434."))
        XCTAssertFalse(IDEAgentNetworkFailure.offersRetry("The API rejected the key. Check the API key."))
        XCTAssertFalse(IDEAgentNetworkFailure.offersRetry("boom"))
        XCTAssertFalse(IDEAgentNetworkFailure.offersRetry("Open a project folder first; the agent works inside one."))
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
        XCTAssertEqual(client.requests[0].tools.map(\.name), ["read_file", "list_dir", "glob", "grep", "show_file", "edit_file", "write_file", "apply_patch", "run_command", "todo", "ask_user", "explore", "task", "diagnostics"])
    }

    func testAProjectsMCPServerReachesTheModelOnlyAfterTheUserAllowsIt() async throws {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        probe.arguments = ["-c", "pass"]
        probe.standardError = Pipe()
        guard (try? probe.run()) != nil else { throw XCTSkip("python3 is not available") }
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { throw XCTSkip("python3 is not usable here") }

        let project = try tempProject()
        let server = project.appendingPathComponent("server.py")
        try """
        import json, sys
        for line in sys.stdin:
            m = json.loads(line)
            if "id" not in m: continue
            r = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}} if m["method"] == "initialize" else {"tools": [{"name": "ping", "description": "pings", "inputSchema": {"type": "object"}}]}
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}) + "\\n"); sys.stdout.flush()
        """.write(to: server, atomically: true, encoding: .utf8)
        try Data(#"{"mcpServers": {"pinger": {"command": "/usr/bin/python3", "args": ["\#(server.path)"]}}}"#.utf8)
            .write(to: project.appendingPathComponent(".mcp.json"))

        let (controller, client, host) = try makeController(turns: [.text("one"), .text("two")], root: project)
        defer { controller.teardown() }

        // Not allowed: the question is asked, the answer is no, and the tool never reaches the model.
        controller.draft = "first"
        controller.send()
        await eventually("the first run should finish") { !controller.isRunning }
        XCTAssertEqual(host.mcpQuestions, 1)
        XCTAssertFalse(client.requests[0].tools.map(\.name).contains("mcp__pinger__ping"))

        // The user changes their mind in Settings: the next message uses it, with no new question.
        let config = try XCTUnwrap(IDEMCPProjectConfig.load(root: project).servers.first)
        controller.settings.mcp.trust(config)
        controller.draft = "second"
        controller.send()
        await eventually("the second run should finish") { !controller.isRunning }
        XCTAssertEqual(host.mcpQuestions, 1)
        XCTAssertTrue(client.requests[1].tools.map(\.name).contains("mcp__pinger__ping"), "\(client.requests[1].tools.map(\.name))")
    }

    /// What every request carries before the conversation: the system prompt and the tool definitions.
    /// Printed so a change can be judged, and bounded so a tool added without a thought for its size is
    /// noticed (`docs/AGENT_TOOL_LOADING_PLAN.md`).
    func testTheToolsAndSystemPromptStayWithinTheirBudget() async throws {
        let project = try tempProject()
        try Data("class A {}\n".utf8).write(to: project.appendingPathComponent("A.java"))
        let (controller, client, _) = try makeController(turns: [.text("hi")], root: project)
        controller.draft = "hello"
        controller.send()
        await eventually("the run should finish") { !controller.isRunning }
        let request = try XCTUnwrap(client.requests.first)
        var lines: [String] = []
        for tool in request.tools.sorted(by: { ToolCost.characters(of: $0) > ToolCost.characters(of: $1) }) {
            lines.append("  \(tool.name): \(ToolCost.tokens(of: tool, provider: "anthropic")) tokens")
        }
        let tools = ToolCost.tokens(of: request.tools, provider: "anthropic")
        let system = ToolCost.tokens(ofText: request.system, provider: "anthropic")
        print("TOOLCOST Umbra Code session: \(request.tools.count) tools ≈\(tools) tokens, system prompt ≈\(system) tokens (Anthropic counting)\n" + lines.joined(separator: "\n"))
        XCTAssertLessThan(tools, 8_000, "the tool definitions have grown; trim them or load them on demand")
        XCTAssertLessThan(system, 2_500, "the system prompt has grown")
    }

    /// Name search comes first (a question about code starts without a file), and only where the
    /// host can search: a session with navigation alone keeps its old tool list.
    func testNameSearchLeadsTheNavigationToolsOnlyWhenTheHostOffersIt() async throws {
        let withSearch = try makeController(turns: [.text("hi")])
        withSearch.2.navigator = NoNavigation()
        withSearch.2.symbolSearch = NoSearch()
        withSearch.2.hoverEngine = HoverEngine(providers: [])
        withSearch.2.renameProvider = NoRename()
        withSearch.0.draft = "hello"
        withSearch.0.send()
        await eventually("the run should finish") { !withSearch.0.isRunning }
        let names = try XCTUnwrap(withSearch.1.requests.first).tools.map(\.name)
        let start = try XCTUnwrap(names.firstIndex(of: "find_symbol"), "\(names)")
        XCTAssertEqual(
            Array(names[start...].prefix(6)),
            ["find_symbol", "explore_symbol", "go_to_definition", "find_usages", "hover", "rename_symbol"])

        let navigationOnly = try makeController(turns: [.text("hi")])
        navigationOnly.2.navigator = NoNavigation()
        navigationOnly.0.draft = "hello"
        navigationOnly.0.send()
        await eventually("the run should finish") { !navigationOnly.0.isRunning }
        let plain = try XCTUnwrap(navigationOnly.1.requests.first).tools.map(\.name)
        XCTAssertTrue(plain.contains("go_to_definition") && plain.contains("find_usages"))
        XCTAssertFalse(plain.contains("find_symbol") || plain.contains("explore_symbol"), "\(plain)")
        XCTAssertFalse(plain.contains("hover") || plain.contains("rename_symbol"), "\(plain)")
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
        XCTAssertFalse(controller.entries.last?.canRetry == true, "a rejected key is not a network failure")

        controller.draft = "two"
        controller.send()
        await eventually("second run ends") { !controller.isRunning }
        XCTAssertEqual(controller.entries.last?.text, "back")
    }

    func testANetworkFailureDropsThePartialReplyAndRetrySendsTheSameMessage() async throws {
        let (controller, client, _) = try makeController(turns: [
            MockTurn([.textDelta("half")], failure: .unreachable("Could not connect to localhost.")),
            .text("the whole answer"),
        ])
        controller.draft = "hello"
        controller.send()
        await eventually("the failure shows") { !controller.isRunning }
        XCTAssertEqual(controller.entries.map(\.kind), [.user, .error])
        XCTAssertEqual(controller.entries.last?.text, "Could not connect to localhost.")
        XCTAssertTrue(controller.entries.last?.canRetry == true)
        let sent = await controller.currentSessionForTesting?.items.count
        XCTAssertEqual(sent, 1, "the message is in the history once")

        controller.retry()
        await eventually("the retry finishes") { !controller.isRunning && controller.entries.contains { $0.kind == .assistant } }
        XCTAssertEqual(controller.entries.map(\.kind), [.user, .assistant])
        XCTAssertEqual(controller.entries.last?.text, "the whole answer")
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(client.requests[0].items.count, 1)
        XCTAssertEqual(client.requests[1].items.count, 1, "retry does not add a second copy of the message")
    }

    func testRetryAfterALaterTurnFailsKeepsTheWorkAlreadyDone() async throws {
        let (controller, client, _) = try makeController(turns: [
            .toolCalls((id: "c1", name: "list_dir", arguments: #"{"path":"."}"#)),
            MockTurn([], failure: .connectionLost("The network connection was lost.")),
            .text("done"),
        ])
        controller.draft = "look around"
        controller.send()
        await eventually("the later turn fails") { !controller.isRunning }
        XCTAssertEqual(controller.entries.map(\.kind), [.user, .toolCall(name: "list_dir"), .error])
        XCTAssertTrue(controller.entries.last?.text.hasPrefix("The connection to the API was lost") == true)
        XCTAssertTrue(controller.entries.last?.canRetry == true)

        controller.retry()
        await eventually("the retry finishes") { !controller.isRunning && controller.entries.contains { $0.kind == .assistant } }
        XCTAssertEqual(controller.entries.map(\.kind), [.user, .toolCall(name: "list_dir"), .assistant])
        XCTAssertEqual(controller.entries.last?.text, "done")
        XCTAssertEqual(client.requests.count, 3)
        XCTAssertEqual(client.requests[2].items.filter { if case .user = $0 { true } else { false } }.count, 1)
    }

    func testSendingAnotherMessageClearsTheRetryButton() async throws {
        let (controller, _, _) = try makeController(turns: [
            MockTurn([], failure: .unreachable("Could not connect to localhost.")),
            .text("ok"),
        ])
        controller.draft = "one"
        controller.send()
        // The retry button appears while the run's last event is handled; the run is over a moment later,
        // and a send before that is refused.
        await eventually("the failure offers retry") { controller.entries.last?.canRetry == true && !controller.isRunning }
        controller.draft = "two"
        controller.send()
        await eventually("the next message finishes") { !controller.isRunning && controller.entries.last?.text == "ok" }
        XCTAssertFalse(controller.entries.contains(where: \.canRetry))
        XCTAssertEqual(controller.entries.filter { $0.kind == .user }.map(\.text), ["one", "two"])
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

    func testACutOffAnswerKeepsItsTextAndSaysTheModelIsAskedToContinue() async throws {
        let (controller, _, _) = try makeController(turns: [])
        controller.handle(.stateChanged(.streaming))
        controller.handle(.textDelta("half"))
        controller.handle(.assistantMessage("half"))
        controller.handle(.continuing(reason: .outputLimit, attempt: 1))
        XCTAssertEqual(controller.entries.map(\.kind), [.assistant, .notice])
        XCTAssertEqual(controller.entries.first?.text, "half")
        XCTAssertTrue(controller.entries.last?.text.contains("output limit") == true)

        controller.handle(.continuing(reason: .interrupted, attempt: 2))
        XCTAssertTrue(controller.entries.last?.text.contains("connection dropped") == true)
        XCTAssertTrue(controller.entries.last?.text.contains("try 2") == true)
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

@MainActor
final class IDEAgentSkillConsentTests: XCTestCase {
    private var hosts: [FakeAgentHost] = []

    private func write(_ text: String, _ root: URL, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeController(
        turns: [MockTurn], root: URL, settings: IDEAgentSettings? = nil, home: URL? = nil, appSupport: URL? = nil
    ) -> (IDEAgentController, MockLLMClient, FakeAgentHost, IDEAgentSettings) {
        let client = MockLLMClient(turns: turns)
        let host = FakeAgentHost(root: root)
        let settings = settings ?? makeSettings()
        let controller = IDEAgentController(
            settings: settings, commandsHome: home, commandsAppSupport: appSupport, clientFactory: { _ in client })
        controller.attach(host: host)
        controller.newConversation()
        hosts.append(host)
        return (controller, client, host, settings)
    }

    /// A command that waits for the user's answer sends from a task, so wait for the message to appear, then for the run.
    private func say(_ controller: IDEAgentController, _ text: String) async {
        let before = controller.entries.filter { $0.kind == .user }.count
        controller.draft = text
        controller.submit()
        await eventually("the message should be sent and its run finish") {
            controller.entries.filter { $0.kind == .user }.count > before && !controller.isRunning
        }
    }

    private let echoSkill = "---\ndescription: Say hi\nallowed-tools: Bash(echo:*)\n---\nSay hi with echo."
    private let echoCall = MockTurn.toolCalls((id: "c1", name: "run_command", arguments: #"{"command":"echo hi"}"#))

    func testAProjectsSkillAsksOnceBeforeItsToolsSkipApprovalAndAChangeAsksAgain() async throws {
        let project = try tempProject()
        try write(echoSkill, project, ".claude/skills/hi/SKILL.md")
        let (controller, _, host, _) = makeController(turns: [echoCall, .text("done"), echoCall, .text("done")], root: project)
        host.skillToolsAnswer = { _ in true }

        await say(controller, "/hi")
        XCTAssertEqual(host.skillToolsQuestions, ["skill:hi"])
        XCTAssertNil(controller.entries.first { $0.approval != nil || $0.approvalOutcome != nil }, "the tool did not ask: the skill's rule applied")

        await say(controller, "/hi")
        XCTAssertEqual(host.skillToolsQuestions, ["skill:hi"], "the answer is remembered")

        try write(echoSkill + "\nAnd also push.", project, ".claude/skills/hi/SKILL.md")
        controller.commandCatalog.invalidate()
        await say(controller, "/hi")
        XCTAssertEqual(host.skillToolsQuestions, ["skill:hi", "skill:hi"], "an edited skill is a different skill")
    }

    func testDecliningStillRunsTheSkillButEveryToolAsksAndTheAnswerIsRemembered() async throws {
        let project = try tempProject()
        try write(echoSkill, project, ".claude/skills/hi/SKILL.md")
        let (controller, client, host, _) = makeController(turns: [echoCall, .text("done")], root: project)

        controller.draft = "/hi"
        controller.submit()
        await eventually("the command asks for approval") { controller.entries.contains { $0.callID == "c1" && $0.approval != nil } }
        XCTAssertEqual(host.skillToolsQuestions, ["skill:hi"])
        XCTAssertTrue(controller.entries.contains { $0.kind == .notice && $0.text.contains("pre-approved tools were not allowed") })
        guard case .user(let sent) = try XCTUnwrap(client.requests.first).items.first else { return XCTFail("no user item") }
        XCTAssertTrue(sent.contains("Say hi with echo."), "the skill itself still reached the model")
        controller.decide(callID: "c1", .deny(note: nil))
        await eventually("the run ends") { !controller.isRunning }

        await say(controller, "/hi")
        XCTAssertEqual(host.skillToolsQuestions, ["skill:hi"], "a declined skill is not asked about again")
        XCTAssertTrue(controller.entries.filter { $0.kind == .notice && $0.text.contains("pre-approved tools were not allowed") }.count == 2)
    }

    func testYourOwnSkillsAndOnesWithoutToolsNeverAsk() async throws {
        let project = try tempProject()
        let home = try tempProject()
        try write(echoSkill, home, ".claude/skills/mine/SKILL.md")
        try write("---\ndescription: No tools\n---\nJust read.", project, ".claude/skills/plain/SKILL.md")
        let (controller, _, host, _) = makeController(turns: [echoCall, .text("done"), .text("ok")], root: project, home: home)

        await say(controller, "/mine")
        await say(controller, "/plain")
        XCTAssertTrue(host.skillToolsQuestions.isEmpty)
        XCTAssertNil(controller.entries.first { $0.callID == "c1" }?.approval, "the user's own skill pre-approved its tool")
    }

    func testAProjectCommandIsGatedLikeASkill() async throws {
        let project = try tempProject()
        try write("---\nallowed-tools: Bash(echo:*)\n---\nSay hi with echo.", project, ".claude/commands/hi.md")
        let (controller, _, host, _) = makeController(turns: [echoCall, .text("done")], root: project)
        host.skillToolsAnswer = { _ in true }
        await say(controller, "/hi")
        XCTAssertEqual(host.skillToolsQuestions, ["command:hi"])
        XCTAssertNil(controller.entries.first { $0.approval != nil || $0.approvalOutcome != nil })
    }

    func testRevokingAnAnswerMakesItAskAgain() async throws {
        let project = try tempProject()
        try write(echoSkill, project, ".claude/skills/hi/SKILL.md")
        let (controller, _, host, settings) = makeController(turns: [echoCall, .text("done"), echoCall, .text("done")], root: project)
        host.skillToolsAnswer = { _ in true }
        await say(controller, "/hi")

        controller.commandCatalog.invalidate()
        let skill = try XCTUnwrap(controller.commandCatalog.allSkillsCatalog.skill(named: "hi"))
        XCTAssertEqual(IDEAgentSkillConsent.state(of: skill, trust: settings.skillTrust), .trusted)
        settings.skillTrust.forget(IDEAgentSkillTrust.fingerprint(of: skill))
        XCTAssertEqual(IDEAgentSkillConsent.state(of: skill, trust: settings.skillTrust), .unknown)
        await say(controller, "/hi")
        XCTAssertEqual(host.skillToolsQuestions.count, 2)
    }

    func testTheModelSeesWhatTheUserTypedAndThenTheSkillBlock() async throws {
        let project = try tempProject()
        try write("---\ndescription: Review\n---\nRead the diff.", project, ".claude/skills/review/SKILL.md")
        try write("notes", project, ".claude/skills/review/notes.md")
        let (controller, client, _, _) = makeController(turns: [.text("ok")], root: project)
        await say(controller, "/review the last commit")

        guard case .user(let sent) = try XCTUnwrap(client.requests.first).items.first else { return XCTFail("no user item") }
        let body = try XCTUnwrap(sent.range(of: "/review the last commit"))
        XCTAssertTrue(sent[body.upperBound...].hasPrefix("\n\n<skill_content name=\"review\">\nRead the diff."))
        XCTAssertTrue(sent.contains("Skill directory: \(project.standardizedFileURL.path)/.claude/skills/review"))
        XCTAssertTrue(sent.contains("<file>notes.md</file>"))
        XCTAssertEqual(UserText.typed(sent), "/review the last commit", "a title and a summary keep only what was typed")
        XCTAssertTrue(SkillActivations.loaded(in: try XCTUnwrap(client.requests.first).items).contains("review"), "so the tool answers already loaded")
    }

    // MARK: - Folders, flags and the switch

    func testASkillInAnAgentsFolderAndOneAboveTheProjectAreFound() async throws {
        let repo = try tempProject()
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let project = repo.appendingPathComponent("apps/web", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try write("---\ndescription: shared\n---\nb", project, ".agents/skills/shared/SKILL.md")
        try write("---\ndescription: from the repository\n---\nb", repo, ".claude/skills/top/SKILL.md")
        let (controller, _, _, _) = makeController(turns: [.text("ok")], root: project)
        let found = controller.commandCatalog.allSkillsCatalog.skills
        XCTAssertEqual(found.map(\.name), ["shared", "top"])
        XCTAssertEqual(found.map(\.scope), [.project, .ancestor])
    }

    func testAUserInvocableFalseSkillIsNotOfferedAfterASlashButTheModelHasIt() async throws {
        let project = try tempProject()
        try write("---\ndescription: bg\nuser-invocable: false\n---\nb", project, ".claude/skills/background/SKILL.md")
        try write("---\ndescription: fg\n---\nb", project, ".claude/skills/foreground/SKILL.md")
        let (controller, client, _, _) = makeController(turns: [.text("ok")], root: project)
        let rows = controller.suggestions(for: .slash(query: "", range: NSRange(location: 0, length: 1)))
        XCTAssertTrue(rows.contains { $0.title == "/foreground" } && !rows.contains { $0.title == "/background" })
        let mentions = controller.suggestions(for: .mention(query: "skill", range: NSRange(location: 0, length: 6)))
        XCTAssertTrue(mentions.contains { $0.title == "@skill:foreground" } && !mentions.contains { $0.title == "@skill:background" })

        await say(controller, "hello")
        let tool = try XCTUnwrap(try XCTUnwrap(client.requests.first).tools.first { $0.name == "skill" })
        XCTAssertTrue(tool.description.contains("- background:") && tool.description.contains("- foreground:"))
    }

    func testADisableModelInvocationSkillIsForTheUserOnly() async throws {
        let project = try tempProject()
        try write("---\ndescription: manual\ndisable-model-invocation: true\n---\nb", project, ".claude/skills/manual/SKILL.md")
        let (controller, client, _, _) = makeController(turns: [.text("ok")], root: project)
        XCTAssertTrue(controller.suggestions(for: .slash(query: "", range: NSRange(location: 0, length: 1))).contains { $0.title == "/manual" })
        await say(controller, "hello")
        XCTAssertFalse(try XCTUnwrap(client.requests.first).tools.map(\.name).contains("skill"), "the only skill is not the model's, so no tool")
    }

    func testSwitchingASkillOffHidesItEverywhereAndStartsANewSession() async throws {
        let project = try tempProject()
        try write("---\ndescription: one\n---\nb", project, ".claude/skills/one/SKILL.md")
        try write("---\ndescription: two\n---\nb", project, ".claude/skills/two/SKILL.md")
        let (controller, client, _, settings) = makeController(turns: [.text("a"), .text("b")], root: project)
        await say(controller, "first")
        let session = try XCTUnwrap(controller.currentSessionForTesting)
        XCTAssertTrue(try XCTUnwrap(client.requests.last).tools.first { $0.name == "skill" }?.description.contains("- two:") == true)

        settings.setSkill("Two", enabled: false)
        XCTAssertFalse(settings.isSkillEnabled("two"))
        controller.commandCatalog.invalidate()
        XCTAssertFalse(controller.suggestions(for: .slash(query: "", range: NSRange(location: 0, length: 1))).contains { $0.title == "/two" })
        XCTAssertEqual(controller.commandCatalog.allSkillsCatalog.skills.map(\.name), ["one", "two"], "Settings still lists it, to switch it back on")
        await say(controller, "second")
        XCTAssertFalse(controller.currentSessionForTesting === session, "the model's skill list changed")
        let description = try XCTUnwrap(try XCTUnwrap(client.requests.last).tools.first { $0.name == "skill" }).description
        XCTAssertTrue(description.contains("- one:") && !description.contains("- two:"))

        settings.setSkill("two", enabled: true)
        XCTAssertTrue(settings.disabledSkills.isEmpty)
    }

    func testSwitchedOffSkillsAreRememberedAcrossLaunches() {
        let defaults = UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!
        let first = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        first.setSkill("Review", enabled: false)
        let second = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        XCTAssertFalse(second.isSkillEnabled("review"))
        XCTAssertTrue(second.isSkillEnabled("other"))
    }

    // MARK: - The consent logic on its own

    func testConsentStatesAndTheQuestionIsAskedOnlyForAnUnansweredRepositorySkill() async {
        let defaults = UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!
        let trust = IDEAgentSkillTrust(defaults: defaults)
        let tools = ["Bash(echo:*)"]
        let fingerprint = IDEAgentSkillTrust.fingerprint(kind: "skill", name: "x", source: ".claude/skills", tools: tools, body: "b")
        XCTAssertEqual(IDEAgentSkillConsent.state(scope: .user, tools: tools, fingerprint: fingerprint, trust: trust), .notNeeded)
        XCTAssertEqual(IDEAgentSkillConsent.state(scope: .app, tools: tools, fingerprint: fingerprint, trust: trust), .notNeeded)
        XCTAssertEqual(IDEAgentSkillConsent.state(scope: .project, tools: [], fingerprint: fingerprint, trust: trust), .notNeeded)
        XCTAssertEqual(IDEAgentSkillConsent.state(scope: .ancestor, tools: tools, fingerprint: fingerprint, trust: trust), .unknown)

        var asked = 0
        let no = await IDEAgentSkillConsent.allowedTools(
            state: .unknown, fingerprint: fingerprint, tools: tools, trust: trust, confirm: { asked += 1; return false })
        XCTAssertEqual(no.tools, []); XCTAssertTrue(no.declined); XCTAssertEqual(asked, 1)
        XCTAssertEqual(IDEAgentSkillConsent.state(scope: .project, tools: tools, fingerprint: fingerprint, trust: trust), .declined)

        trust.trust(fingerprint)
        XCTAssertEqual(IDEAgentSkillConsent.state(scope: .project, tools: tools, fingerprint: fingerprint, trust: trust), .trusted)
        XCTAssertFalse(trust.isDeclined(fingerprint), "a yes replaces an earlier no")

        let reloaded = IDEAgentSkillTrust(defaults: defaults)
        XCTAssertTrue(reloaded.isTrusted(fingerprint), "kept across launches")
        reloaded.forget(fingerprint)
        XCTAssertFalse(reloaded.isTrusted(fingerprint) || reloaded.isDeclined(fingerprint))
    }

    func testTheFingerprintFollowsWhatTheUserWasShown() {
        let base = IDEAgentSkillTrust.fingerprint(kind: "skill", name: "x", source: "s", tools: ["a", "b"], body: "text")
        XCTAssertEqual(base, IDEAgentSkillTrust.fingerprint(kind: "skill", name: "X", source: "s", tools: ["b", "a"], body: "text"), "case and tool order do not matter")
        for changed in [
            IDEAgentSkillTrust.fingerprint(kind: "command", name: "x", source: "s", tools: ["a", "b"], body: "text"),
            IDEAgentSkillTrust.fingerprint(kind: "skill", name: "y", source: "s", tools: ["a", "b"], body: "text"),
            IDEAgentSkillTrust.fingerprint(kind: "skill", name: "x", source: "t", tools: ["a", "b"], body: "text"),
            IDEAgentSkillTrust.fingerprint(kind: "skill", name: "x", source: "s", tools: ["a"], body: "text"),
            IDEAgentSkillTrust.fingerprint(kind: "skill", name: "x", source: "s", tools: ["a", "b"], body: "text!"),
        ] {
            XCTAssertNotEqual(changed, base)
        }
    }

    func testSettingsRowsNameWhatNeedsAttention() {
        let plain = Skill(name: "p", description: "d", body: "b", directory: URL(fileURLWithPath: "/tmp/p"))
        XCTAssertEqual(IDEAgentSkillsSection.badges(for: plain), [])
        let odd = Skill(
            name: "o", description: "d", body: "b", directory: URL(fileURLWithPath: "/tmp/o"), paths: ["**/*.java"],
            modelInvocable: false, userInvocable: false)
        XCTAssertEqual(IDEAgentSkillsSection.badges(for: odd), ["Only you", "Only the agent", "Conditional"])
        let catalog = SkillCatalog(diagnostics: [
            SkillDiagnostic(kind: .warning, path: "/a/SKILL.md", skillName: "a", message: "Shadowed by the skill of the same name in .claude/skills, which is read first."),
            SkillDiagnostic(kind: .skipped, path: "/b/SKILL.md", message: "Not loaded: x"),
        ])
        XCTAssertEqual(IDEAgentSkillsSection.problems(in: catalog).map(\.path), ["/b/SKILL.md"], "shadowing has a group of its own")
    }
}
