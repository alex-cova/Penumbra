import AgentKit
import Foundation

/// Output shapes for `umbra-agent run`. `json` is a contract: every object carries
/// `"schema": 1` so consumers can gate on it.
public enum UmbraAgentOutputFormat: String, Sendable, CaseIterable {
    case text
    case json
    case streamJson = "stream-json"
}

/// Exit codes for `umbra-agent run`: 0 finished, 1 error, 2 stopped by a budget,
/// 3 an approval was refused.
public enum UmbraAgentExitCode: Int32, Sendable {
    case finished = 0
    case error = 1
    case budget = 2
    case approvalRefused = 3
}

/// A refused approval, question, or plan decision from a non-interactive run.
public struct UmbraAgentRefusal: Sendable, Equatable {
    public var kind: String
    public var title: String
    public var command: String?

    public init(kind: String, title: String, command: String? = nil) {
        self.kind = kind
        self.title = title
        self.command = command
    }
}

/// Everything one headless run needs. `client` injects a model (tests pass a
/// `MockLLMClient`); when it is nil the run builds one from `provider` via the shared
/// `UmbraAgentProviderFactory`.
public struct UmbraAgentRunRequest: Sendable {
    public var prompt: String
    public var provider: UmbraAgentProviderConfig
    public var client: (any LLMClient)?
    public var mode: PermissionMode
    public var maxIterations: Int?
    public var maxRunTokens: Int?
    public var maxRunSeconds: TimeInterval?
    public var workingDirectory: URL
    public var output: UmbraAgentOutputFormat
    public var resumeSessionID: UUID?
    /// Project MCP servers (`.umbra/mcp.json`, `.mcp.json`) start only with this set,
    /// standing in for the app's consent sheet.
    public var allowMCP: Bool
    public var sandbox: Bool
    public var extraEnvironment: [String: String]
    /// Session storage. `nil` uses the app's own directory, so a CLI run shows up in
    /// AI mode history afterwards. Tests redirect it.
    public var sessionsDirectory: URL?
    public var keyStore: (any IDEAgentKeyStore)?

    public init(
        prompt: String,
        provider: UmbraAgentProviderConfig,
        client: (any LLMClient)? = nil,
        mode: PermissionMode = .acceptEdits,
        maxIterations: Int? = nil,
        maxRunTokens: Int? = nil,
        maxRunSeconds: TimeInterval? = nil,
        workingDirectory: URL,
        output: UmbraAgentOutputFormat = .text,
        resumeSessionID: UUID? = nil,
        allowMCP: Bool = false,
        sandbox: Bool = false,
        extraEnvironment: [String: String] = [:],
        sessionsDirectory: URL? = nil,
        keyStore: (any IDEAgentKeyStore)? = nil
    ) {
        self.prompt = prompt
        self.provider = provider
        self.client = client
        self.mode = mode
        self.maxIterations = maxIterations
        self.maxRunTokens = maxRunTokens
        self.maxRunSeconds = maxRunSeconds
        self.workingDirectory = workingDirectory
        self.output = output
        self.resumeSessionID = resumeSessionID
        self.allowMCP = allowMCP
        self.sandbox = sandbox
        self.extraEnvironment = extraEnvironment
        self.sessionsDirectory = sessionsDirectory
        self.keyStore = keyStore
    }
}

public struct UmbraAgentRunResult: Sendable {
    /// Contract version. Always 1.
    public static let schemaVersion = 1

    public var exitCode: UmbraAgentExitCode
    public var ending: RunEnding
    public var text: String
    public var refusals: [UmbraAgentRefusal]
    public var usage: TokenUsage
    public var sessionID: UUID
    public var providerName: String
    public var model: String
    public var workingDirectory: String

    /// The `json` output: a documented, stable shape.
    public func jsonObject() -> [String: Any] {
        [
            "schema": Self.schemaVersion,
            "session": sessionID.uuidString,
            "provider": providerName,
            "model": model,
            "cwd": workingDirectory,
            "ending": Self.endingName(ending),
            "exit_code": Int(exitCode.rawValue),
            "text": text,
            "usage": ["input_tokens": usage.inputTokens, "output_tokens": usage.outputTokens],
            "refused": refusals.map { refusal -> [String: Any] in
                var object: [String: Any] = ["kind": refusal.kind, "title": refusal.title]
                if let command = refusal.command { object["command"] = command }
                return object
            },
        ]
    }

    public func jsonString(pretty: Bool = true) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: jsonObject(),
            options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func endingName(_ ending: RunEnding) -> String {
        switch ending {
        case .completed: "completed"
        case .lengthLimit: "length_limit"
        case .contentFiltered: "content_filtered"
        case .degenerateOutput: "degenerate_output"
        case .iterationCap: "iteration_cap"
        case .budget: "budget"
        case .stopped: "stopped"
        case .repeatedCall(let name): "repeated_call:\(name)"
        case .failed(let message): "failed:\(message)"
        }
    }
}

/// The `UmbraAgentCommandHost` for a headless run: no editor, no panels. Command output
/// streams to stderr (or the stream-json event log); buffers need no saving.
public struct UmbraAgentHeadlessCommandHost: UmbraAgentCommandHost {
    public var projectRoot: URL
    public var environment: [String: String]
    public var onCommandLine: (@Sendable (UUID, String, String?) -> Void)?

    public init(
        projectRoot: URL, environment: [String: String] = [:],
        onCommandLine: (@Sendable (UUID, String, String?) -> Void)? = nil
    ) {
        self.projectRoot = projectRoot
        self.environment = environment
        self.onCommandLine = onCommandLine
    }

    public func commandEnvironment() async -> [String: String] { environment }

    public func showCommand(id: UUID, title: String, line: String?) {
        onCommandLine?(id, title, line)
    }
}

public enum UmbraAgentHeadlessRun {
    public enum RunError: Error, CustomStringConvertible, Sendable {
        case message(String)
        public var description: String {
            if case .message(let text) = self { return text }
            return ""
        }
    }

    /// Drives one prompt to a terminal `RunEnding` with `client` (or the shared factory),
    /// answering every approval, question, and plan decision with a refusal: there is no TTY,
    /// so nothing is ever auto-approved. An allow rule in the project's permission files (or
    /// `.auto` for reads) still lets a call through without surfacing a card.
    public static func run(
        _ request: UmbraAgentRunRequest,
        onEvent: (@Sendable (AgentEvent) -> Void)? = nil
    ) async -> UmbraAgentRunResult {
        let root = request.workingDirectory.standardizedFileURL
        let store = store(for: request)
        let resumed = request.resumeSessionID.flatMap { store.load($0, projectRoot: root.path) }

        let setup: UmbraAgentProviderSetup
        if let client = request.client {
            setup = UmbraAgentProviderSetup(
                client: client, contextWindow: request.provider.contextWindow,
                model: request.provider.model,
                reasoningEffort: request.provider.reasoningEffort == "off" ? nil : request.provider.reasoningEffort)
        } else {
            do {
                var config = request.provider
                if config.keyStore == nil { config.keyStore = request.keyStore }
                setup = try await UmbraAgentProviderFactory.make(config)
            } catch {
                return failure(
                    request: request, sessionID: resumed?.id ?? UUID(), text: "",
                    message: "Could not start the provider: \(error)")
            }
        }

        let rules = IDEAgentPermissionFiles.load(projectRoot: root, appFile: IDEAgentPermissionFiles.appFile())
        let environment = AgentCommandEnvironment.make(javaHome: nil, extras: request.extraEnvironment)
        let sandbox: IDEAgentSandboxChoice? =
            (request.sandbox && IDEAgentSandbox.isAvailable)
            ? IDEAgentSandboxChoice(profile: IDEAgentSandboxProfile.make(projectRoot: root.path)) : nil
        let host = UmbraAgentHeadlessCommandHost(projectRoot: root, environment: environment) { _, _, line in
            if let line, request.output == .streamJson {
                FileHandle.standardError.write(Data(line.utf8))
            }
        }

        var tools: [any AgentTool] = ReadOnlyTools.all() + EditingTools.all()
        tools.append(UmbraAgentRunCommandTool(host: host, sandbox: sandbox))
        let catalog = SkillCatalog.load(
            skillFolders: [
                SkillCatalog.Location(url: root.appendingPathComponent(".umbra/skills"), label: ".umbra/skills"),
                SkillCatalog.Location(url: root.appendingPathComponent(".claude/skills"), label: ".claude/skills"),
            ],
            commandFolders: [
                SkillCatalog.Location(url: root.appendingPathComponent(".umbra/commands"), label: ".umbra/commands"),
                SkillCatalog.Location(url: root.appendingPathComponent(".claude/commands"), label: ".claude/commands"),
            ])
        if !catalog.skills.isEmpty { tools.append(SkillTool(catalog: catalog)) }
        tools += [TodoTool(), AskUserTool(), ExitPlanModeTool(), ExploreTool()]
        // Subagent definitions from the same folders as the app (`agents`), built-ins last.
        let agents = AgentCatalog.load(folders: [
            SkillCatalog.Location(url: root.appendingPathComponent(".umbra/agents"), label: ".umbra/agents"),
            SkillCatalog.Location(url: root.appendingPathComponent(".claude/agents"), label: ".claude/agents"),
        ])
        tools.append(TaskTool(catalog: agents))
        if let memoryDirectory = memoryDirectory(store: store, root: root) {
            tools.append(RememberTool(memoryDirectory: memoryDirectory))
        }
        var hub: MCPHub?
        if request.allowMCP {
            do {
                hub = try await startProjectMCP(root: root, environment: environment)
                if let hub { tools += await hub.tools }
            } catch {
                return failure(
                    request: request, sessionID: resumed?.id ?? UUID(), text: "",
                    message: "Could not start the project's MCP servers: \(error)")
            }
        }

        let modelName = setup.model
        let projectNotes = loadProjectNotes(root: root)
        let memoryText = memoryDirectory(store: store, root: root).flatMap { ProjectMemory.load(at: $0) }
        let configuration = AgentConfiguration(
            model: modelName,
            systemPrompt: SystemPrompt.make(
                projectRoot: root.path, notes: projectNotes, mode: request.mode,
                userNotes: loadUserNotes(), memory: memoryText),
            reasoningEffort: setup.reasoningEffort,
            maxIterations: request.maxIterations ?? AgentConfiguration(model: "").maxIterations,
            approval: .askForCommands,
            contextWindow: setup.contextWindow,
            compactionThreshold: request.provider.provider == .ollama ? 0.60 : setup.compactionThreshold,
            mode: request.mode,
            permissions: rules,
            shapeToolOutput: { IDEAgentOutputScrubber.shape($0) },
            currentInstructions: {
                InstructionSnapshot(name: "AGENTS.md", text: loadProjectNotes(root: root))
            },
            instructionsBaseline: projectNotes)
        var configurationWithBudgets = configuration
        if let maxTokens = request.maxRunTokens, maxTokens > 0 { configurationWithBudgets.maxRunTokens = maxTokens }
        if let maxSeconds = request.maxRunSeconds, maxSeconds > 0 { configurationWithBudgets.maxRunSeconds = maxSeconds }

        let sessionID = resumed?.id ?? UUID()
        let session = AgentSession(
            client: setup.client, tools: tools,
            workspace: DiskAgentWorkspace(root: root),
            configuration: configurationWithBudgets,
            history: resumed?.items ?? [],
            totalUsage: resumed?.totalUsage ?? TokenUsage(),
            sessionID: sessionID)

        var texts: [String] = []
        var refusals: [UmbraAgentRefusal] = []
        var usage = resumed?.totalUsage ?? TokenUsage()
        var ending: RunEnding = .failed("The run ended without an answer.")
        let stream = await session.send(request.prompt)
        for await event in stream {
            onEvent?(event)
            if request.output == .streamJson, let line = streamEventLine(event) {
                print(line)
            }
            switch event {
            case .assistantMessage(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                texts.append(text)
            case .approvalRequested(let approval):
                refusals.append(UmbraAgentRefusal(
                    kind: "approval", title: approval.title,
                    command: approval.command.isEmpty ? nil : approval.command))
                await session.resolveApproval(
                    callID: approval.callID,
                    decision: .deny(note: "Non-interactive run: approvals need a person. Rerun with --mode auto or add an allow rule."))
            case .questionAsked(let question):
                refusals.append(UmbraAgentRefusal(kind: "question", title: question.question))
                await session.answerQuestion(callID: question.callID, answer: nil)
            case .planProposed(let callID, let plan):
                refusals.append(UmbraAgentRefusal(kind: "plan", title: String(plan.prefix(120))))
                await session.resolvePlan(callID: callID, decision: .revise("Non-interactive run: plans need a person."))
            case .usage(let delta):
                usage = TokenUsage(
                    inputTokens: usage.inputTokens + delta.inputTokens,
                    outputTokens: usage.outputTokens + delta.outputTokens,
                    cachedInputTokens: usage.cachedInputTokens + delta.cachedInputTokens,
                    reasoningTokens: usage.reasoningTokens + delta.reasoningTokens)
            case .runEnded(let end):
                ending = end
            default:
                break
            }
        }
        if let hub { await hub.close() }

        let text = texts.joined(separator: "\n\n")
        let exitCode: UmbraAgentExitCode
        switch ending {
        case .completed where !refusals.isEmpty:
            exitCode = .approvalRefused
        case .completed:
            exitCode = .finished
        case .budget, .iterationCap where refusals.isEmpty:
            exitCode = .budget
        case .budget, .iterationCap:
            exitCode = .approvalRefused
        default:
            exitCode = refusals.isEmpty ? .error : .approvalRefused
        }

        let result = UmbraAgentRunResult(
            exitCode: exitCode, ending: ending, text: text, refusals: refusals,
            usage: usage, sessionID: sessionID,
            providerName: request.provider.provider.rawValue, model: modelName,
            workingDirectory: root.path)
        await persist(store: store, root: root, session: session, sessionID: sessionID, prompt: request.prompt)
        return result
    }

    // MARK: - Sessions

    static func store(for request: UmbraAgentRunRequest) -> SessionStore {
        if let directory = request.sessionsDirectory { return SessionStore(directory: directory) }
        if let directory = try? SessionStore.defaultDirectory(appFolder: "com.umbra.editor") {
            return SessionStore(directory: directory)
        }
        return SessionStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()))
    }

    static func memoryDirectory(store: SessionStore, root: URL) -> URL? {
        store.projectDirectory(for: root.path)
    }

    /// Saved synchronously before the run returns: a CLI process may exit at once,
    /// and a detached save would lose the history.
    static func persist(
        store: SessionStore, root: URL, session: AgentSession, sessionID: UUID, prompt: String
    ) async {
        let items = await session.items
        let usage = await session.totalUsage
        guard !items.isEmpty else { return }
        let snapshot = SessionSnapshot(
            id: sessionID, projectRoot: root.path,
            title: SessionStore.title(from: items),
            items: items, totalUsage: usage)
        try? store.save(snapshot)
    }

    static func failure(
        request: UmbraAgentRunRequest, sessionID: UUID, text: String, message: String
    ) -> UmbraAgentRunResult {
        UmbraAgentRunResult(
            exitCode: .error, ending: .failed(message), text: text, refusals: [],
            usage: TokenUsage(), sessionID: sessionID,
            providerName: request.provider.provider.rawValue, model: request.provider.model,
            workingDirectory: request.workingDirectory.path)
    }

    // MARK: -Instructions, skills, MCP

    static func loadProjectNotes(root: URL) -> String? {
        for name in ["AGENTS.md", "CLAUDE.md"] {
            let url = root.appendingPathComponent(name)
            if let text = try? String(contentsOf: url, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    static func loadUserNotes() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/CLAUDE.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// Project MCP servers (`.umbra/mcp.json`, then `.mcp.json`), started only behind
    /// `--allow-mcp`. A missing or broken file means no servers, never a failed run.
    public static func startProjectMCP(root: URL, environment: [String: String]) async throws -> MCPHub? {
        var servers: [MCPServerConfig] = []
        for name in [".umbra/mcp.json", ".mcp.json"] {
            let url = root.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            if let file = try? MCPConfigFile.parse(data) { servers += file.servers }
        }
        guard !servers.isEmpty else { return nil }
        let hub = MCPHub(servers: servers, trimming: .standard) { config in
            switch config.transport {
            case .stdio(let command, let args, let env):
                var merged = environment
                for (key, value) in env { merged[key] = value }
                return try UmbraAgentProcessTransport(command: command, args: args, environment: merged)
            case .http(let url, let headers):
                guard let endpoint = URL(string: url) else {
                    throw RunError.message("“\(config.name)” is not a valid http or https URL.")
                }
                return MCPHTTPTransport(url: endpoint, headers: headers)
            }
        }
        await hub.start()
        return hub
    }

    // MARK: - stream-json

    static func streamEventLine(_ event: AgentEvent) -> String? {
        func line(_ object: [String: Any]) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8)
            else { return "" }
            return text
        }
        switch event {
        case .textDelta(let text):
            return line(["type": "text_delta", "text": text])
        case .assistantMessage(let text):
            return line(["type": "assistant_message", "text": text])
        case .toolCallStarted(let id, let name):
            return line(["type": "tool_call_started", "id": id, "name": name])
        case .toolCallFinished(let id, let name, let output):
            return line(["type": "tool_call_finished", "id": id, "name": name, "output": output.text])
        case .approvalRequested(let approval):
            return line(["type": "approval_requested", "id": approval.callID, "title": approval.title, "command": approval.command])
        case .questionAsked(let question):
            return line(["type": "question_asked", "id": question.callID, "question": question.question])
        case .planProposed(let callID, let plan):
            return line(["type": "plan_proposed", "id": callID, "plan": plan])
        case .usage(let delta):
            return line(["type": "usage", "input_tokens": delta.inputTokens, "output_tokens": delta.outputTokens])
        case .runEnded(let ending):
            return line(["type": "run_ended", "ending": endingName(ending)])
        case .runStarted(let id):
            return line(["type": "run_started", "run": id.uuidString])
        default:
            return nil
        }
    }

    static func endingName(_ ending: RunEnding) -> String {
        UmbraAgentRunResult.endingName(ending)
    }
}

/// An `ACPTransport` over a child process (stdio MCP servers), so the CLI and `UmbraACP`
/// can start project servers without the app's `IDEACPTransport`.
final class UmbraAgentProcessTransport: ACPTransport, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    let incoming: AsyncStream<Data>

    init(command: String, args: [String] = [], environment: [String: String] = [:]) throws {
        var continuation: AsyncStream<Data>.Continuation!
        incoming = AsyncStream { continuation = $0 }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        var base = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                    "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
        for (key, value) in environment { base[key] = value }
        process.environment = base
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        let captured = continuation!
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; captured.finish() }
            else { captured.yield(data) }
        }
        do {
            try process.run()
        } catch {
            throw UmbraAgentHeadlessRun.RunError.message("Could not start MCP server “\(command)”: \(error.localizedDescription)")
        }
    }

    func send(_ line: Data) async throws {
        try input.fileHandleForWriting.write(contentsOf: line + Data([10]))
    }

    func close() async {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
