import Foundation
import Testing
@testable import AgentKit

final class ACPLocked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ newValue: T) { lock.withLock { value = newValue } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&value) } }
}

/// Scripted in-memory ACP agent: the same `ACPConnection` run in reverse (plan step 4).
/// It is the conformance oracle; no real agent, process, or network is involved.
final class FakeACPAgent: @unchecked Sendable {
    let connection: ACPConnection
    let transport: ACPInMemoryTransport
    var protocolVersion = 1
    var authMethodsJSON: [JSONValue] = []
    var requireAuth = false
    /// When set, `session/new` and `session/load` fail with `-32000` and this message.
    var sessionErrorMessage: String?
    var hangInitialize = false
    /// Codex ACP 2.6.0 answers `session/load` without `sessionId`. The client keeps the requested id.
    var omitSessionIdOnLoad = false
    let authenticated = ACPLocked(false)
    let cancelled = ACPLocked(false)
    let lastInitializeParams = ACPLocked<JSONValue?>(nil)
    let permissionOutcome = ACPLocked<JSONValue?>(nil)
    let fsError = ACPLocked<String?>(nil)
    let promptText = ACPLocked<String?>(nil)
    var onPrompt: @Sendable (FakeACPAgent, String) async -> String = { _, _ in "end_turn" }

    private init(transport: ACPInMemoryTransport) {
        self.transport = transport
        connection = ACPConnection(transport: transport)
    }

    static func make(transport: ACPInMemoryTransport) async -> FakeACPAgent {
        let agent = FakeACPAgent(transport: transport)
        let connection = agent.connection
        await connection.setNotificationHandler { method, _ in
            if method == "session/cancel" { agent.cancelled.set(true) }
        }
        await connection.setRequestHandler { method, params in
            await agent.handle(method: method, params: params)
        }
        await connection.start()
        return agent
    }

    func handle(method: String, params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        switch method {
        case "initialize":
            lastInitializeParams.set(params)
            if hangInitialize { try? await Task.sleep(for: .seconds(2)) }
            return .success(.object([
                "protocolVersion": .int(protocolVersion),
                "agentCapabilities": .object([
                    "loadSession": true,
                    "promptCapabilities": .object(["image": false, "audio": false, "embeddedContext": false]),
                ]),
                "agentInfo": .object(["name": "FakeAgent", "version": "1.0"]),
                "authMethods": .array(authMethodsJSON),
            ]))
        case "authenticate":
            authenticated.set(true)
            return .success(.object([:]))
        case "session/new", "session/load":
            if let sessionErrorMessage {
                return .failure(JSONRPCError(code: -32000, message: sessionErrorMessage))
            }
            if requireAuth, !authenticated.get() {
                return .failure(JSONRPCError(code: -32000, message: "Authentication required"))
            }
            if method == "session/load", omitSessionIdOnLoad {
                return .success(.object([
                    "modes": .object([
                        "currentModeId": "agent",
                        "availableModes": .array([.object(["id": "agent", "name": "Agent"])]),
                    ]),
                ]))
            }
            return .success(.object([
                "sessionId": .string(params?.string("sessionId") ?? "fake-session-1"),
                "modes": .object([
                    "currentModeId": "agent",
                    "availableModes": .array([
                        .object(["id": "agent", "name": "Agent"]),
                        .object(["id": "plan", "name": "Plan"]),
                    ]),
                ]),
                "configOptions": .array([
                    .object(["id": "model", "name": "Model", "type": "select", "currentValue": "fake-1"]),
                ]),
            ]))
        case "session/prompt":
            let text = params?["prompt"]?.arrayValue?.first.flatMap { ACPContentBlock(jsonValue: $0).textValue } ?? ""
            promptText.set(text)
            let reason = await onPrompt(self, text)
            return .success(.object(["stopReason": .string(reason)]))
        case "session/set_mode":
            return .success(.object([:]))
        default:
            return .failure(.methodNotFound(method))
        }
    }

    func emit(sessionId: String = "fake-session-1", update: JSONValue) async {
        try? await connection.notify(method: "session/update", params: .object([
            "sessionId": .string(sessionId), "update": update,
        ]))
    }

    func emitText(_ text: String, thought: Bool = false) async {
        await emit(update: .object([
            "sessionUpdate": thought ? "agent_thought_chunk" : "agent_message_chunk",
            "content": .object(["type": "text", "text": .string(text)]),
        ]))
    }

    func requestPermission() async -> JSONValue? {
        let result = try? await connection.request(method: "session/request_permission", params: .object([
            "sessionId": "fake-session-1",
            "toolCall": .object([
                "toolCallId": "perm-1", "title": "Run command",
                "rawInput": .object(["command": "git status"]),
            ]),
            "options": .array([
                .object(["optionId": "allow-once", "name": "Allow once", "kind": "allow_once"]),
                .object(["optionId": "allow-always", "name": "Always allow", "kind": "allow_always"]),
                .object(["optionId": "reject-once", "name": "Reject", "kind": "reject_once"]),
            ]),
        ]))
        permissionOutcome.set(result)
        return result
    }

    func createTerminal(command: String) async -> String? {
        let result = try? await connection.request(method: "terminal/create", params: .object([
            "sessionId": "fake-session-1", "command": .string(command), "args": .array([]),
        ]))
        return result?.string("terminalId")
    }

    func readFile(path: String) async -> String? {
        let result = try? await connection.request(method: "fs/read_text_file", params: .object([
            "sessionId": "fake-session-1", "path": .string(path),
        ]))
        return result?.string("content")
    }

    func writeFile(path: String, content: String) async -> Bool {
        do {
            _ = try await connection.request(method: "fs/write_text_file", params: .object([
                "sessionId": "fake-session-1", "path": .string(path), "content": .string(content),
            ]))
            return true
        } catch let error as ACPError {
            if case .agentError(let rpc) = error { fsError.set(rpc.message) }
            return false
        } catch { return false }
    }

    func crash() async { await transport.close() }
}

func collectACP(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in stream { events.append(event) }
    return events
}

func acpPair() -> (ACPInMemoryTransport, ACPInMemoryTransport) { ACPInMemoryTransport.pair() }

@Suite struct ACPJSONRPCTests {
    @Test func requestRoundTrip() throws {
        let message = JSONRPCMessage.request(id: .int(7), method: "session/prompt", params: .object(["sessionId": "s1"]))
        let parsed = try JSONRPCMessage(parsing: message.serialized())
        #expect(parsed == message)
    }

    @Test func notificationAndErrorParsing() throws {
        let note = try JSONRPCMessage(parsing: Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s"}}"#.utf8))
        guard case .notification(let method, _) = note else { Issue.record("expected notification"); return }
        #expect(method == "session/update")
        let error = try JSONRPCMessage(parsing: Data(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"nope"}}"#.utf8))
        guard case .error(let id, let rpc) = error else { Issue.record("expected error"); return }
        #expect(id == .int(3))
        #expect(rpc.code == -32601)
    }

    @Test func malformedFramesThrow() {
        #expect(throws: ACPError.self) { try JSONRPCMessage(parsing: Data("not json".utf8)) }
        #expect(throws: ACPError.self) { try JSONRPCMessage(parsing: Data(#"{"jsonrpc":"2.0"}"#.utf8)) }
    }

    @Test func unknownSessionUpdateIsTolerated() throws {
        let text = try fixtureText("ACP/session-update-sequence.json")
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 7)
        let updates = lines.map { ACPSessionUpdate(jsonValue: try! JSONValue(parsing: $0)) }
        guard case .unknown(let type, _) = updates[6] else { Issue.record("expected unknown"); return }
        #expect(type == "future_variant_xyz")
        guard case .agentMessageChunk(.text(let chunk)) = updates[0] else { Issue.record("expected text chunk"); return }
        #expect(chunk == "Hello ")
        guard case .plan(let entries) = updates[4] else { Issue.record("expected plan"); return }
        #expect(entries.first?.todoItem == TodoItem("Do the thing", .inProgress))
    }

    @Test func stopReasonMapping() {
        #expect(ACPStopReason(raw: "end_turn").runEnding == .completed)
        #expect(ACPStopReason(raw: "max_tokens").runEnding == .lengthLimit)
        #expect(ACPStopReason(raw: "max_turn_requests").runEnding == .iterationCap)
        #expect(ACPStopReason(raw: "refusal").runEnding == .contentFiltered)
        #expect(ACPStopReason(raw: "cancelled").runEnding == .stopped)
        #expect(ACPStopReason(raw: "something_new").runEnding == .completed)
    }
}

@Suite struct ACPConnectionTests {
    @Test func splitAndCoalescedFrames() async throws {
        let (clientTransport, peerTransport) = acpPair()
        let connection = ACPConnection(transport: clientTransport)
        await connection.start()
        let peer = Task {
            for await chunk in peerTransport.incoming {
                let text = String(decoding: chunk, as: UTF8.self)
                if text.contains("initialize") {
                    // One response split across three writes, then a second coalesced pair.
                    let response = #"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"# + "\n"
                    let bytes = Array(response.utf8)
                    peerTransport.sendRaw(Data(bytes[0..<10]))
                    peerTransport.sendRaw(Data(bytes[10..<25]))
                    peerTransport.sendRaw(Data(bytes[25...]))
                }
            }
        }
        defer { peer.cancel() }
        let result = try await connection.request(method: "initialize", params: .object([:]))
        #expect(result["ok"]?.boolValue == true)
        await connection.close()
    }

    @Test func clientSessionEndToEnd() async throws {
        let (clientTransport, agentTransport) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentTransport)
        agent.onPrompt = { agent, _ in
            await agent.emitText("thinking", thought: true)
            await agent.emitText("Hello ")
            await agent.emitText("world")
            await agent.emit(update: .object([
                "sessionUpdate": "tool_call", "toolCallId": "call-1", "title": "Read file", "name": "read_file",
                "kind": "read", "status": "pending", "rawInput": .object(["path": "README.md"]), "content": .array([]),
            ]))
            await agent.emit(update: .object([
                "sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": "completed",
                "content": .array([.object(["type": "content", "content": .object(["type": "text", "text": "contents"])])]),
            ]))
            await agent.emit(update: .object([
                "sessionUpdate": "plan",
                "entries": .array([.object(["content": "Do it", "priority": "high", "status": "in_progress"])]),
            ]))
            await agent.emit(update: .object(["sessionUpdate": "usage_update", "used": 42, "size": 1000]))
            await agent.emit(update: .object(["sessionUpdate": "future_variant_xyz"]))
            return "end_turn"
        }
        let session = ACPClientSession(transport: clientTransport, cwd: "/tmp/project")
        let events = await collectACP(await session.send("Hi"))
        #expect(events.first == .runStarted(events.compactMap { if case .runStarted(let id) = $0 { id } else { nil } }.first!))
        let text = events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        #expect(text == "Hello world")
        let reasoning = events.compactMap { if case .reasoningDelta(let t) = $0 { t } else { nil } }.joined()
        #expect(reasoning == "thinking")
        #expect(events.contains { if case .toolCallStarted(let id, _) = $0 { id == "call-1" } else { false } })
        #expect(events.contains { if case .toolCallFinished(let id, _, let output) = $0 { id == "call-1" && output.text == "contents" && !output.isError } else { false } })
        #expect(events.contains(.todosUpdated([TodoItem("Do it", .inProgress)])))
        #expect(events.contains(.usage(TokenUsage(inputTokens: 42, outputTokens: 0))))
        let endings = events.filter { if case .runEnded = $0 { true } else { false } }
        #expect(endings == [.runEnded(.completed)])
        #expect(events.last == .runEnded(.completed))
        #expect(await session.sessionId == "fake-session-1")
        #expect(await session.currentModeId == "agent")
        #expect(await session.configOptions.first?.id == "model")
        // Advertised capabilities strictly from host services: none provided here.
        let caps = agent.lastInitializeParams.get()?["clientCapabilities"]?["fs"]
        #expect(caps?["readTextFile"]?.boolValue == false)
        #expect(caps?["writeTextFile"]?.boolValue == false)
        #expect(agent.lastInitializeParams.get()?["clientCapabilities"]?["elicitation"] == nil)
    }

    @Test func elicitationAdvertisedOnlyWithAskText() async throws {
        let (clientTransport, agentTransport) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentTransport)
        let session = ACPClientSession(
            transport: clientTransport,
            hostServices: ACPHostServices(askText: { _ in nil }),
            cwd: "/tmp/project")
        _ = try? await session.newSession()
        let caps = agent.lastInitializeParams.get()?["clientCapabilities"]
        #expect(caps?["elicitation"]?["form"] != nil && caps?["elicitation"]?["form"] != .null)
    }

    @Test func handshakeRejectsNewerProtocol() async throws {
        let (clientTransport, agentTransport) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentTransport)
        agent.protocolVersion = 2
        let session = ACPClientSession(transport: clientTransport, cwd: "/tmp/project")
        await #expect(throws: ACPError.self) { try await session.connect() }
    }

    @Test func authenticateWhenAgentRequiresIt() async throws {
        let (clientTransport, agentTransport) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentTransport)
        agent.requireAuth = true
        agent.authMethodsJSON = [.object(["id": "fake-auth", "name": "Fake auth", "type": "agent"])]
        let session = ACPClientSession(transport: clientTransport, cwd: "/tmp/project")
        let id = try await session.newSession()
        #expect(id == "fake-session-1")
        #expect(agent.authenticated.get())
    }

    @Test func permissionApproveAndAllowAlways() async throws {
        let (clientTransport, agentTransport) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentTransport)
        agent.onPrompt = { agent, _ in
            let outcome = await agent.requestPermission()
            let option = outcome?["outcome"]?["optionId"]?.stringValue ?? "none"
            await agent.emitText("chose \(option)")
            return "end_turn"
        }
        let session = ACPClientSession(transport: clientTransport, cwd: "/tmp/project")
        var events: [AgentEvent] = []
        for await event in await session.send("run it") {
            events.append(event)
            if case .approvalRequested(let request) = event {
                await session.resolvePermission(callID: request.callID, optionId: "allow-always")
            }
        }
        #expect(agent.permissionOutcome.get()?["outcome"]?["optionId"]?.stringValue == "allow-always")
        #expect(events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined() == "chose allow-always")
        #expect(events.last == .runEnded(.completed))
        let rules = await session.permissionRules
        #expect(!rules.allow.isEmpty, "allow_always records a session rule")
    }

    @Test func permissionDenyViaApprovalDecision() async throws {
        let (clientTransport, agentTransport) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentTransport)
        agent.onPrompt = { agent, _ in _ = await agent.requestPermission(); return "end_turn" }
        let session = ACPClientSession(transport: clientTransport, cwd: "/tmp/project")
        for await event in await session.send("run it") {
            if case .approvalRequested(let request) = event {
                await session.resolveApproval(callID: request.callID, decision: .deny(note: "no"))
            }
        }
        let outcome = agent.permissionOutcome.get()
        #expect(outcome?["outcome"]?["outcome"]?.stringValue == "selected")
        #expect(outcome?["outcome"]?["optionId"]?.stringValue == "reject-once")
    }

    @Test func planModeAutoRejectsPermissionAndWrites() async throws {
        let (clientTransport, agentTransport) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentTransport)
        let written = ACPLocked(false)
        agent.onPrompt = { agent, _ in
            _ = await agent.requestPermission()
            written.set(await agent.writeFile(path: "/tmp/project/a.txt", content: "x"))
            return "end_turn"
        }
        let session = ACPClientSession(
            transport: clientTransport,
            hostServices: ACPHostServices(writeTextFile: { _ in }),
            cwd: "/tmp/project", mode: .plan)
        var sawApproval = false
        for await event in await session.send("run it") {
            if case .approvalRequested = event { sawApproval = true }
        }
        #expect(!sawApproval)
        #expect(agent.permissionOutcome.get()?["outcome"]?["optionId"]?.stringValue == "reject-once")
        #expect(!written.get())
        #expect(agent.fsError.get()?.contains("plan mode") == true)
    }

    @Test func fsReadWriteThroughHostServices() async throws {
        let (clientTransport, agentTransport) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentTransport)
        let store = ACPLocked<[String: String]>([:])
        agent.onPrompt = { agent, _ in
            let text = await agent.readFile(path: "/tmp/project/a.txt")
            await agent.emitText(text ?? "missing")
            _ = await agent.writeFile(path: "/tmp/project/b.txt", content: "new")
            return "end_turn"
        }
        store.set(["/tmp/project/a.txt": "one\ntwo\nthree"])
        let session = ACPClientSession(
            transport: clientTransport,
            hostServices: ACPHostServices(
                readTextFile: { request in store.get()[request.path] ?? "" },
                writeTextFile: { request in store.mutate { $0[request.path] = request.content } }),
            cwd: "/tmp/project")
        let events = await collectACP(await session.send("read"))
        #expect(events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined().contains("one"))
        #expect(store.get()["/tmp/project/b.txt"] == "new")
        let caps = agent.lastInitializeParams.get()?["clientCapabilities"]?["fs"]
        #expect(caps?["readTextFile"]?.boolValue == true)
        #expect(caps?["writeTextFile"]?.boolValue == true)
    }

    @Test func cancelStopsTurn() async throws {
        let (clientTransport, agentTransport) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentTransport)
        agent.onPrompt = { agent, _ in
            await agent.emitText("started")
            while !agent.cancelled.get() { try? await Task.sleep(for: .milliseconds(10)) }
            return "cancelled"
        }
        let session = ACPClientSession(transport: clientTransport, cwd: "/tmp/project")
        let collector = Task { await collectACP(await session.send("go")) }
        try await Task.sleep(for: .milliseconds(150))
        await session.stop()
        let events = await collector.value
        #expect(events.last == .runEnded(.stopped))
    }

    @Test func crashMidTurnEndsWithFailureNotHang() async throws {
        let (clientTransport, agentTransport) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentTransport)
        agent.onPrompt = { agent, _ in
            await agent.emitText("before crash")
            await agent.crash()
            try? await Task.sleep(for: .seconds(5))
            return "end_turn"
        }
        let session = ACPClientSession(transport: clientTransport, cwd: "/tmp/project")
        let events = await collectACP(await session.send("go"))
        guard case .runEnded(.failed) = events.last! else {
            Issue.record("expected failed ending, got \(String(describing: events.last))")
            return
        }
        let endings = events.filter { if case .runEnded = $0 { true } else { false } }
        #expect(endings.count == 1)
    }

    @Test func terminalThroughHostServices() async throws {
        let (clientTransport, agentTransport) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentTransport)
        agent.onPrompt = { agent, _ in
            let id = await agent.createTerminal(command: "echo hi")
            await agent.emitText("terminal \(id ?? "none")")
            return "end_turn"
        }
        let session = ACPClientSession(
            transport: clientTransport,
            hostServices: ACPHostServices(createTerminal: { _ in "term-1" }),
            cwd: "/tmp/project")
        let events = await collectACP(await session.send("run"))
        #expect(events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined() == "terminal term-1")
        let caps = agent.lastInitializeParams.get()?["clientCapabilities"]
        #expect(caps?["terminal"]?.boolValue == true)
    }

    @Test func oversizedLineClosesConnection() async throws {
        let (clientTransport, peerTransport) = acpPair()
        let connection = ACPConnection(transport: clientTransport)
        await connection.start()
        let closed = ACPLocked(false)
        await connection.setCloseHandler { _ in closed.set(true) }
        peerTransport.sendRaw(Data(repeating: UInt8(ascii: "x"), count: ACPConnection.maxLineBytes + 1024))
        // The request must fail, not hang, once the oversized frame is rejected.
        await #expect(throws: ACPError.self) {
            try await connection.request(method: "initialize", params: nil, timeout: .seconds(5))
        }
        #expect(closed.get())
        await connection.close()
    }

    @Test func setAgentModeSendsRequest() async throws {
        let (clientTransport, agentTransport) = acpPair()
        _ = await FakeACPAgent.make(transport: agentTransport)
        let session = ACPClientSession(transport: clientTransport, cwd: "/tmp/project")
        _ = try await session.newSession()
        try await session.setAgentMode("plan")
        #expect(await session.currentModeId == "plan")
    }

    @Test func requestTimeout() async throws {
        let (clientTransport, _) = acpPair()
        let connection = ACPConnection(transport: clientTransport)
        await connection.start()
        await #expect(throws: ACPError.self) {
            try await connection.request(method: "initialize", params: nil, timeout: .milliseconds(100))
        }
        await connection.close()
    }

    @Test func permissionTimeoutCancelsWithoutApproving() async throws {
        let (clientTransport, agentTransport) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentTransport)
        agent.onPrompt = { agent, _ in
            _ = await agent.requestPermission()
            return "end_turn"
        }
        let session = ACPClientSession(
            transport: clientTransport, cwd: "/tmp/project", permissionTimeout: .milliseconds(200))
        let events = await collectACP(await session.send("run it"))
        let outcome = agent.permissionOutcome.get()
        #expect(outcome?["outcome"]?["outcome"]?.stringValue == "cancelled")
        #expect(events.contains {
            if case .toolCallFinished(_, _, let output) = $0 {
                output.isError && output.text.contains("Permission request timed out")
            } else { false }
        })
        #expect(events.last == .runEnded(.completed))
    }

    /// Codex's adapter, measured 2026-11-12: a `cancelled` permission ends the whole turn with
    /// `stopReason: cancelled`, after its own `failed` update for the call.
    @Test func aTimedOutPermissionStaysExplainedWhenTheAgentEndsItsTurn() async throws {
        let (clientTransport, agentTransport) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentTransport)
        agent.onPrompt = { agent, _ in
            _ = await agent.requestPermission()
            await agent.emit(update: .object([
                "sessionUpdate": "tool_call_update", "toolCallId": "perm-1", "status": "failed",
                "content": .array([.object(["type": "content", "content": .object(["type": "text", "text": "aborted"])])]),
            ]))
            return "cancelled"
        }
        let session = ACPClientSession(
            transport: clientTransport, cwd: "/tmp/project", permissionTimeout: .milliseconds(200))
        let events = await collectACP(await session.send("run it"))
        #expect(agent.permissionOutcome.get()?["outcome"]?["outcome"]?.stringValue == "cancelled")
        let outputs = events.compactMap { event -> ToolOutput? in
            if case .toolCallFinished("perm-1", _, let output) = event { output } else { nil }
        }
        #expect(outputs.last?.text.hasPrefix("Permission request timed out") == true, "\(outputs)")
        #expect(outputs.last?.text.contains("aborted") == true, "the agent's own text is kept after the reason")
        #expect(events.last == .runEnded(.failed(ACPClientSession.unansweredPermissionEnding)),
                "nobody pressed Stop, so the ending is not \"Stopped.\"")
    }

    /// Claude Code's adapter, measured 2026-11-12: it reports the call failed and goes on.
    @Test func aTimedOutPermissionKeepsItsReasonWhenTheAgentCarriesOn() async throws {
        let (clientTransport, agentTransport) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentTransport)
        agent.onPrompt = { agent, _ in
            _ = await agent.requestPermission()
            await agent.emit(update: .object([
                "sessionUpdate": "tool_call_update", "toolCallId": "perm-1", "status": "failed", "rawOutput": "{}",
            ]))
            await agent.emitText("NOT-CREATED")
            return "end_turn"
        }
        let session = ACPClientSession(
            transport: clientTransport, cwd: "/tmp/project", permissionTimeout: .milliseconds(200))
        let events = await collectACP(await session.send("run it"))
        let last = events.last { if case .toolCallFinished("perm-1", _, _) = $0 { true } else { false } }
        guard case .toolCallFinished(_, _, let output)? = last else {
            Issue.record("no finish for the call")
            return
        }
        #expect(output.isError && output.text.hasPrefix("Permission request timed out"))
        #expect(events.last == .runEnded(.completed))
    }

    @Test func stopWhileACardWaitsFinishesItsCall() async throws {
        let (clientTransport, agentTransport) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentTransport)
        agent.onPrompt = { agent, _ in
            _ = await agent.requestPermission()
            // Like Codex: no update for the call, just the cancelled turn.
            while !agent.cancelled.get() { try? await Task.sleep(for: .milliseconds(10)) }
            return "cancelled"
        }
        let session = ACPClientSession(transport: clientTransport, cwd: "/tmp/project")
        let collector = Task { await collectACP(await session.send("go")) }
        for _ in 0..<200 where await session.awaitingApproval.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await session.awaitingApproval == ["perm-1"])
        await session.stop()
        let events = await collector.value
        #expect(events.contains {
            if case .toolCallFinished("perm-1", _, let output) = $0 {
                output.isError && output.text == ACPClientSession.permissionCancelledNote
            } else { false }
        }, "the host is told the card's call is over, so it can clear the card")
        #expect(agent.permissionOutcome.get()?["outcome"]?["outcome"]?.stringValue == "cancelled")
        #expect(events.last == .runEnded(.stopped))
    }

    @Test func loadWithoutSessionIdKeepsTheRequestedId() async throws {
        let (clientTransport, agentTransport) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentTransport)
        agent.omitSessionIdOnLoad = true
        let session = ACPClientSession(transport: clientTransport, cwd: "/tmp/project")
        let loaded = try await session.loadSession(id: "remote-9")
        #expect(loaded == "remote-9")
        #expect(await session.sessionId == "remote-9")
    }

    @Test func staleSessionLoadWithoutAuthMethodsIsNotRewritten() async throws {
        let (clientTransport, agentTransport) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentTransport)
        agent.sessionErrorMessage = "session not found"
        let session = ACPClientSession(transport: clientTransport, cwd: "/tmp/project")
        do {
            _ = try await session.loadSession(id: "gone")
            Issue.record("load should fail")
        } catch let error as ACPError {
            #expect(error.localizedDescription == "session not found")
        }
        #expect(!agent.authenticated.get())
    }

    @Test func malformedFrameFailsTheWaitingRequest() async throws {
        let (clientTransport, peerTransport) = acpPair()
        let connection = ACPConnection(transport: clientTransport)
        await connection.start()
        let closed = ACPLocked(false)
        await connection.setCloseHandler { _ in closed.set(true) }
        let peer = Task {
            for await chunk in peerTransport.incoming {
                if String(decoding: chunk, as: UTF8.self).contains("initialize") {
                    peerTransport.sendRaw(Data("{not json\n".utf8))
                }
            }
        }
        defer { peer.cancel() }
        do {
            _ = try await connection.request(method: "initialize", params: nil, timeout: .seconds(5))
            Issue.record("initialize should fail")
        } catch let error as ACPError {
            #expect(error.localizedDescription.contains("Malformed"))
        }
        #expect(closed.get())
        await connection.close()
    }
}
