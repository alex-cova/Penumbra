import Foundation
import Testing
@testable import AgentKit

// MARK: - Helpers

private func taskCall(
    _ agent: String = "general", prompt: String = "do it", background: Bool = false, session: String? = nil, id: String = "t1"
) -> MockTurn {
    var arguments = #"{"agent":"\#(agent)","description":"a job","prompt":"\#(prompt)""#
    if background { arguments += #","background":true"# }
    if let session { arguments += #","session":"\#(session)""# }
    arguments += "}"
    return .toolCalls((id: id, name: "task", arguments: arguments))
}

private func writeCall(_ path: String, _ text: String, id: String = "w1") -> MockTurn {
    .toolCalls((id: id, name: "write_file", arguments: #"{"path":"\#(path)","content":"\#(text)"}"#))
}

private func makeParent(
    _ parent: any LLMClient, child: MockLLMClient, project: TempProject, mode: PermissionMode = .acceptEdits,
    catalog: AgentCatalog = .builtIn, permissions: PermissionRules = PermissionRules(),
    approval: ApprovalPolicy = .approveAll
) -> AgentSession {
    AgentSession(
        client: parent,
        tools: ReadOnlyTools.all() + EditingTools.all() + [TaskTool(catalog: catalog, childClient: child)],
        workspace: project.workspace,
        configuration: AgentConfiguration(model: "m", approval: approval, mode: mode, permissions: permissions))
}

/// A parent whose next turn is chosen from what it has been told so far, for scripts that depend on
/// ids the session makes up.
private final class ReactiveClient: LLMClient, @unchecked Sendable {
    let providerID = "mock"
    let supportsDisabledToolChoice = false
    private let react: @Sendable (LLMRequest) -> MockTurn
    private let lock = NSLock()
    private var seen: [LLMRequest] = []

    init(_ react: @escaping @Sendable (LLMRequest) -> MockTurn) { self.react = react }

    var requests: [LLMRequest] { lock.withLock { seen } }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        lock.withLock { seen.append(request) }
        return MockLLMClient(turns: [react(request)]).stream(request)
    }
}

private func outputs(_ request: LLMRequest) -> [String] {
    request.items.compactMap { if case .toolOutput(_, let text) = $0 { text } else { nil } }
}

private func notes(_ request: LLMRequest) -> [String] {
    request.items.compactMap {
        if case .user(let text) = $0, text.hasPrefix(UntrustedContent.editorNotePrefix) { text } else { nil }
    }
}

private func run(_ agent: AgentSession, _ text: String = "go") async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in await agent.send(text) { events.append(event) }
    return events
}

private func ending(_ events: [AgentEvent]) -> RunEnding? {
    for case .runEnded(let value) in events { return value }
    return nil
}

private func runID(_ events: [AgentEvent]) -> RunID? {
    for case .runStarted(let id) in events { return id }
    return nil
}

private func output(_ events: [AgentEvent], call: String = "t1") -> ToolOutput? {
    for case .toolCallFinished(let id, _, let result) in events where id == call { return result }
    return nil
}

private func toolNames(_ request: LLMRequest) -> Set<String> { Set(request.tools.map(\.name)) }

private func disk(_ project: TempProject, _ path: String) -> String? {
    try? String(contentsOf: project.root.appendingPathComponent(path), encoding: .utf8)
}

private func sessionID(in text: String) -> String? {
    guard let range = text.range(of: #"session (sub-[0-9a-f]+)"#, options: .regularExpression) else { return nil }
    return String(text[range].dropFirst("session ".count))
}

// MARK: - Definitions

@Suite struct AgentDefinitionTests {
    @Test func aFileBecomesADefinitionWithItsFields() throws {
        let agent = try #require(AgentDefinition.parse(
            fileName: "reviewer.md",
            contents: """
            ---
            description: Reviews a diff for bugs
            tools: [read_file, grep]
            mode: read-only
            max-iterations: 12
            ---
            Report only real defects.
            """, source: ".umbra/agents"))
        #expect(agent.name == "reviewer")
        #expect(agent.description == "Reviews a diff for bugs")
        #expect(agent.tools == ["read_file", "grep"])
        #expect(!agent.editsFiles)
        #expect(agent.maxIterations == 12)
        #expect(agent.instructions == "Report only real defects.")
    }

    @Test func editingIsOptInAndTheDescriptionFallsBackToTheFirstLine() throws {
        let plain = try #require(AgentDefinition.parse(fileName: "a.md", contents: "Just do it well.", source: ""))
        #expect(!plain.editsFiles)
        #expect(plain.description == "Just do it well.")
        let writer = try #require(AgentDefinition.parse(fileName: "w.md", contents: "---\nmode: edit\n---\nbody", source: ""))
        #expect(writer.editsFiles)
        #expect(writer.maxIterations == 25)
    }

    @Test func theCatalogKeepsEarlierFoldersAndAlwaysHasGeneral() throws {
        let project = try TempProject(files: [
            "project/reviewer.md": "---\ndescription: project one\n---\nA",
            "user/reviewer.md": "---\ndescription: user one\n---\nB",
            "user/general.md": "---\ndescription: my general\nmode: edit\n---\nC",
            "user/notes.txt": "ignored",
        ])
        let catalog = AgentCatalog.load(folders: [
            SkillCatalog.Location(url: project.root.appendingPathComponent("project"), label: "project"),
            SkillCatalog.Location(url: project.root.appendingPathComponent("user"), label: "user"),
        ])
        #expect(catalog.agents.map(\.name) == ["general", "reviewer"])
        #expect(catalog.agent(named: "reviewer")?.description == "project one")
        #expect(catalog.agent(named: "general")?.description == "my general", "a file replaces the built-in")
        #expect(AgentCatalog.builtIn.agent(named: "general") != nil)
        #expect(catalog.fingerprint != AgentCatalog.builtIn.fingerprint)
        #expect(AgentCatalog.builtIn.fingerprint == AgentCatalog().fingerprint)
    }
}

// MARK: - Foreground

@Suite struct TaskToolTests {
    @Test func aReadOnlyChildReportsBackAndCannotSeeTheEditTools() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let child = MockLLMClient(turns: [.text("found it in A.txt:1")])
        let catalog = AgentCatalog(agents: [AgentDefinition(name: "scout", description: "looks")])
        let parent = MockLLMClient(turns: [taskCall("scout"), .text("thanks")])
        let events = await run(makeParent(parent, child: child, project: project, catalog: catalog))

        let result = try #require(output(events))
        #expect(!result.isError)
        #expect(result.text.contains("found it in A.txt:1"))
        #expect(result.text.contains("<untrusted"))
        #expect(sessionID(in: result.text) != nil)
        let seen = toolNames(child.requests[0])
        #expect(seen.contains("read_file") && seen.contains("grep"))
        #expect(!seen.contains("write_file") && !seen.contains("edit_file") && !seen.contains("task") && !seen.contains("explore"))
        #expect(ending(events) == .completed)
    }

    @Test func aGeneralChildChangesFilesAndRevertRunCoversThem() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let child = MockLLMClient(turns: [writeCall("Made.txt", "made by the child"), .text("created Made.txt")])
        let parent = MockLLMClient(turns: [taskCall(), .text("done")])
        let session = makeParent(parent, child: child, project: project)
        let events = await run(session)

        #expect(output(events)?.text.contains("created Made.txt") == true)
        #expect(disk(project, "Made.txt") == "made by the child")
        let id = try #require(runID(events))
        #expect(await session.checkpoints.changes(in: id).map(\.path) == ["Made.txt"], "filed under the parent's run")
        let report = try await session.revertRun(id)
        #expect(report.isComplete)
        #expect(disk(project, "Made.txt") == nil)
    }

    @Test func anEditingChildKeepsCommandsAndQuestionsButNeverAnotherTask() async throws {
        struct Shell: AgentTool {
            var risk: ToolRisk { .command }
            var definition: ToolDefinition { ToolDefinition(name: "run_command", description: "x") }
            func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String { "ran" }
        }
        let project = try TempProject()
        let child = MockLLMClient(turns: [.text("ok")])
        let parent = MockLLMClient(turns: [taskCall(), .text("done")])
        let session = AgentSession(
            client: parent,
            tools: ReadOnlyTools.all() + EditingTools.all() + [Shell(), AskUserTool(), TaskTool(childClient: child)],
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "m", approval: .approveAll))
        _ = await run(session)
        let seen = toolNames(child.requests[0])
        #expect(seen.contains("run_command") && seen.contains("ask_user"), "commands ask through the parent, questions reach the user")
        #expect(!seen.contains("task") && !seen.contains("explore") && !seen.contains("todo") && !seen.contains("remember"))
        #expect(seen.contains("write_file"))
    }

    @Test func aReadOnlyChildStaysReadOnly() async throws {
        struct Shell: AgentTool {
            var risk: ToolRisk { .command }
            var definition: ToolDefinition { ToolDefinition(name: "run_command", description: "x") }
            func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String { "ran" }
        }
        let project = try TempProject()
        let child = MockLLMClient(turns: [.text("ok")])
        let parent = MockLLMClient(turns: [taskCall("scout"), .text("done")])
        let catalog = AgentCatalog(agents: [AgentDefinition(name: "scout", description: "looks")])
        let session = AgentSession(
            client: parent,
            tools: ReadOnlyTools.all() + EditingTools.all() + [Shell(), AskUserTool(), TaskTool(catalog: catalog, childClient: child)],
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "m", approval: .approveAll))
        _ = await run(session)
        let seen = toolNames(child.requests[0])
        #expect(!seen.contains("run_command") && !seen.contains("write_file"))
        #expect(seen.contains("read_file"))
    }

    @Test func anEditingChildRunsWhereTheUserApprovesEachEdit() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let child = MockLLMClient(turns: [writeCall("Made.txt", "made by the child"), .text("created Made.txt")])
        let parent = MockLLMClient(turns: [taskCall(), .text("ok")])
        let session = makeParent(parent, child: child, project: project, mode: .manual, approval: .approveAll)
        let events = await run(session)
        #expect(output(events)?.text.contains("created Made.txt") == true, "its edits ask through the parent instead of being refused")
        #expect(disk(project, "Made.txt") == "made by the child")
        #expect(ending(events) == .completed)
    }

    @Test func planModeDoesNotOfferTask() async throws {
        let project = try TempProject()
        let parent = MockLLMClient(turns: [.text("plan")])
        _ = await run(makeParent(parent, child: MockLLMClient(turns: []), project: project, mode: .plan))
        #expect(!toolNames(parent.requests[0]).contains("task"))
        #expect(toolNames(parent.requests[0]).contains("read_file"))
    }

    @Test func anUnknownAgentNamesTheOnesThatExist() async throws {
        let project = try TempProject()
        let parent = MockLLMClient(turns: [taskCall("nobody"), .text("ok")])
        let events = await run(makeParent(parent, child: MockLLMClient(turns: []), project: project))
        let result = try #require(output(events))
        #expect(result.isError)
        #expect(result.text.contains("general"))
    }

    @Test func aClaimsGateAsksAboutAChildsEdit() async throws {
        struct ClaimsGate: PermissionGate {
            func verdict(for call: ToolCallInfo) async -> PermissionVerdict? {
                guard call.risk == .edit, call.name != "task" else { return nil }
                return .ask(notes: ["Chat 'Refactor' is changing this file in its current run."])
            }
        }
        let project = try TempProject(files: ["A.txt": "x"])
        let child = MockLLMClient(turns: [writeCall("Made.txt", "made by the child"), .text("tried to write it")])
        let parent = MockLLMClient(turns: [taskCall(), .text("done")])
        let session = AgentSession(
            client: parent,
            tools: ReadOnlyTools.all() + EditingTools.all() + [TaskTool(childClient: child)],
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "m", approval: .askForCommands, gate: ClaimsGate()))
        var events: [AgentEvent] = []
        var denied = false
        for await event in await session.send("go") {
            events.append(event)
            if case .subagent(_, let inner) = event, case .approvalRequested(let request) = inner, !denied {
                denied = true
                await session.resolveApproval(callID: request.callID, decision: .deny(note: nil))
            }
        }
        let asked = events.compactMap { event -> ApprovalRequest? in
            if case .subagent(_, let inner) = event, case .approvalRequested(let request) = inner { return request }
            return nil
        }
        #expect(asked.count == 1)
        #expect(asked.first?.notes == ["Chat 'Refactor' is changing this file in its current run."])
        #expect(disk(project, "Made.txt") == nil, "the refused edit never lands")
        #expect(ending(events) == .completed)
    }

    @Test func aChildsEditCarriesTheHostsAfterEditNote() async throws {
        let project = try TempProject()
        let child = MockLLMClient(turns: [writeCall("Kid.txt", "hi", id: "w1"), .text("wrote it")])
        let parent = MockLLMClient(turns: [taskCall(), .text("done")])
        let session = AgentSession(
            client: parent,
            tools: ReadOnlyTools.all() + EditingTools.all() + [TaskTool(childClient: child)],
            workspace: project.workspace,
            configuration: AgentConfiguration(
                model: "m", approval: .approveAll, afterEdit: { _ in "Problems after this edit: none" }))
        _ = await run(session)
        // The live `.toolCallFinished` was already sent, so the note only reaches the child's
        // next request, as the model's tool output.
        let seen = outputs(child.requests[1])
        #expect(seen.contains { $0.contains("Problems after this edit: none") })
        #expect(disk(project, "Kid.txt") == "hi")
    }

    @Test func aChildRequestCarriesTheParentsCacheKey() async throws {
        let project = try TempProject()
        let child = MockLLMClient(turns: [.text("report")])
        let parent = MockLLMClient(turns: [taskCall(), .text("done")])
        _ = await run(AgentSession(
            client: parent,
            tools: ReadOnlyTools.all() + EditingTools.all() + [TaskTool(childClient: child)],
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "m", cacheKey: "parent-key", approval: .approveAll)))
        #expect(child.requests[0].cacheKey == "parent-key")
    }
}

@Suite struct TaskToolContinueTests {
    @Test func aChildIsContinuedByItsSessionIdAndKeepsItsConversation() async throws {
        let project = try TempProject()
        let child = MockLLMClient(turns: [.text("first report"), .text("second report")])
        let catalog = AgentCatalog(agents: [AgentDefinition(name: "scout", description: "looks")])
        let parent = ReactiveClient { request in
            let seen = outputs(request)
            switch seen.count {
            case 0: return taskCall("scout", prompt: "look")
            case 1:
                let id = sessionID(in: seen[0]) ?? "missing"
                return taskCall("scout", prompt: "and more", session: id, id: "t2")
            default: return .text("done")
            }
        }
        let events = await run(makeParent(parent, child: child, project: project, catalog: catalog))
        #expect(output(events, call: "t2")?.text.contains("second report") == true)
        #expect(child.requests.count == 2)
        // The second request carries the first exchange, so the child remembers what it did.
        #expect(child.requests[1].items.count > child.requests[0].items.count)
        #expect(sessionID(in: output(events, call: "t1")?.text ?? "") == sessionID(in: output(events, call: "t2")?.text ?? ""))
    }

    @Test func anUnknownSessionAndTheWrongAgentAreRefused() async throws {
        let project = try TempProject()
        let child = MockLLMClient(turns: [.text("report")])
        let catalog = AgentCatalog(agents: [AgentDefinition(name: "scout", description: "looks")])
        let parent = ReactiveClient { request in
            let seen = outputs(request)
            switch seen.count {
            case 0: return taskCall("scout", prompt: "look")
            case 1: return taskCall("scout", prompt: "x", session: "sub-nope", id: "t2")
            case 2: return taskCall("general", prompt: "x", session: sessionID(in: seen[0]) ?? "missing", id: "t3")
            default: return .text("done")
            }
        }
        let events = await run(makeParent(parent, child: child, project: project, catalog: catalog))
        #expect(output(events, call: "t2")?.text.contains("No subagent with session sub-nope") == true)
        #expect(output(events, call: "t3")?.text.contains("belongs to agent scout") == true)
    }

    @Test func theChildsTokensJoinTheRunsBudget() async throws {
        let project = try TempProject()
        let child = MockLLMClient(turns: [
            MockTurn([.textDelta("r"), .usage(TokenUsage(inputTokens: 100, outputTokens: 7)), .finished(.completed)]),
        ])
        let parent = MockLLMClient(turns: [taskCall(), .text("ok")])
        let session = makeParent(parent, child: child, project: project)
        _ = await run(session)
        let usage = await session.totalUsage
        #expect(usage.inputTokens == 100 && usage.outputTokens == 7)
    }

    @Test func anApprovalAChildRaisesReachesTheHostAndResolves() async throws {
        let project = try TempProject()
        let rules = PermissionRules(ask: [PermissionRule(tool: "Edit", pattern: "secret/**")])
        let child = MockLLMClient(turns: [writeCall("secret/x.txt", "ok"), .text("wrote it")])
        let parent = MockLLMClient(turns: [taskCall(), .text("ok")])
        let session = makeParent(parent, child: child, project: project, permissions: rules, approval: .askForCommands)
        var events: [AgentEvent] = []
        var approved = false
        for await event in await session.send("go") {
            events.append(event)
            if case .subagent(_, let inner) = event, case .approvalRequested(let request) = inner, !approved {
                approved = true
                await session.resolveApproval(callID: request.callID, decision: .approve)
            }
        }
        #expect(approved, "the child's approval reaches the host wrapped as .subagent")
        #expect(disk(project, "secret/x.txt") == "ok")
        #expect(ending(events) == .completed)
    }

    /// A child must not be a way round the user's mode: in Manual every edit asks, a child's included.
    /// (`anEditingChildRunsWhereTheUserApprovesEachEdit` runs under `.approveAll`, which skips the
    /// policy altogether, so it cannot see this.)
    @Test func aManualParentMakesAnEditingChildsEditsAsk() async throws {
        let project = try TempProject()
        let child = MockLLMClient(turns: [writeCall("Made.txt", "by the child"), .text("wrote it")])
        let parent = MockLLMClient(turns: [taskCall(), .text("ok")])
        let session = makeParent(parent, child: child, project: project, mode: .manual, approval: .askForCommands)
        var asked = false
        var landedBeforeAnswer = false
        for await event in await session.send("go") {
            if case .subagent(_, let inner) = event, case .approvalRequested(let request) = inner, !asked {
                asked = true
                landedBeforeAnswer = disk(project, "Made.txt") != nil
                await session.resolveApproval(callID: request.callID, decision: .deny(note: nil))
            }
        }
        #expect(asked, "Manual asks about the child's edit like any other")
        #expect(!landedBeforeAnswer)
        #expect(disk(project, "Made.txt") == nil, "denied, so it never lands")
    }

    /// Switching the chat to Manual after a child exists reaches that child when it is continued.
    @Test func aChildContinuedAfterSwitchingToManualAsksAboutItsEdits() async throws {
        let project = try TempProject()
        let child = MockLLMClient(turns: [.text("first report"), writeCall("Late.txt", "late"), .text("wrote it")])
        let parent = ReactiveClient { request in
            let seen = outputs(request)
            switch seen.count {
            case 0: return taskCall()
            case 1:
                // The mode change adds an editor note after the message, so look past the last item.
                if request.items.contains(where: { if case .user("again") = $0 { true } else { false } }) { return taskCall(session: sessionID(in: seen[0]) ?? "missing", id: "t2") }
                return .text("done")
            default: return .text("done")
            }
        }
        let session = makeParent(parent, child: child, project: project, mode: .acceptEdits, approval: .askForCommands)
        _ = await run(session)
        await session.setMode(.manual)
        // The forward is a detached task; give it the moment it needs before the child runs again.
        try await Task.sleep(for: .milliseconds(50))
        var asked = false
        for await event in await session.send("again") {
            if case .subagent(_, let inner) = event, case .approvalRequested(let request) = inner, !asked {
                asked = true
                await session.resolveApproval(callID: request.callID, decision: .deny(note: nil))
            }
        }
        #expect(asked, "the continued child follows Manual")
        #expect(disk(project, "Late.txt") == nil)
    }

    @Test func denyingAChildsApprovalStopsOnlyThatCall() async throws {
        let project = try TempProject()
        let rules = PermissionRules(ask: [PermissionRule(tool: "Edit", pattern: "secret/**")])
        let child = MockLLMClient(turns: [writeCall("secret/x.txt", "nope"), .text("could not write it")])
        let parent = MockLLMClient(turns: [taskCall(), .text("ok")])
        let session = makeParent(parent, child: child, project: project, permissions: rules, approval: .askForCommands)
        var events: [AgentEvent] = []
        var denied = false
        for await event in await session.send("go") {
            events.append(event)
            if case .subagent(_, let inner) = event, case .approvalRequested(let request) = inner, !denied {
                denied = true
                await session.resolveApproval(callID: request.callID, decision: .deny(note: nil))
            }
        }
        #expect(denied)
        #expect(disk(project, "secret/x.txt") == nil, "the refused edit never lands")
        #expect(ending(events) == .completed)
    }

    @Test func aQuestionAChildAsksIsAnsweredThroughTheParent() async throws {
        let project = try TempProject()
        let child = MockLLMClient(turns: [
            .toolCalls((id: "q1", name: "ask_user", arguments: #"{"question":"Favorite color?"}"#)),
            .text("done"),
        ])
        let parent = MockLLMClient(turns: [taskCall("scout"), .text("ok")])
        let catalog = AgentCatalog(agents: [AgentDefinition(name: "scout", description: "looks")])
        let session = AgentSession(
            client: parent,
            tools: ReadOnlyTools.all() + [AskUserTool(), TaskTool(catalog: catalog, childClient: child)],
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "m", approval: .approveAll))
        var events: [AgentEvent] = []
        var answered = false
        for await event in await session.send("go") {
            events.append(event)
            if case .subagent(_, let inner) = event, case .questionAsked(let question) = inner, !answered {
                answered = true
                await session.answerQuestion(callID: question.callID, answer: "blue")
            }
        }
        #expect(answered, "the child's question reaches the host wrapped as .subagent")
        #expect(outputs(child.requests[1]).contains { $0.contains("blue") })
        #expect(ending(events) == .completed)
    }
}

@Suite struct TaskToolRoutingTests {
    @Test func twoReadOnlyChildrenAndOneEditingChildRunInOneTurn() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let child = MockLLMClient(turns: [.text("scout one saw it"), .text("scout two saw it"), .text("editing child done")])
        let catalog = AgentCatalog(agents: [
            AgentDefinition(name: "scout", description: "looks"),
            AgentDefinition(name: "scout2", description: "looks again"),
        ])
        let parent = MockLLMClient(turns: [
            .toolCalls(
                (id: "t1", name: "task", arguments: #"{"agent":"scout","description":"first look","prompt":"look"}"#),
                (id: "t2", name: "task", arguments: #"{"agent":"scout2","description":"second look","prompt":"look again"}"#),
                (id: "t3", name: "task", arguments: #"{"agent":"general","description":"make it","prompt":"do it"}"#)),
            .text("done"),
        ])
        let session = makeParent(parent, child: child, project: project, catalog: catalog)
        let events = await run(session)
        #expect(output(events, call: "t1")?.text.contains("scout one saw it") == true)
        #expect(output(events, call: "t2")?.text.contains("scout two saw it") == true)
        #expect(output(events, call: "t3")?.text.contains("editing child done") == true)
        #expect(ending(events) == .completed)
    }

    @Test func stopChildCancelsOneChildAndLeavesTheOthersRunning() async throws {
        let project = try TempProject()
        let catalog = AgentCatalog(agents: [AgentDefinition(name: "scout", description: "looks")])
        let child = MockLLMClient(turns: [
            MockTurn(
                [.textDelta("s"), .textDelta("l"), .textDelta("o"), .textDelta("w"), .finished(.completed)],
                delayPerEvent: .seconds(1)),
            .text("fast report"),
        ])
        let parent = ReactiveClient { request in
            if notes(request).contains(where: { $0.contains("finished in the background") }) { return .text("final answer") }
            switch outputs(request).count {
            case 0:
                return .toolCalls(
                    (id: "t1", name: "task", arguments: #"{"agent":"scout","description":"slow job","prompt":"take your time","background":true}"#),
                    (id: "t2", name: "task", arguments: #"{"agent":"scout","description":"fast job","prompt":"be quick","background":true}"#))
            default:
                return .text("waiting for them")
            }
        }
        let session = AgentSession(
            client: parent,
            tools: ReadOnlyTools.all() + EditingTools.all() + [TaskTool(catalog: catalog, childClient: child)],
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "m", approval: .approveAll))
        var events: [AgentEvent] = []
        var stopped: String? = nil
        for await event in await session.send("go") {
            events.append(event)
            if stopped == nil, case .toolCallFinished(let id, _, _) = event, id == "t1" {
                try? await Task.sleep(for: .milliseconds(300))
                let running = await session.runningChildCalls
                if let childID = running["t1"] {
                    await session.stopChild(id: childID)
                    stopped = childID
                }
            }
        }
        let stoppedID = try #require(stopped, "a background child was running to stop")
        #expect(ending(events) == .completed, "the parent and the other child carry on")
        let finishedIDs = events.compactMap { event -> String? in
            if case .subagentFinished(let id, _, _, _, _) = event { return id }
            return nil
        }
        #expect(!finishedIDs.contains(stoppedID), "the stopped child files no report")
        #expect(finishedIDs.count == 1, "the other child still reports")
        let infos = await session.childInfos
        #expect(infos.allSatisfy { !$0.isRunning })
    }

    @Test func aChildContinuesAfterASnapshotReload() async throws {
        let project = try TempProject()
        let catalog = AgentCatalog(agents: [AgentDefinition(name: "scout", description: "looks")])
        let child = MockLLMClient(turns: [.text("first report")])
        let parent = MockLLMClient(turns: [taskCall("scout", prompt: "look"), .text("done")])
        let first = AgentSession(
            client: parent,
            tools: ReadOnlyTools.all() + [TaskTool(catalog: catalog, childClient: child)],
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "m", approval: .approveAll))
        let firstEvents = await run(first, "go")
        let id = try #require(sessionID(in: output(firstEvents)?.text ?? ""))
        let snapshots = await first.childSnapshots()
        #expect(snapshots.count == 1 && snapshots[0].id == id)

        // A fresh session restores the child and continues it by session id on the shared client:
        // parent turn, the continued child's turn, the parent's closing turn.
        let shared = MockLLMClient(turns: [
            taskCall("scout", prompt: "and more", session: id, id: "t2"),
            .text("second report"),
            .text("done"),
        ])
        let second = AgentSession(
            client: shared,
            tools: ReadOnlyTools.all() + [TaskTool(catalog: catalog)],
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "m", approval: .approveAll))
        await second.restoreChildren(snapshots, catalog: catalog)
        #expect(await second.childInfos.map(\.id) == [id])
        let events = await run(second, "go")
        #expect(output(events, call: "t2")?.text.contains("second report") == true)
        // The continued request carries the first exchange, so the child remembers what it did.
        #expect(shared.requests[1].items.contains { if case .assistant(let text) = $0 { text.contains("first report") } else { false } })
        #expect(ending(events) == .completed)
    }
}

@Suite struct BackgroundTaskTests {
    private func slow(_ text: String, events: Int = 1, delay: Duration = .milliseconds(150)) -> MockLLMClient {
        MockLLMClient(turns: [MockTurn([.textDelta(text), .finished(.completed)], delayPerEvent: delay)])
    }

    @Test func aBackgroundChildReturnsAtOnceAndItsReportArrivesAsANote() async throws {
        let project = try TempProject()
        let parent = ReactiveClient { request in
            if notes(request).contains(where: { $0.contains("finished in the background") }) { return .text("final answer") }
            if outputs(request).isEmpty { return taskCall(background: true) }
            return .text("waiting for it")
        }
        let session = makeParent(parent, child: slow("the background report"), project: project)
        let events = await run(session)

        let started = try #require(output(events))
        #expect(started.text.contains("working in the background"))
        #expect(started.text.contains("Do not sleep, poll"))
        // The run did not end when the model stopped talking: it waited for the child, then went on.
        #expect(parent.requests.count == 3)
        let note = try #require(notes(parent.requests[2]).first { $0.contains("finished in the background") })
        #expect(note.contains("the background report"))
        #expect(note.contains("<untrusted"))
        let finishedAt = events.firstIndex { if case .subagentFinished = $0 { true } else { false } }
        let endedAt = events.firstIndex { if case .runEnded = $0 { true } else { false } }
        #expect(try #require(finishedAt) < (try #require(endedAt)))
        #expect(ending(events) == .completed)
    }

    @Test func aSecondChildThatChangesFilesIsRefusedWhileOneIsStillWriting() async throws {
        let project = try TempProject()
        let child = MockLLMClient(turns: [
            MockTurn([.textDelta("slow"), .finished(.completed)], delayPerEvent: .milliseconds(200)),
        ])
        let parent = ReactiveClient { request in
            if notes(request).contains(where: { $0.contains("finished in the background") }) { return .text("final") }
            switch outputs(request).count {
            case 0: return taskCall(background: true)
            case 1: return taskCall(prompt: "also", id: "t2")
            default: return .text("ok")
            }
        }
        let events = await run(makeParent(parent, child: child, project: project))
        let refused = try #require(output(events, call: "t2"))
        #expect(refused.isError)
        #expect(refused.text.contains("Another subagent that changes files is still running"))
        #expect(ending(events) == .completed)
    }

    @Test func stopEndsTheRunAndTheBackgroundChildAndNoReportLeaksIntoTheNextRun() async throws {
        let project = try TempProject()
        let child = MockLLMClient(turns: [
            MockTurn([.textDelta("a"), .textDelta("b"), .textDelta("c"), .finished(.completed)], delayPerEvent: .seconds(2)),
        ])
        let parent = ReactiveClient { request in
            outputs(request).isEmpty ? taskCall(background: true) : .text("waiting")
        }
        let session = makeParent(parent, child: child, project: project)
        var events: [AgentEvent] = []
        let started = Date()
        for await event in await session.send("go") {
            events.append(event)
            if case .toolCallFinished = event {
                try? await Task.sleep(for: .milliseconds(200))
                await session.stop()
            }
        }
        #expect(ending(events) == .stopped)
        #expect(Date().timeIntervalSince(started) < 3, "Stop did not wait for the child's slow turns")
        let items = await session.items
        #expect(!items.contains { if case .user(let text) = $0 { text.contains("finished in the background") } else { false } })
    }

    @Test func aBackgroundChildThatEditsIsRevertableWithTheRun() async throws {
        let project = try TempProject()
        let child = MockLLMClient(turns: [
            MockTurn([.toolCallStarted(id: "w1", name: "write_file"),
                      .toolCallFinished(id: "w1", name: "write_file", arguments: #"{"path":"Bg.txt","content":"bg"}"#),
                      .finished(.toolCalls)], delayPerEvent: .milliseconds(50)),
            .text("wrote Bg.txt"),
        ])
        let parent = ReactiveClient { request in
            if notes(request).contains(where: { $0.contains("finished in the background") }) { return .text("final") }
            return outputs(request).isEmpty ? taskCall(background: true) : .text("waiting")
        }
        let session = makeParent(parent, child: child, project: project)
        let events = await run(session)
        #expect(disk(project, "Bg.txt") == "bg")
        let id = try #require(runID(events))
        #expect(await session.checkpoints.changes(in: id).map(\.path) == ["Bg.txt"])
        #expect(try await session.revertRun(id).isComplete)
        #expect(disk(project, "Bg.txt") == nil)
    }
}
