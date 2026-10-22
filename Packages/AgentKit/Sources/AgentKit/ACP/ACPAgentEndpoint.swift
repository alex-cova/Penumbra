import Foundation

/// AgentKit as an ACP agent (plan Phase 2): wraps `AgentSession`s behind an ACP connection,
/// reusing the client mapping table in reverse.
///
/// `session/prompt` → `AgentSession.send(_:)`; `AgentEvent` → `session/update`;
/// `.approvalRequested` → client `session/request_permission` (awaited before
/// `resolveApproval`); `.questionAsked` with suggested answers → the answers as permission
/// options, without answers → a free-text `elicitation/create` form; `.planProposed` →
/// approve/revise options.
///
/// What the endpoint asks the host to build for one session: where it works, what it
/// restores, and how to reach the remote client's files.
public struct ACPSessionRequest: Sendable {
    public var cwd: String
    public var history: [ConversationItem]
    public var totalUsage: TokenUsage
    /// The identity a restored session must keep. `nil` for a new session (the host generates
    /// one). A factory that ignores this breaks `session/load` after a restart.
    public var sessionID: UUID?
    /// Reads an absolute path from the remote client. Present only when the client advertised
    /// `fs.readTextFile`.
    public var remoteFileReader: (@Sendable (String) async throws -> String)?

    public init(
        cwd: String, history: [ConversationItem] = [], totalUsage: TokenUsage = TokenUsage(),
        sessionID: UUID? = nil,
        remoteFileReader: (@Sendable (String) async throws -> String)? = nil
    ) {
        self.cwd = cwd; self.history = history; self.totalUsage = totalUsage
        self.sessionID = sessionID
        self.remoteFileReader = remoteFileReader
    }
}

/// The sessions' tools keep running against their local `AgentWorkspace`, wrapped so a file
/// the local project does not have is read from the remote client when it advertised
/// `fs.readTextFile`. Listing, search, and all writes stay local: the endpoint never writes
/// to the client's machine.
public actor ACPAgentEndpoint {
    /// Creates the session for one `session/new` (or a `session/load` the store restores).
    public typealias SessionFactory = @Sendable (ACPSessionRequest) async throws -> AgentSession

    private let transport: any ACPTransport
    private let agentInfo: ACPImplementation?
    private let sessionFactory: SessionFactory
    private let contextWindow: Int?
    /// When set, sessions are saved after every turn and `session/load` restores them, so a
    /// conversation survives a process restart. Advertised as `loadSession`.
    public let sessionStore: SessionStore?

    private var connection: ACPConnection?
    private var sessions: [String: AgentSession] = [:]
    private var sessionRoots: [String: String] = [:]
    /// Per-session `permissions` config values (`ask` or `auto-allow`).
    private var sessionPermissions: [String: String] = [:]
    private var clientFS = ACPFileSystemCapabilities()
    private var clientElicitationForm = false
    private var closeWaiter: CheckedContinuation<Void, Never>?
    private var stopped = false

    public init(
        transport: any ACPTransport,
        agentInfo: ACPImplementation? = ACPImplementation(name: "Umbra Agent", version: "1.0"),
        contextWindow: Int? = nil,
        sessionStore: SessionStore? = nil,
        sessionFactory: @escaping SessionFactory
    ) {
        self.transport = transport
        self.agentInfo = agentInfo
        self.contextWindow = contextWindow
        self.sessionStore = sessionStore
        self.sessionFactory = sessionFactory
    }

    public var sessionIDs: [String] { Array(sessions.keys) }

    /// Serves until the transport closes (stdin EOF for a stdio host).
    public func run() async {
        let connection = ACPConnection(transport: transport)
        self.connection = connection
        let endpoint = self
        await connection.setRequestHandler { method, params in
            await endpoint.handle(method: method, params: params)
        }
        await connection.setNotificationHandler { method, params in
            await endpoint.handleNotification(method: method, params: params)
        }
        await connection.setCloseHandler { _ in
            await endpoint.handleClose()
        }
        await connection.start()
        await withCheckedContinuation { continuation in
            if stopped { continuation.resume() } else { closeWaiter = continuation }
        }
    }

    public func stop() async {
        for session in sessions.values { await session.stop() }
        await connection?.close()
        handleCloseSync()
    }

    private func handleClose() { handleCloseSync() }

    private func handleCloseSync() {
        stopped = true
        closeWaiter?.resume()
        closeWaiter = nil
    }

    // MARK: - Requests (client -> agent)

    private func handle(method: String, params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        switch method {
        case "initialize":
            clientFS = ACPFileSystemCapabilities(jsonValue: params?["clientCapabilities"]?["fs"])
            clientElicitationForm = ACPClientCapabilities(jsonValue: params?["clientCapabilities"]).elicitationForm
            let lifecycle: JSONValue? = sessionStore == nil ? nil : .object([
                "resume": .object([:]), "list": .object([:]),
                "delete": .object([:]), "close": .object([:]),
            ])
            let capabilities: JSONValue = .object([
                "loadSession": .bool(sessionStore != nil),
                "promptCapabilities": .object(["image": false, "audio": false, "embeddedContext": false]),
                "mcpCapabilities": .object(["http": false, "sse": false]),
                "sessionCapabilities": lifecycle ?? .object([:]),
            ])
            var result: [String: JSONValue] = [
                "protocolVersion": .int(acpProtocolVersion),
                "agentCapabilities": capabilities,
                "authMethods": .array([]),
            ]
            if let agentInfo { result["agentInfo"] = agentInfo.jsonValue }
            return .success(.object(result))
        case "authenticate":
            return .success(.object([:]))
        case "session/new":
            guard let cwd = params?.string("cwd"), !cwd.isEmpty else {
                return .failure(.invalidParams("session/new requires an absolute cwd."))
            }
            do {
                let session = try await sessionFactory(ACPSessionRequest(cwd: cwd, remoteFileReader: remoteReader()))
                let id = session.sessionID.uuidString
                sessions[id] = session
                sessionRoots[id] = cwd
                await persist(id: id)
                return .success(await sessionResponse(session: session, id: id))
            } catch {
                return .failure(.internalError(error.localizedDescription))
            }
        case "session/load":
            guard let id = params?.string("sessionId") else {
                return .failure(.invalidParams("session/load requires a sessionId."))
            }
            if let session = sessions[id] {
                return .success(await sessionResponse(session: session, id: id))
            }
            guard let cwd = params?.string("cwd"), !cwd.isEmpty else {
                return .failure(.invalidParams("session/load requires an absolute cwd."))
            }
            guard let uuid = UUID(uuidString: id) else { return .failure(.invalidParams("Unknown sessionId.")) }
            do {
                let session = try await restore(id: uuid, cwd: cwd)
                sessions[id] = session
                sessionRoots[id] = cwd
                return .success(await sessionResponse(session: session, id: id))
            } catch {
                return .failure(.invalidParams("Unknown session. Start with session/new."))
            }
        case "session/resume":
            // Resume restores without replaying history (unlike load): the conversation
            // continues where the store left it. Nothing is emitted before the response.
            guard let id = params?.string("sessionId") else {
                return .failure(.invalidParams("session/resume requires a sessionId."))
            }
            if let session = sessions[id] {
                return .success(await sessionResponse(session: session, id: id))
            }
            guard sessionStore != nil else {
                return .failure(.invalidParams("Unknown session. Start with session/new."))
            }
            guard let cwd = params?.string("cwd"), !cwd.isEmpty else {
                return .failure(.invalidParams("session/resume requires an absolute cwd."))
            }
            guard let uuid = UUID(uuidString: id) else { return .failure(.invalidParams("Unknown sessionId.")) }
            do {
                let session = try await restore(id: uuid, cwd: cwd)
                sessions[id] = session
                sessionRoots[id] = cwd
                return .success(await sessionResponse(session: session, id: id))
            } catch {
                return .failure(.invalidParams("Unknown session. Start with session/new."))
            }
        case "session/list":
            guard let store = sessionStore else { return .success(.object(["sessions": .array([])])) }
            // Roots we can report: live sessions, plus an explicit filter (which may name a
            // root whose sessions all live in the store from an earlier process).
            var roots = Set(sessionRoots.values)
            if let filter = params?.string("cwd") { roots = [filter] }
            var infos: [JSONValue] = []
            let formatter = ISO8601DateFormatter()
            for root in roots.sorted() {
                var seen = Set<String>()
                for id in sessions.keys.filter({ sessionRoots[$0] == root }).sorted() {
                    seen.insert(id)
                    infos.append(.object(["sessionId": .string(id), "cwd": .string(root)]))
                }
                for summary in store.list(projectRoot: root) where !seen.contains(summary.id.uuidString) {
                    infos.append(.object([
                        "sessionId": .string(summary.id.uuidString),
                        "cwd": .string(root),
                        "title": .string(summary.title),
                        "updatedAt": .string(formatter.string(from: summary.updatedAt)),
                    ]))
                }
            }
            return .success(.object(["sessions": .array(infos)]))
        case "session/delete":
            guard let id = params?.string("sessionId") else {
                return .failure(.invalidParams("session/delete requires a sessionId."))
            }
            // Deleting an unknown id succeeds silently.
            if let session = sessions.removeValue(forKey: id) { await session.stop() }
            if let root = sessionRoots.removeValue(forKey: id) { sessionStore?.delete(UUID(uuidString: id) ?? UUID(), projectRoot: root) }
            sessionPermissions.removeValue(forKey: id)
            return .success(.object([:]))
        case "session/close":
            guard let id = params?.string("sessionId") else {
                return .failure(.invalidParams("session/close requires a sessionId."))
            }
            // Close cancels in-flight work as if session/cancel had been called, then frees
            // the live session. The store keeps the snapshot, so load/resume still work.
            if let session = sessions.removeValue(forKey: id) { await session.stop() }
            sessionRoots.removeValue(forKey: id)
            sessionPermissions.removeValue(forKey: id)
            return .success(.object([:]))
        case "session/set_config_option":
            guard let id = params?.string("sessionId"), sessions[id] != nil,
                  let configId = params?.string("configId")
            else { return .failure(.invalidParams("session/set_config_option requires a known sessionId and configId.")) }
            guard configId == "permissions",
                  let value = params?.string("value"), ["ask", "auto-allow"].contains(value)
            else { return .failure(.invalidParams("Unknown configId or value.")) }
            sessionPermissions[id] = value
            return .success(.object(["configOptions": configOptions(for: id)]))
        case "session/prompt":
            guard let id = params?.string("sessionId"), let session = sessions[id] else {
                return .failure(.invalidParams("Unknown sessionId."))
            }
            let blocks = (params?["prompt"]?.arrayValue ?? []).map(ACPContentBlock.init(jsonValue:))
            let text = blocks.compactMap(\.textValue).joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.invalidParams("session/prompt requires a text prompt."))
            }
            return await prompt(session: session, sessionId: id, text: text)
        case "session/set_mode":
            guard let id = params?.string("sessionId"), let session = sessions[id],
                  let modeID = params?.string("modeId"), let mode = PermissionMode(persisted: modeID)
            else { return .failure(.invalidParams("session/set_mode requires a known sessionId and modeId.")) }
            await session.setMode(mode)
            return .success(.object([:]))
        default:
            return .failure(.methodNotFound(method))
        }
    }

    /// Reads through to the remote client, when it advertised `fs.readTextFile`.
    private func remoteReader() -> (@Sendable (String) async throws -> String)? {
        guard clientFS.readTextFile, let connection else { return nil }
        return { path in
            let result = try await connection.request(
                method: "fs/read_text_file",
                params: .object(["path": .string(path)]))
            guard let content = result.string("content") else {
                throw ACPError.malformedFrame("fs/read_text_file response missing content")
            }
            return content
        }
    }

    private func persist(id: String) async {
        guard let store = sessionStore, let session = sessions[id], let root = sessionRoots[id] else { return }
        let snapshot = SessionSnapshot(
            id: session.sessionID, projectRoot: root, title: SessionStore.title(from: await session.items),
            items: await session.items, totalUsage: await session.totalUsage)
        try? store.save(snapshot)
    }

    /// Restores a session saved by an earlier process. Throws when the store has nothing for it.
    private func restore(id: UUID, cwd: String) async throws -> AgentSession {
        struct NotFound: Error {}
        guard let store = sessionStore, let snapshot = store.load(id, projectRoot: cwd) else { throw NotFound() }
        let session = try await sessionFactory(ACPSessionRequest(
            cwd: cwd, history: snapshot.items, totalUsage: snapshot.totalUsage,
            sessionID: id, remoteFileReader: remoteReader()))
        guard session.sessionID == id else { throw NotFound() }
        return session
    }

    /// The endpoint's one real config option: whether tool approvals ask the client or
    /// are auto-allowed. Served and round-tripped through `session/set_config_option`.
    private func configOptions(for id: String) -> JSONValue {
        .array([.object([
            "id": "permissions",
            "name": "Permissions",
            "description": "Ask the client before tools run, or allow them without asking.",
            "type": "select",
            "options": .array([
                .object(["value": "ask", "name": "Ask every time"]),
                .object(["value": "auto-allow", "name": "Always allow"]),
            ]),
            "currentValue": .string(sessionPermissions[id] ?? "ask"),
        ])])
    }

    private func sessionResponse(session: AgentSession, id: String) async -> JSONValue {
        let current = await session.currentMode
        let modes = ACPSessionModeState(
            currentModeId: current.rawValue,
            availableModes: PermissionMode.allCases.map {
                ACPSessionMode(id: $0.rawValue, name: $0.displayName, description: $0.editorNote)
            })
        return .object(["sessionId": .string(id), "modes": modes.jsonValue, "configOptions": configOptions(for: id)])
    }

    private func handleNotification(method: String, params: JSONValue?) async {
        if method == "session/cancel", let id = params?.string("sessionId"), let session = sessions[id] {
            await session.stop()
        }
    }

    // MARK: - Prompt turn (reversed mapping)

    private func prompt(session: AgentSession, sessionId: String, text: String) async -> Result<JSONValue, JSONRPCError> {
        guard let connection else { return .failure(.internalError("The endpoint is not running.")) }
        var ending: RunEnding = .completed
        let stream = await session.send(text)
        for await event in stream {
            switch event {
            case .runEnded(let runEnding):
                ending = runEnding
            case .approvalRequested(let request):
                await answerApproval(request, session: session, connection: connection)
            case .questionAsked(let question):
                await answerQuestion(question, session: session, connection: connection)
            case .planProposed(let callID, let plan):
                await answerPlan(callID: callID, plan: plan, session: session, connection: connection)
            default:
                if let update = Self.update(for: event, contextWindow: contextWindow) {
                    try? await connection.notify(
                        method: "session/update",
                        params: .object(["sessionId": .string(sessionId), "update": update]))
                }
            }
        }
        await persist(id: sessionId)
        switch ending {
        case .failed(let message):
            return .failure(.internalError(message))
        case .completed:
            return .success(.object(["stopReason": .string(ACPStopReason.endTurn.rawValue)]))
        case .lengthLimit:
            return .success(.object(["stopReason": .string(ACPStopReason.maxTokens.rawValue)]))
        case .iterationCap, .budget, .repeatedCall:
            return .success(.object(["stopReason": .string(ACPStopReason.maxTurnRequests.rawValue)]))
        case .contentFiltered:
            return .success(.object(["stopReason": .string(ACPStopReason.refusal.rawValue)]))
        case .degenerateOutput:
            return .success(.object(["stopReason": .string(ACPStopReason.endTurn.rawValue)]))
        case .stopped:
            return .success(.object(["stopReason": .string(ACPStopReason.cancelled.rawValue)]))
        }
    }

    /// `AgentEvent` → `session/update` payload. Approvals/questions/plans and lifecycle events
    /// are handled by the prompt loop and map to `nil` here.
    public static func update(for event: AgentEvent, contextWindow: Int? = nil) -> JSONValue? {
        switch event {
        case .textDelta(let text):
            return chunk("agent_message_chunk", text: text)
        case .reasoningDelta(let text):
            return chunk("agent_thought_chunk", text: text)
        case .toolCallStarted(let id, let name):
            return .object([
                "sessionUpdate": "tool_call", "toolCallId": .string(id), "title": .string(name),
                "name": .string(name), "status": "pending", "content": .array([]),
            ])
        case .toolCallArguments(let id, _, let arguments):
            let raw = (try? JSONValue(parsing: arguments)) ?? .string(arguments)
            return .object(["sessionUpdate": "tool_call_update", "toolCallId": .string(id), "rawInput": raw])
        case .toolCallOutput(let id, let chunkText):
            return .object([
                "sessionUpdate": "tool_call_update", "toolCallId": .string(id), "status": "in_progress",
                "content": .array([toolContent(chunkText)]),
            ])
        case .toolCallFinished(let id, _, let output):
            return .object([
                "sessionUpdate": "tool_call_update", "toolCallId": .string(id),
                "status": output.isError ? "failed" : "completed",
                "content": .array([toolContent(output.text)]),
            ])
        case .todosUpdated(let items):
            let entries = items.map { item -> JSONValue in
                let status: String
                switch item.status {
                case .pending: status = "pending"
                case .inProgress: status = "in_progress"
                case .completed: status = "completed"
                }
                return .object(["content": .string(item.content), "priority": "medium", "status": .string(status)])
            }
            return .object(["sessionUpdate": "plan", "entries": .array(entries)])
        case .usage(let usage):
            return .object([
                "sessionUpdate": "usage_update",
                "used": .int(usage.inputTokens + usage.outputTokens),
                "size": .int(contextWindow ?? 0),
            ])
        case .runStarted, .stateChanged, .turnRestarted, .retryScheduled, .assistantMessage, .approvalRequested,
             .questionAsked, .planProposed, .unreadableToolCall, .compacted, .continuing, .stepFinished, .stopGateChecked,
             .subagent, .subagentFinished, .runEnded:
            return nil
        }
    }

    private static func chunk(_ type: String, text: String) -> JSONValue {
        .object([
            "sessionUpdate": .string(type),
            "content": .object(["type": "text", "text": .string(text)]),
        ])
    }

    private static func toolContent(_ text: String) -> JSONValue {
        .object(["type": "content", "content": .object(["type": "text", "text": .string(text)])])
    }

    // MARK: - Permission equivalents

    private func answerApproval(_ request: ApprovalRequest, session: AgentSession, connection: ACPConnection) async {
        // The `permissions` config option is real: auto-allow approves without asking.
        if sessionPermissions[session.sessionID.uuidString] == "auto-allow" {
            await session.resolveApproval(callID: request.callID, decision: .approve)
            return
        }
        let options: [JSONValue] = [
            option("allow-once", "Allow once", "allow_once"),
            option("allow-always", "Always allow", "allow_always"),
            option("reject-once", "Reject", "reject_once"),
            option("reject-always", "Always reject", "reject_always"),
        ]
        let rawInput: JSONValue = .object(["command": .string(request.command)])
        let outcome = await requestPermission(
            connection: connection, sessionId: session.sessionID.uuidString,
            toolCallId: request.callID, title: request.title, rawInput: rawInput, options: options)
        switch outcome {
        case .selected(let optionId) where optionId.hasPrefix("allow"):
            await session.resolveApproval(callID: request.callID, decision: .approve)
        case .selected(let optionId) where optionId.hasPrefix("reject"):
            await session.resolveApproval(callID: request.callID, decision: .deny(note: nil))
        default:
            await session.resolveApproval(callID: request.callID, decision: .deny(note: "Cancelled by the client."))
        }
    }

    private func answerQuestion(_ question: UserQuestion, session: AgentSession, connection: ACPConnection) async {
        guard !question.options.isEmpty else {
            // No suggested answers: elicit free text over `elicitation/create` — but only when
            // the client advertised a form mode. Calling it otherwise is a protocol violation
            // (the client never consented to the call), so the question is dismissed as before.
            guard clientElicitationForm else {
                await session.answerQuestion(callID: question.callID, answer: nil)
                return
            }
            let prompt = ACPElicitationPrompt(
                sessionId: session.sessionID.uuidString, toolCallId: question.callID,
                title: question.question, message: question.question)
            guard let result = try? await connection.request(
                method: "elicitation/create", params: ACPElicitationOutcome.formRequest(prompt: prompt)),
                ACPElicitationOutcome(jsonValue: result).acceptedText?.isEmpty == false
            else {
                await session.answerQuestion(callID: question.callID, answer: nil)
                return
            }
            await session.answerQuestion(
                callID: question.callID, answer: ACPElicitationOutcome(jsonValue: result).acceptedText)
            return
        }
        let options = question.options.enumerated().map { index, text in
            option("option-\(index)", text, "allow_once")
        }
        let outcome = await requestPermission(
            connection: connection, sessionId: session.sessionID.uuidString,
            toolCallId: question.callID, title: question.question, rawInput: .object([:]), options: options)
        switch outcome {
        case .selected(let optionId):
            let index = optionId.split(separator: "-").last.flatMap { Int($0) }
            let answer = index.flatMap { question.options.indices.contains($0) ? question.options[$0] : nil }
            await session.answerQuestion(callID: question.callID, answer: answer)
        default:
            await session.answerQuestion(callID: question.callID, answer: nil)
        }
    }

    private func answerPlan(callID: String, plan: String, session: AgentSession, connection: ACPConnection) async {
        let options = [
            option("approve", "Approve plan", "allow_once"),
            option("revise", "Request changes", "reject_once"),
        ]
        let outcome = await requestPermission(
            connection: connection, sessionId: session.sessionID.uuidString,
            toolCallId: callID, title: "Approve this plan?", rawInput: .object(["plan": .string(plan)]), options: options)
        switch outcome {
        case .selected(let optionId) where optionId == "approve":
            await session.resolvePlan(callID: callID, decision: .approve(.acceptEdits))
        default:
            await session.resolvePlan(callID: callID, decision: .revise(""))
        }
    }

    private func option(_ id: String, _ name: String, _ kind: String) -> JSONValue {
        .object(["optionId": .string(id), "name": .string(name), "kind": .string(kind)])
    }

    private func requestPermission(
        connection: ACPConnection, sessionId: String, toolCallId: String,
        title: String, rawInput: JSONValue, options: [JSONValue]
    ) async -> ACPRequestPermissionOutcome {
        let params: JSONValue = .object([
            "sessionId": .string(sessionId),
            "toolCall": .object(["toolCallId": .string(toolCallId), "title": .string(title), "rawInput": rawInput]),
            "options": .array(options),
        ])
        guard let result = try? await connection.request(method: "session/request_permission", params: params),
              let outcome = result["outcome"],
              let parsed = ACPRequestPermissionOutcome(jsonValue: outcome)
        else { return .cancelled }
        return parsed
    }
}
