import Foundation
import Testing
@testable import AgentKit

private struct EndpointCommandTool: AgentTool {
    let ran: ACPLocked<[String]>
    var risk: ToolRisk { .command }
    var definition: ToolDefinition {
        ToolDefinition(name: "run_command", description: "run", parameters: [ToolParameter("command", .string, "cmd")])
    }
    func approvalRequest(for arguments: ToolArguments, context: ToolContext) async -> ApprovalRequest? {
        ApprovalRequest(title: "Run command", command: (try? arguments.string("command")) ?? "")
    }
    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let command = try arguments.string("command")
        ran.mutate { $0.append(command) }
        return "ran: \(command)"
    }
}

/// Phase 2 verification: a second ACP client (`ACPClientSession`) drives `ACPAgentEndpoint`
/// over the in-memory pair — the same oracle shape as the fake-agent tests, reversed.
@Suite struct ACPAgentEndpointTests {
    private func rig(
        turns: [MockTurn], tools: [any AgentTool] = [], mode: PermissionMode = .acceptEdits,
        hostServices: ACPHostServices = ACPHostServices(),
        endpointStore: SessionStore? = nil,
        turnSource: ACPLocked<[MockTurn]>? = nil
    ) throws -> (client: ACPClientSession, endpoint: ACPAgentEndpoint, task: Task<Void, Never>, project: TempProject, created: ACPLocked<AgentSession?>, clients: ACPLocked<[MockLLMClient]>) {
        let project = try TempProject(files: ["a.txt": "hello"])
        let created = ACPLocked<AgentSession?>(nil)
        let clients = ACPLocked<[MockLLMClient]>([])
        let (clientTransport, agentTransport) = ACPInMemoryTransport.pair()
        let endpoint = ACPAgentEndpoint(transport: agentTransport, sessionStore: endpointStore) { request in
            let mock = MockLLMClient(turns: turnSource?.get() ?? turns)
            clients.mutate { $0.append(mock) }
            let session = AgentSession(
                client: mock, tools: tools,
                workspace: ACPRemoteWorkspace(local: project.workspace, remoteFileReader: request.remoteFileReader),
                configuration: AgentConfiguration(model: "mock", mode: mode),
                history: request.history, totalUsage: request.totalUsage,
                sessionID: request.sessionID ?? UUID())
            created.set(session)
            return session
        }
        let task = Task { await endpoint.run() }
        let client = ACPClientSession(transport: clientTransport, hostServices: hostServices, cwd: project.root.path)
        return (client, endpoint, task, project, created, clients)
    }

    @Test func updateMappingIsTheClientTableReversed() {
        #expect(ACPAgentEndpoint.update(for: .textDelta("hi"))?["sessionUpdate"]?.stringValue == "agent_message_chunk")
        #expect(ACPAgentEndpoint.update(for: .reasoningDelta("t"))?["sessionUpdate"]?.stringValue == "agent_thought_chunk")
        let finished = ACPAgentEndpoint.update(for: .toolCallFinished(id: "1", name: "x", output: ToolOutput("bad", isError: true)))
        #expect(finished?["status"]?.stringValue == "failed")
        #expect(ACPAgentEndpoint.update(for: .runEnded(.completed)) == nil)
        let plan = ACPAgentEndpoint.update(for: .todosUpdated([TodoItem("a", .inProgress)]))
        #expect(plan?["entries"]?.arrayValue?.first?["status"]?.stringValue == "in_progress")
    }

    @Test func textTurnFromASecondClient() async throws {
        let rig = try rig(turns: [.text("Hello from AgentKit")])
        defer { rig.task.cancel() }
        let events = await collectACP(await rig.client.send("hi"))
        let text = events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        #expect(text == "Hello from AgentKit")
        #expect(events.last == .runEnded(.completed))
        // Modes are Umbra's permission modes, agent-defined over ACP.
        #expect(await rig.client.modeState?.availableModes.map(\.id) == PermissionMode.allCases.map(\.rawValue))
        #expect(await rig.client.currentModeId == PermissionMode.acceptEdits.rawValue)
        #expect(await rig.endpoint.sessionIDs.count == 1)
        await rig.endpoint.stop()
    }

    @Test func approvalRoundTripsThroughRequestPermission() async throws {
        let ran = ACPLocked<[String]>([])
        let rig = try rig(
            turns: [
                .toolCalls((id: "c1", name: "run_command", arguments: #"{"command":"git status"}"#)),
                .text("done"),
            ],
            tools: [EndpointCommandTool(ran: ran)], mode: .manual)
        defer { rig.task.cancel() }
        var events: [AgentEvent] = []
        for await event in await rig.client.send("go") {
            events.append(event)
            if case .approvalRequested(let request) = event {
                await rig.client.resolveApproval(callID: request.callID, decision: .approve)
            }
        }
        #expect(ran.get() == ["git status"])
        #expect(events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined() == "done")
        #expect(events.last == .runEnded(.completed))
        await rig.endpoint.stop()
    }

    @Test func denialStopsTheTool() async throws {
        let ran = ACPLocked<[String]>([])
        let rig = try rig(
            turns: [
                .toolCalls((id: "c1", name: "run_command", arguments: #"{"command":"rm x"}"#)),
                .text("ok, skipped"),
            ],
            tools: [EndpointCommandTool(ran: ran)], mode: .manual)
        defer { rig.task.cancel() }
        for await event in await rig.client.send("go") {
            if case .approvalRequested(let request) = event {
                await rig.client.resolveApproval(callID: request.callID, decision: .deny(note: nil))
            }
        }
        #expect(ran.get().isEmpty)
        await rig.endpoint.stop()
    }

    @Test func setModeReachesTheSession() async throws {
        let rig = try rig(turns: [.text("x")])
        defer { rig.task.cancel() }
        _ = try await rig.client.newSession()
        try await rig.client.setAgentMode(PermissionMode.plan.rawValue)
        let session = try #require(rig.created.get())
        #expect(await session.currentMode == .plan)
        await rig.endpoint.stop()
    }

    @Test func cancelEndsThePromptAsCancelled() async throws {
        let slow = MockTurn([.textDelta("slow"), .finished(.completed)], delayPerEvent: .seconds(10))
        let rig = try rig(turns: [slow])
        defer { rig.task.cancel() }
        let collector = Task { await collectACP(await rig.client.send("go")) }
        try await Task.sleep(for: .milliseconds(200))
        await rig.client.stop()
        let events = await collector.value
        #expect(events.last == .runEnded(.stopped))
        await rig.endpoint.stop()
    }

    @Test func optionLessQuestionIsElicitedAsFreeText() async throws {
        let asked = ACPLocked<[String]>([])
        let rig = try rig(
            turns: [
                .toolCalls((id: "q1", name: "ask_user", arguments: #"{"question":"Pick a color"}"#)),
                .text("answered"),
            ],
            tools: [AskUserTool()],
            hostServices: ACPHostServices(askText: { prompt in
                asked.mutate { $0.append(prompt.title) }
                return "blue"
            }))
        defer { rig.task.cancel() }
        let events = await collectACP(await rig.client.send("go"))
        #expect(asked.get() == ["Pick a color"])
        #expect(events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined() == "answered")
        #expect(events.last == .runEnded(.completed))
        let toolOutput = try #require(rig.clients.get().first?.requests.last?.items.last)
        guard case .toolOutput(_, let output) = toolOutput else { Issue.record("expected the answer in the history"); return }
        #expect(output.contains("blue"))
        await rig.endpoint.stop()
    }

    @Test func declinedElicitationDismissesTheQuestion() async throws {
        let rig = try rig(
            turns: [
                .toolCalls((id: "q1", name: "ask_user", arguments: #"{"question":"Pick a color"}"#)),
                .text("skipped"),
            ],
            tools: [AskUserTool()],
            hostServices: ACPHostServices(askText: { _ in nil }))
        defer { rig.task.cancel() }
        let events = await collectACP(await rig.client.send("go"))
        #expect(events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined() == "skipped")
        #expect(events.last == .runEnded(.completed))
        await rig.endpoint.stop()
    }

    @Test func missingLocalFileReadsThroughToTheClient() async throws {
        let read = ACPLocked<[String]>([])
        let rig = try rig(
            turns: [
                .toolCalls((id: "r1", name: "read_file", arguments: #"{"path":"remote.txt"}"#)),
                .text("done"),
            ],
            tools: ReadOnlyTools.all(),
            hostServices: ACPHostServices(readTextFile: { request in
                read.mutate { $0.append(request.path) }
                return "content from the client"
            }))
        defer { rig.task.cancel() }
        // The endpoint workspace is local-only; wrap it so a local miss reads the client.
        let events = await collectACP(await rig.client.send("go"))
        #expect(events.last == .runEnded(.completed))
        #expect(read.get() == ["remote.txt"])
        let toolOutput = try #require(rig.clients.get().first?.requests.last?.items.last)
        guard case .toolOutput(_, let output) = toolOutput else { Issue.record("expected the remote text in the history"); return }
        #expect(output.contains("content from the client"))
        await rig.endpoint.stop()
    }

    @Test func sessionsSurviveARestartThroughTheStore() async throws {
        let storeDir = FileManager.default.temporaryDirectory.appendingPathComponent("acp-store-\(UUID().uuidString)", isDirectory: true)
        let store = SessionStore(directory: storeDir)
        let turns = ACPLocked([MockTurn.text("first answer"), MockTurn.text("second answer")])
        let clients = ACPLocked<[MockLLMClient]>([])
        let project = try TempProject(files: ["a.txt": "hello"])
        func textOf(_ events: [AgentEvent]) -> String {
            events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        }
        func makePair() -> (ACPClientSession, ACPAgentEndpoint, Task<Void, Never>) {
            let (clientTransport, agentTransport) = ACPInMemoryTransport.pair()
            let endpoint = ACPAgentEndpoint(transport: agentTransport, sessionStore: store) { request in
                let myTurns = Array(turns.get().prefix(1))
                turns.mutate { $0 = Array($0.dropFirst()) }
                let mock = MockLLMClient(turns: myTurns)
                clients.mutate { $0.append(mock) }
                return AgentSession(
                    client: mock, tools: [], workspace: project.workspace,
                    configuration: AgentConfiguration(model: "mock"),
                    history: request.history, totalUsage: request.totalUsage,
                    sessionID: request.sessionID ?? UUID())
            }
            return (ACPClientSession(transport: clientTransport, cwd: project.root.path), endpoint, Task { await endpoint.run() })
        }
        let first = makePair()
        let id = try await first.0.newSession()
        #expect(textOf(await collectACP(await first.0.send("first"))) == "first answer")
        await first.1.stop()
        first.2.cancel()
        let second = makePair()
        _ = try await second.0.loadSession(id: id)
        #expect(textOf(await collectACP(await second.0.send("second"))) == "second answer")
        // The restored session sent the earlier conversation to the model again.
        let historyTexts = clients.get()[1].requests.first?.items.compactMap { item -> String? in
            if case .user(let text) = item { text } else { nil }
        } ?? []
        #expect(historyTexts.contains("first"))
        await second.1.stop()
        second.2.cancel()
    }
}
