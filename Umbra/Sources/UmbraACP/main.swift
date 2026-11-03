import AgentKit
import Foundation
import UmbraAgentSupport

/// Umbra as an ACP agent (server) on stdio: any ACP client (e.g. Zed) can drive Umbra's
/// built-in agent. Build/run: `swift run UmbraACP [--provider openai|chat|anthropic|meta|ollama|mlx|apple|apple-pcc]
/// [--model <name>] [--base-url <url>] [--allow-mcp] [--sandbox]`.
///
/// Provider configuration comes from, in order: flags, `UMBRA_ACP_*` environment, then the
/// user's Umbra settings (`com.umbra.editor` defaults; the API key from the environment or
/// Umbra's Keychain service). Nothing is printed to stdout except ACP frames; diagnostics
/// go to stderr.
///
/// Parity with the app comes from `UmbraAgentSupport` (docs/harness/agent-harness-6.md
/// Phase 3): every provider through the shared factory, the same permission files, the
/// host-independent `run_command`, and project MCP servers behind `--allow-mcp`. Command
/// approvals reach the ACP client as `session/request_permission` (see `ACPAgentEndpoint`).
final class ACPStdioTransport: ACPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private var closedFlag = false
    let incoming: AsyncStream<Data>

    init() {
        var captured: AsyncStream<Data>.Continuation?
        incoming = AsyncStream<Data> { captured = $0 }
        continuation = captured
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                FileHandle.standardInput.readabilityHandler = nil
                self.lock.withLock { self.continuation }?.finish()
            } else {
                self.lock.withLock { self.continuation }?.yield(data)
            }
        }
    }

    func send(_ line: Data) async throws {
        lock.withLock {
            if closedFlag { return }
            var frame = line
            if !frame.isEmpty, frame.last != UInt8(ascii: "\n") { frame.append(UInt8(ascii: "\n")) }
            FileHandle.standardOutput.write(frame)
        }
    }

    func close() async {
        let continuation: AsyncStream<Data>.Continuation? = lock.withLock {
            closedFlag = true
            let captured = self.continuation
            self.continuation = nil
            return captured
        }
        FileHandle.standardInput.readabilityHandler = nil
        continuation?.finish()
    }
}

struct ACPOptions {
    var provider: String
    var model: String
    var baseURL: String?
    var reasoning: String?
    var allowMCP: Bool
    var sandbox: Bool

    /// Umbra's settings live under the app's defaults domain and `com.umbra.editor.agent` keys.
    static func load() -> ACPOptions {
        let defaults = UserDefaults(suiteName: "com.umbra.editor") ?? .standard
        let env = ProcessInfo.processInfo.environment
        let arguments = Array(CommandLine.arguments.dropFirst())
        func flag(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let providerRaw = defaults.string(forKey: "umbra.agent.provider") ?? "responses"
        // IDEAgentSettings stores per-provider fields: bare keys for Responses, suffixed otherwise.
        func field(_ name: String) -> String? {
            providerRaw == "responses"
                ? defaults.string(forKey: "umbra.agent.\(name)")
                : defaults.string(forKey: "umbra.agent.\(name).\(providerRaw)")
        }
        let provider: String
        switch providerRaw {
        case "responses": provider = "openai"
        case "chat": provider = "chat"
        default: provider = providerRaw
        }
        return ACPOptions(
            provider: flag("--provider") ?? env["UMBRA_ACP_PROVIDER"] ?? provider,
            model: flag("--model") ?? env["UMBRA_ACP_MODEL"] ?? field("model") ?? "",
            baseURL: flag("--base-url") ?? env["UMBRA_ACP_BASE_URL"] ?? field("baseURL"),
            reasoning: field("reasoning"),
            allowMCP: arguments.contains("--allow-mcp") || env["UMBRA_ACP_ALLOW_MCP"] == "1",
            sandbox: arguments.contains("--sandbox") || env["UMBRA_ACP_SANDBOX"] == "1")
    }
}

enum ACPHostError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let text) = self { text } else { "" } }
}

/// The `UmbraAgentCommandHost` for ACP sessions: commands run in the session's cwd with a
/// built environment; progress goes to stderr (stdout carries ACP frames only).
struct ACPCommandHost: UmbraAgentCommandHost {
    var projectRoot: URL
    var environment: [String: String]

    func commandEnvironment() async -> [String: String] { environment }

    func showCommand(id: UUID, title: String, line: String?) {
        if let line { FileHandle.standardError.write(Data(line.utf8)) }
    }
}

/// MCP hubs by project root, kept for the life of the process so a session's tools stay live.
actor ACPHubStore {
    private var hubs: [String: MCPHub] = [:]

    func hub(for root: URL, environment: [String: String]) async throws -> MCPHub? {
        if let existing = hubs[root.path] { return existing }
        guard let hub = try await UmbraAgentHeadlessRun.startProjectMCP(root: root, environment: environment) else {
            return nil
        }
        hubs[root.path] = hub
        return hub
    }
}

func endpointURL(_ text: String?, fallback: String) throws -> URL {
    let value = text ?? fallback
    guard let url = URL(string: value), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil else {
        throw ACPHostError.message("“\(value)” is not an http(s) URL.")
    }
    return url
}

@main
struct UmbraACP {
    static func main() async {
        let options = ACPOptions.load()
        guard let provider = UmbraAgentProvider(name: options.provider) else {
            FileHandle.standardError.write(Data(
                "UmbraACP: unknown provider “\(options.provider)”. Use openai|chat|anthropic|meta|ollama|mlx|apple|apple-pcc.\n".utf8))
            exit(2)
        }
        let setup: UmbraAgentProviderSetup
        do {
            setup = try await UmbraAgentProviderFactory.make(UmbraAgentProviderConfig(
                provider: provider, model: options.model, baseURL: options.baseURL,
                reasoningEffort: options.reasoning, keyStore: IDEAgentKeychain()))
        } catch {
            FileHandle.standardError.write(Data("UmbraACP: \(error)\n".utf8))
            exit(2)
        }
        let transport = ACPStdioTransport()
        // Tests and operators can redirect session storage; otherwise the app's own store is used.
        let store: URL? = ProcessInfo.processInfo.environment["UMBRA_ACP_SESSIONS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? (try? SessionStore.defaultDirectory(appFolder: "com.umbra.editor"))
        let hubs = ACPHubStore()
        let endpoint = ACPAgentEndpoint(
            transport: transport,
            agentInfo: ACPImplementation(name: "Umbra Agent", version: "1.0"),
            contextWindow: setup.contextWindow,
            sessionStore: store.map(SessionStore.init(directory:))
        ) { request in
            let root = URL(fileURLWithPath: request.cwd)
            let workspace = ACPRemoteWorkspace(
                local: DiskAgentWorkspace(root: root),
                remoteFileReader: request.remoteFileReader)
            let environment = AgentCommandEnvironment.make(javaHome: nil)
            let sandbox: IDEAgentSandboxChoice? =
                (options.sandbox && IDEAgentSandbox.isAvailable)
                ? IDEAgentSandboxChoice(profile: IDEAgentSandboxProfile.make(projectRoot: root.path)) : nil
            var tools: [any AgentTool] = ReadOnlyTools.all() + EditingTools.all()
            tools.append(UmbraAgentRunCommandTool(
                host: ACPCommandHost(projectRoot: root, environment: environment), sandbox: sandbox))
            tools += [TodoTool(), AskUserTool(), ExitPlanModeTool()]
            if options.allowMCP, let hub = try await hubs.hub(for: root, environment: environment) {
                tools += await hub.tools
            }
            return AgentSession(
                client: setup.client, tools: tools, workspace: workspace,
                configuration: AgentConfiguration(
                    model: setup.model,
                    systemPrompt: SystemPrompt.make(projectRoot: request.cwd),
                    reasoningEffort: setup.reasoningEffort,
                    contextWindow: setup.contextWindow,
                    compactionThreshold: provider == .ollama ? 0.60 : setup.compactionThreshold,
                    mode: .acceptEdits,
                    permissions: IDEAgentPermissionFiles.load(
                        projectRoot: root, appFile: IDEAgentPermissionFiles.appFile()),
                    shapeToolOutput: { IDEAgentOutputScrubber.shape($0) }),
                history: request.history,
                totalUsage: request.totalUsage,
                sessionID: request.sessionID ?? UUID())
        }
        await endpoint.run()
    }
}
