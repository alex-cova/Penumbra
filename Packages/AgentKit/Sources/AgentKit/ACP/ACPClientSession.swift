import Foundation

/// Host-provided services an ACP agent may call back into (`fs/*`, `terminal/*`).
///
/// AgentKit advertises `clientCapabilities` strictly from which closures are present. The host
/// (Umbra) implements these through its workspace/terminal so unsaved buffers, the project jail,
/// and checkpoint recording keep working. A `nil` closure means "not supported".
public struct ACPHostServices: Sendable {
    public var readTextFile: (@Sendable (ACPReadTextFileRequest) async throws -> String)?
    public var writeTextFile: (@Sendable (ACPWriteTextFileRequest) async throws -> Void)?
    public var createTerminal: (@Sendable (ACPCreateTerminalRequest) async throws -> String)?
    public var terminalOutput: (@Sendable (_ terminalId: String) async throws -> ACPTerminalOutput)?
    public var waitForTerminalExit: (@Sendable (_ terminalId: String) async throws -> ACPTerminalOutput)?
    public var killTerminal: (@Sendable (_ terminalId: String) async throws -> Void)?
    public var releaseTerminal: (@Sendable (_ terminalId: String) async throws -> Void)?

    public init(
        readTextFile: (@Sendable (ACPReadTextFileRequest) async throws -> String)? = nil,
        writeTextFile: (@Sendable (ACPWriteTextFileRequest) async throws -> Void)? = nil,
        createTerminal: (@Sendable (ACPCreateTerminalRequest) async throws -> String)? = nil,
        terminalOutput: (@Sendable (_ terminalId: String) async throws -> ACPTerminalOutput)? = nil,
        waitForTerminalExit: (@Sendable (_ terminalId: String) async throws -> ACPTerminalOutput)? = nil,
        killTerminal: (@Sendable (_ terminalId: String) async throws -> Void)? = nil,
        releaseTerminal: (@Sendable (_ terminalId: String) async throws -> Void)? = nil
    ) {
        self.readTextFile = readTextFile
        self.writeTextFile = writeTextFile
        self.createTerminal = createTerminal
        self.terminalOutput = terminalOutput
        self.waitForTerminalExit = waitForTerminalExit
        self.killTerminal = killTerminal
        self.releaseTerminal = releaseTerminal
    }

    public var clientCapabilities: ACPClientCapabilities {
        ACPClientCapabilities(
            fs: ACPFileSystemCapabilities(readTextFile: readTextFile != nil, writeTextFile: writeTextFile != nil),
            terminal: createTerminal != nil)
    }
}

/// An external ACP agent presented with the subset of the `AgentSession` surface Umbra uses:
/// `send`, `stop`, `resolveApproval`, `answerQuestion`, and mode changes. ACP `session/update`
/// notifications are translated to `AgentEvent`, and the prompt response's stop reason becomes
/// exactly one terminal `.runEnded`.
public actor ACPClientSession {
    private let transport: any ACPTransport
    private let hostServices: ACPHostServices
    private let clientInfo: ACPImplementation?
    private let cwd: String
    private let additionalDirectories: [String]
    private let mcpServers: [JSONValue]
    private let requestTimeout: Duration

    public private(set) var permissionMode: PermissionMode
    public private(set) var permissionRules: PermissionRules

    private var connection: ACPConnection?
    public private(set) var initializeResponse: ACPInitializeResponse?
    public private(set) var sessionId: String?
    public private(set) var modeState: ACPSessionModeState?
    public private(set) var configOptions: [ACPConfigOption] = []
    public private(set) var availableCommands: [String] = []

    /// Checkpoints for files this agent writes through `fs/write_text_file`, so Revert Run works.
    public nonisolated let checkpoints: CheckpointLog?
    public private(set) var currentRunID: RunID?

    private var activeContinuation: AsyncStream<AgentEvent>.Continuation?
    private var activeRunTask: Task<Void, Never>?
    private var isRunning = false
    private var runEndedSent = false
    private var stopRequested = false
    private var knownToolCalls: [String: String] = [:]

    private var pendingApprovals: [String: CheckedContinuation<ACPRequestPermissionOutcome, Never>] = [:]
    private var pendingOptions: [String: [ACPPermissionOption]] = [:]
    private var pendingSuggestedRules: [String: PermissionRule] = [:]

    public init(
        transport: any ACPTransport,
        hostServices: ACPHostServices = ACPHostServices(),
        cwd: String,
        clientInfo: ACPImplementation? = ACPImplementation(name: "Umbra", version: "1.0"),
        additionalDirectories: [String] = [],
        mcpServers: [JSONValue] = [],
        mode: PermissionMode = .acceptEdits,
        rules: PermissionRules = PermissionRules(),
        requestTimeout: Duration = .seconds(30),
        checkpoints: CheckpointLog? = nil
    ) {
        self.checkpoints = checkpoints
        self.transport = transport
        self.hostServices = hostServices
        self.cwd = cwd
        self.clientInfo = clientInfo
        self.additionalDirectories = additionalDirectories
        self.mcpServers = mcpServers
        self.permissionMode = mode
        self.permissionRules = rules
        self.requestTimeout = requestTimeout
    }

    public var agentCapabilities: ACPAgentCapabilities? { initializeResponse?.agentCapabilities }
    public var currentModeId: String? { modeState?.currentModeId }
    public var isConnected: Bool { connection != nil && initializeResponse != nil }

    // MARK: - Connection & session setup

    @discardableResult
    public func connect() async throws -> ACPInitializeResponse {
        if let initializeResponse { return initializeResponse }
        let connection = ACPConnection(transport: transport)
        self.connection = connection
        let session = self
        await connection.setNotificationHandler { method, params in
            await session.dispatchNotification(method: method, params: params)
        }
        await connection.setRequestHandler { method, params in
            await session.dispatchRequest(method: method, params: params)
        }
        await connection.setCloseHandler { error in
            await session.handleClose(error: error)
        }
        await connection.start()
        let request = ACPInitializeRequest(
            clientCapabilities: hostServices.clientCapabilities, clientInfo: clientInfo)
        let raw: JSONValue
        do {
            raw = try await connection.request(method: "initialize", params: request.jsonValue, timeout: requestTimeout)
        } catch {
            self.connection = nil
            throw error
        }
        let response = try ACPInitializeResponse(jsonValue: raw)
        guard response.protocolVersion == acpProtocolVersion else {
            await connection.close()
            self.connection = nil
            throw ACPError.unsupportedProtocolVersion(response.protocolVersion)
        }
        initializeResponse = response
        return response
    }

    /// Creates a session, authenticating first if the agent demands it (`-32000` on `session/new`).
    @discardableResult
    public func newSession() async throws -> String {
        if let sessionId { return sessionId }
        _ = try await connect()
        guard let connection else { throw ACPError.notConnected }
        do {
            return try await startSession(method: "session/new", extra: [:], connection: connection)
        } catch ACPError.agentError(let error) where error.code == -32000 {
            try await authenticate(connection: connection)
            return try await startSession(method: "session/new", extra: [:], connection: connection)
        }
    }

    @discardableResult
    public func loadSession(id: String) async throws -> String {
        _ = try await connect()
        guard let connection else { throw ACPError.notConnected }
        do {
            return try await startSession(method: "session/load", extra: ["sessionId": .string(id)], connection: connection)
        } catch ACPError.agentError(let error) where error.code == -32000 {
            try await authenticate(connection: connection)
            return try await startSession(method: "session/load", extra: ["sessionId": .string(id)], connection: connection)
        }
    }

    private func startSession(method: String, extra: [String: JSONValue], connection: ACPConnection) async throws -> String {
        var params: [String: JSONValue] = [
            "cwd": .string(cwd),
            "mcpServers": .array(mcpServers),
        ]
        if !additionalDirectories.isEmpty {
            params["additionalDirectories"] = .array(additionalDirectories.map(JSONValue.string))
        }
        for (key, value) in extra { params[key] = value }
        let raw = try await connection.request(method: method, params: .object(params), timeout: requestTimeout)
        let response = try ACPNewSessionResponse(jsonValue: raw)
        sessionId = response.sessionId
        if let modes = response.modes { modeState = modes }
        if !response.configOptions.isEmpty { configOptions = response.configOptions }
        return response.sessionId
    }

    private func authenticate(connection: ACPConnection) async throws {
        guard let method = initializeResponse?.authMethods.first else {
            throw ACPError.agentError(JSONRPCError(code: -32000, message: "Authentication required, but the agent advertised no auth methods."))
        }
        _ = try await connection.request(
            method: "authenticate", params: .object(["methodId": .string(method.id)]), timeout: requestTimeout)
    }

    public func ensureSession() async throws -> String {
        if let sessionId { return sessionId }
        return try await newSession()
    }

    // MARK: - Prompt turns

    public func send(_ text: String) -> AsyncStream<AgentEvent> {
        send(prompt: [.text(text)])
    }

    public func send(prompt blocks: [ACPContentBlock]) -> AsyncStream<AgentEvent> {
        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()
        guard !isRunning else {
            continuation.yield(.runEnded(.failed("A run is already in progress.")))
            continuation.finish()
            return stream
        }
        isRunning = true
        runEndedSent = false
        stopRequested = false
        knownToolCalls = [:]
        activeContinuation = continuation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runPrompt(blocks: blocks, continuation: continuation)
        }
        activeRunTask = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func runPrompt(blocks: [ACPContentBlock], continuation: AsyncStream<AgentEvent>.Continuation) async {
        let runID: RunID
        if let checkpoints { runID = await checkpoints.beginRun(label: "") } else { runID = UUID() }
        currentRunID = runID
        continuation.yield(.runStarted(runID))
        continuation.yield(.stateChanged(.streaming))
        do {
            let sessionId = try await ensureSession()
            guard let connection else { throw ACPError.notConnected }
            if Task.isCancelled || stopRequested {
                finishRun(.stopped, continuation: continuation)
                return
            }
            let params: JSONValue = .object([
                "sessionId": .string(sessionId),
                "prompt": .array(blocks.map(\.jsonValue)),
            ])
            let raw = try await connection.request(method: "session/prompt", params: params)
            let reason = ACPStopReason(raw: raw.string("stopReason"))
            finishRun(stopRequested && reason != .cancelled ? .stopped : reason.runEnding, continuation: continuation)
        } catch is CancellationError {
            finishRun(.stopped, continuation: continuation)
        } catch let error as ACPError {
            if case .agentError(let rpc) = error {
                finishRun(.failed(rpc.message), continuation: continuation)
            } else if error == .transportClosed {
                finishRun(.failed("The ACP agent disconnected."), continuation: continuation)
            } else {
                finishRun(.failed(error.localizedDescription), continuation: continuation)
            }
        } catch {
            finishRun(.failed(error.localizedDescription), continuation: continuation)
        }
    }

    private func finishRun(_ ending: RunEnding, continuation: AsyncStream<AgentEvent>.Continuation) {
        guard !runEndedSent else { return }
        runEndedSent = true
        isRunning = false
        activeRunTask = nil
        if activeContinuation != nil { activeContinuation = nil }
        continuation.yield(.stateChanged(.idle))
        continuation.yield(.runEnded(ending))
        continuation.finish()
    }

    /// Sends `session/cancel`, answers pending permissions as cancelled, and (via the agent's
    /// `cancelled` prompt response) ends the run with `.stopped`.
    public func stop() async {
        stopRequested = true
        let approvals = pendingApprovals
        pendingApprovals = [:]
        pendingOptions = [:]
        pendingSuggestedRules = [:]
        for (_, continuation) in approvals { continuation.resume(returning: .cancelled) }
        guard let connection, let sessionId else { return }
        try? await connection.notify(method: "session/cancel", params: .object(["sessionId": .string(sessionId)]))
    }

    /// Hard stop: closes the transport. The run ends with `.failed` via the close handler.
    public func close() async {
        await stop()
        if let connection {
            await connection.setRequestHandler(nil)
            await connection.setNotificationHandler(nil)
            await connection.setCloseHandler(nil)
            await connection.close()
        }
        connection = nil
        sessionId = nil
        initializeResponse = nil
    }

    // MARK: - Approvals

    public func resolveApproval(callID: String, decision: ApprovalDecision) {
        guard let options = pendingOptions[callID] else { return }
        let outcome: ACPRequestPermissionOutcome
        switch decision {
        case .approve, .approveEditing:
            if let option = options.first(where: { $0.kind == .allowOnce }) ?? options.first(where: { $0.kind.isAllow }) ?? options.first {
                outcome = .selected(optionId: option.optionId)
                recordAllowAlwaysIfNeeded(callID: callID, option: option)
            } else {
                outcome = .cancelled
            }
        case .deny:
            if let option = options.first(where: { $0.kind == .rejectOnce }) ?? options.first(where: { $0.kind.isReject }) {
                outcome = .selected(optionId: option.optionId)
            } else {
                outcome = .cancelled
            }
        }
        resumeApproval(callID: callID, outcome: outcome)
    }

    /// Selects a specific permission option by id (e.g. an "allow always" button).
    public func resolvePermission(callID: String, optionId: String) {
        guard let options = pendingOptions[callID], let option = options.first(where: { $0.optionId == optionId }) else { return }
        recordAllowAlwaysIfNeeded(callID: callID, option: option)
        resumeApproval(callID: callID, outcome: .selected(optionId: optionId))
    }

    private func recordAllowAlwaysIfNeeded(callID: String, option: ACPPermissionOption) {
        guard option.kind == .allowAlways, let rule = pendingSuggestedRules[callID] else { return }
        permissionRules.add(rule, to: .allow)
    }

    private func resumeApproval(callID: String, outcome: ACPRequestPermissionOutcome) {
        guard let continuation = pendingApprovals.removeValue(forKey: callID) else { return }
        pendingOptions.removeValue(forKey: callID)
        pendingSuggestedRules.removeValue(forKey: callID)
        activeContinuation?.yield(.stateChanged(.streaming))
        continuation.resume(returning: outcome)
    }

    public var awaitingApproval: [String] { Array(pendingApprovals.keys) }

    /// ACP has no `ask_user` equivalent in the client direction; late answers are ignored,
    /// matching `AgentSession.answerQuestion` for an unknown call.
    public func answerQuestion(callID: String, answer: String?) {}

    // MARK: - Modes

    /// Sets Umbra's local permission mode. This gates host `fs`/`terminal` effects only; it is
    /// deliberately separate from the agent's own mode list.
    public func setMode(_ mode: PermissionMode) { permissionMode = mode }

    public func setRules(_ rules: PermissionRules) { permissionRules = rules }

    /// Switches the agent's mode via `session/set_mode`.
    public func setAgentMode(_ modeId: String) async throws {
        guard let connection else { throw ACPError.notConnected }
        let sessionId = try await ensureSession()
        _ = try await connection.request(
            method: "session/set_mode",
            params: .object(["sessionId": .string(sessionId), "modeId": .string(modeId)]),
            timeout: requestTimeout)
        if var state = modeState {
            state.currentModeId = modeId
            modeState = state
        }
    }

    // MARK: - Agent -> client dispatch

    private func handleClose(error: ACPError?) async {
        connection = nil
        sessionId = nil
        initializeResponse = nil
        let approvals = pendingApprovals
        pendingApprovals = [:]
        pendingOptions = [:]
        pendingSuggestedRules = [:]
        for (_, continuation) in approvals { continuation.resume(returning: .cancelled) }
        if let continuation = activeContinuation {
            let message = error.map { "The ACP agent disconnected: \($0.localizedDescription)" } ?? "The ACP agent disconnected."
            finishRun(.failed(message), continuation: continuation)
        }
    }

    private func dispatchNotification(method: String, params: JSONValue?) async {
        guard method == "session/update", let params else { return }
        if let updateSession = params.string("sessionId"), let sessionId, updateSession != sessionId { return }
        guard let updateValue = params["update"] else { return }
        let update = ACPSessionUpdate(jsonValue: updateValue)
        applyUpdate(update)
    }

    private func applyUpdate(_ update: ACPSessionUpdate) {
        let continuation = activeContinuation
        switch update {
        case .agentMessageChunk(let block):
            if let text = block.textValue, !text.isEmpty { continuation?.yield(.textDelta(text)) }
        case .agentThoughtChunk(let block):
            if let text = block.textValue, !text.isEmpty { continuation?.yield(.reasoningDelta(text)) }
        case .userMessageChunk:
            break
        case .toolCall(let call):
            if knownToolCalls[call.toolCallId] == nil {
                knownToolCalls[call.toolCallId] = call.displayName
                continuation?.yield(.toolCallStarted(id: call.toolCallId, name: call.displayName))
                if let rawInput = call.rawInput, let arguments = try? rawInput.serialized() {
                    continuation?.yield(.toolCallArguments(id: call.toolCallId, name: call.displayName, arguments: arguments))
                }
            }
            emitToolContent(id: call.toolCallId, name: call.displayName, content: call.content, status: call.status, continuation: continuation)
        case .toolCallUpdate(let update):
            let name = knownToolCalls[update.toolCallId] ?? update.displayName ?? "tool"
            if knownToolCalls[update.toolCallId] == nil {
                knownToolCalls[update.toolCallId] = name
                continuation?.yield(.toolCallStarted(id: update.toolCallId, name: name))
                if let rawInput = update.rawInput, let arguments = try? rawInput.serialized() {
                    continuation?.yield(.toolCallArguments(id: update.toolCallId, name: name, arguments: arguments))
                }
            }
            if let content = update.content {
                emitToolContent(id: update.toolCallId, name: name, content: content, status: update.status, continuation: continuation)
            } else if let status = update.status, status == .completed || status == .failed {
                let text = update.rawOutput.flatMap { value -> String? in
                    value.stringValue ?? (try? value.serialized())
                } ?? ""
                continuation?.yield(.toolCallFinished(
                    id: update.toolCallId, name: name, output: ToolOutput(text, isError: status == .failed)))
            }
        case .plan(let entries):
            continuation?.yield(.todosUpdated(entries.map(\.todoItem)))
        case .usageUpdate(let usage):
            continuation?.yield(.usage(usage.tokenUsage))
        case .currentModeUpdate(let modeId):
            if var state = modeState { state.currentModeId = modeId; modeState = state }
            continuation?.yield(.stateChanged(.streaming))
        case .configOptionUpdate(let options):
            configOptions = options
        case .availableCommands(let commands):
            availableCommands = commands
        case .sessionInfoUpdate, .unknown:
            break
        }
    }

    private func emitToolContent(
        id: String, name: String, content: [ACPToolCallContent],
        status: ACPToolCallStatus?, continuation: AsyncStream<AgentEvent>.Continuation?
    ) {
        guard let continuation else { return }
        let text = content.compactMap(\.textValue).joined(separator: "\n")
        switch status {
        case .completed, .failed:
            continuation.yield(.toolCallFinished(id: id, name: name, output: ToolOutput(text, isError: status == .failed)))
        case .inProgress:
            if !text.isEmpty { continuation.yield(.toolCallOutput(id: id, chunk: text)) }
        case .pending, nil:
            break
        }
    }

    private func dispatchRequest(method: String, params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        switch method {
        case "session/request_permission":
            return await handlePermissionRequest(params: params)
        case "fs/read_text_file":
            guard let service = hostServices.readTextFile else { return .failure(.methodNotFound(method)) }
            guard let params else { return .failure(.invalidParams("Missing params.")) }
            do {
                let request = try ACPReadTextFileRequest(jsonValue: params)
                let text = try await service(request)
                return .success(.object(["content": .string(request.windowed(text))]))
            } catch let error as JSONRPCError { return .failure(error) }
            catch { return .failure(.internalError(error.localizedDescription)) }
        case "fs/write_text_file":
            guard let service = hostServices.writeTextFile else { return .failure(.methodNotFound(method)) }
            guard permissionMode != .plan else {
                return .failure(JSONRPCError(code: -32000, message: "Writes are not allowed in plan mode."))
            }
            guard let params else { return .failure(.invalidParams("Missing params.")) }
            do {
                let write = try ACPWriteTextFileRequest(jsonValue: params)
                var checkpointRun: RunID?
                var checkpointPath: String?
                if let checkpoints, let runID = currentRunID {
                    let relative = write.path.hasPrefix(cwd + "/") ? String(write.path.dropFirst(cwd.count + 1)) : write.path
                    let original: String?
                    if let read = hostServices.readTextFile {
                        original = try? await read(ACPReadTextFileRequest(sessionId: write.sessionId, path: write.path))
                    } else { original = nil }
                    await checkpoints.willChange(run: runID, path: relative, original: original)
                    checkpointRun = runID
                    checkpointPath = relative
                }
                try await service(write)
                if let checkpoints, let checkpointRun, let checkpointPath {
                    await checkpoints.didChange(run: checkpointRun, path: checkpointPath, written: write.content)
                }
                return .success(.object([:]))
            } catch let error as JSONRPCError { return .failure(error) }
            catch { return .failure(.internalError(error.localizedDescription)) }
        case "terminal/create":
            guard let service = hostServices.createTerminal else { return .failure(.methodNotFound(method)) }
            guard permissionMode != .plan else {
                return .failure(JSONRPCError(code: -32000, message: "Terminals are not allowed in plan mode."))
            }
            guard let params else { return .failure(.invalidParams("Missing params.")) }
            do {
                let terminalId = try await service(try ACPCreateTerminalRequest(jsonValue: params))
                return .success(.object(["terminalId": .string(terminalId)]))
            } catch { return .failure(.internalError(error.localizedDescription)) }
        case "terminal/output":
            guard let service = hostServices.terminalOutput else { return .failure(.methodNotFound(method)) }
            guard let terminalId = params?.string("terminalId") else { return .failure(.invalidParams("Missing terminalId.")) }
            do { return .success(try await service(terminalId).jsonValue) }
            catch { return .failure(.internalError(error.localizedDescription)) }
        case "terminal/wait_for_exit":
            guard let service = hostServices.waitForTerminalExit else { return .failure(.methodNotFound(method)) }
            guard let terminalId = params?.string("terminalId") else { return .failure(.invalidParams("Missing terminalId.")) }
            do { return .success(try await service(terminalId).jsonValue) }
            catch { return .failure(.internalError(error.localizedDescription)) }
        case "terminal/kill":
            guard let service = hostServices.killTerminal else { return .failure(.methodNotFound(method)) }
            guard let terminalId = params?.string("terminalId") else { return .failure(.invalidParams("Missing terminalId.")) }
            do { try await service(terminalId); return .success(.object([:])) }
            catch { return .failure(.internalError(error.localizedDescription)) }
        case "terminal/release":
            guard let service = hostServices.releaseTerminal else { return .failure(.methodNotFound(method)) }
            guard let terminalId = params?.string("terminalId") else { return .failure(.invalidParams("Missing terminalId.")) }
            do { try await service(terminalId); return .success(.object([:])) }
            catch { return .failure(.internalError(error.localizedDescription)) }
        default:
            return .failure(.methodNotFound(method))
        }
    }

    private func handlePermissionRequest(params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        guard let params else { return .failure(.invalidParams("Missing params.")) }
        let request: ACPRequestPermission
        do { request = try ACPRequestPermission(jsonValue: params) }
        catch { return .failure(.invalidParams(error.localizedDescription)) }

        // Umbra's PermissionMode governs locally: in Plan mode, reject without a card.
        if permissionMode == .plan {
            if let reject = request.options.first(where: { $0.kind == .rejectOnce }) ?? request.options.first(where: { $0.kind.isReject }) {
                return .success(.object(["outcome": ACPRequestPermissionOutcome.selected(optionId: reject.optionId).jsonValue]))
            }
            return .success(.object(["outcome": ACPRequestPermissionOutcome.cancelled.jsonValue]))
        }

        let callID = request.toolCall.toolCallId
        let name = request.toolCall.displayName ?? "tool"
        let commandText: String = {
            if let raw = request.toolCall.rawInput {
                if let command = raw.string("command") { return command }
                return (try? raw.serialized()) ?? name
            }
            return request.toolCall.title ?? name
        }()
        var suggested: PermissionRule?
        if let raw = request.toolCall.rawInput {
            if let command = raw.string("command") { suggested = PermissionRule.suggestion(forCommand: command) }
            else if let path = raw.string("path") { suggested = PermissionRule(tool: "Edit", pattern: path) }
        }
        let approval = ApprovalRequest(
            title: request.toolCall.title ?? name,
            command: commandText,
            suggestedRule: suggested?.description,
            callID: callID,
            toolName: name)
        if knownToolCalls[callID] == nil {
            knownToolCalls[callID] = name
            activeContinuation?.yield(.toolCallStarted(id: callID, name: name))
        }
        pendingOptions[callID] = request.options
        if let suggested { pendingSuggestedRules[callID] = suggested }
        activeContinuation?.yield(.stateChanged(.awaitingApproval(callID: callID)))
        activeContinuation?.yield(.approvalRequested(approval))
        let outcome: ACPRequestPermissionOutcome = await withCheckedContinuation { continuation in
            pendingApprovals[callID] = continuation
            if stopRequested { resumeApproval(callID: callID, outcome: .cancelled) }
        }
        return .success(.object(["outcome": outcome.jsonValue]))
    }
}
