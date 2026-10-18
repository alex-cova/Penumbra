import AgentKit
import AgentKitMLX
import Foundation
import LocalModelStore
import Security

/// Umbra as an ACP agent (plan Phase 2): hosts an `AgentSession` on stdio so any ACP client
/// (e.g. Zed) can drive Umbra's built-in agent. Build/run: `swift run UmbraACP [--provider
/// ollama|openai|chat|mlx] [--model <name>] [--base-url <url>]`.
///
/// Provider configuration comes from, in order: flags, `UMBRA_ACP_*` environment, then the
/// user's Umbra settings (`com.umbra.editor` defaults; the API key from Umbra's Keychain
/// service when no key is in the environment). Nothing is printed to stdout except ACP frames;
/// diagnostics go to stderr.
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
            reasoning: field("reasoning"))
    }

    func apiKey(forHost host: String?) -> String? {
        let env = ProcessInfo.processInfo.environment
        if let key = env["UMBRA_ACP_API_KEY"] ?? env["OPENAI_API_KEY"], !key.isEmpty { return key }
        guard let host else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.umbra.editor.agent",
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum ACPHostError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let text) = self { text } else { "" } }
}

struct ProviderSetup {
    var client: any LLMClient
    var contextWindow: Int?
    var compactionThreshold: Double = 0.75
    var model: String
    var reasoning: String?
}

func makeProvider(_ options: ACPOptions) async throws -> ProviderSetup {
    let model = options.model.trimmingCharacters(in: .whitespaces)
    guard !model.isEmpty else {
        throw ACPHostError.message("No model configured. Set one in Umbra's agent settings, pass --model, or set UMBRA_ACP_MODEL.")
    }
    let reasoning = options.reasoning == "off" ? nil : options.reasoning
    switch options.provider {
    case "ollama":
        let url = try endpointURL(options.baseURL, fallback: OllamaClient.defaultBaseURL.absoluteString)
        let models = try await OllamaModelCatalog(baseURL: url).models()
        guard let info = models.first(where: { $0.name == model }) else {
            throw ACPHostError.message("Ollama has no model “\(model)”. Installed: \(models.map(\.name).joined(separator: ", "))")
        }
        if !info.capabilities.isEmpty, !info.supportsTools {
            throw ACPHostError.message("“\(model)” does not support tool calling, which the agent needs.")
        }
        let context = min(32_768, info.contextLength ?? 32_768)
        return ProviderSetup(
            client: OllamaClient(endpoint: LLMEndpoint(baseURL: url, apiKey: nil), contextLength: context, supportsThinking: info.supportsThinking),
            contextWindow: context, compactionThreshold: 0.60, model: model, reasoning: reasoning)
    case "openai", "chat":
        let url = try endpointURL(options.baseURL, fallback: "https://api.openai.com/v1")
        let key = options.apiKey(forHost: url.host())
        let isLocal = ["localhost", "127.0.0.1", "::1"].contains(url.host()?.lowercased() ?? "")
        if key == nil, !isLocal {
            throw ACPHostError.message("No API key for \(url.host() ?? "the server"). Set UMBRA_ACP_API_KEY or save one in Umbra's agent settings.")
        }
        let endpoint = LLMEndpoint(baseURL: url, apiKey: key)
        let client: any LLMClient = options.provider == "openai"
            ? OpenAIResponsesClient(endpoint: endpoint)
            : OpenAIChatCompletionsClient(endpoint: endpoint, capabilities: url.host() == "api.openai.com" ? .openAI : .compatible)
        return ProviderSetup(client: client, contextWindow: options.baseURL == nil ? nil : nil, model: model, reasoning: reasoning)
    case "mlx":
        let status = MLXAvailability.currentStatus()
        guard status == .available else { throw ACPHostError.message(MLXAvailability.message(for: status)) }
        let root = try LocalModelPaths.defaultRoot(folderName: "com.umbra.editor")
        let installed = LocalModelCatalog(paths: LocalModelPaths(root: root)).installed()
        guard let found = installed.first(where: { $0.id == model }) else {
            throw ACPHostError.message("“\(model)” is not an installed on-device model.")
        }
        let info = MLXModelInspector.inspect(directory: found.directory)
        if info.hasChatTemplate, !info.supportsTools {
            throw ACPHostError.message("“\(model)” has a chat template without tool support.")
        }
        let context = min(32_768, info.contextLength ?? 32_768)
        return ProviderSetup(client: MLXLLMClient(model: found, settings: MLXGenerationSettings()), contextWindow: context, model: model, reasoning: reasoning)
    default:
        throw ACPHostError.message("Unknown provider “\(options.provider)”. Use ollama, openai, chat or mlx.")
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
        let setup: ProviderSetup
        do {
            setup = try await makeProvider(options)
        } catch {
            FileHandle.standardError.write(Data("UmbraACP: \(error)\n".utf8))
            exit(2)
        }
        let transport = ACPStdioTransport()
        // Tests and operators can redirect session storage; otherwise the app's own store is used.
        let store: URL? = ProcessInfo.processInfo.environment["UMBRA_ACP_SESSIONS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? (try? SessionStore.defaultDirectory(appFolder: "com.umbra.editor"))
        let endpoint = ACPAgentEndpoint(
            transport: transport,
            agentInfo: ACPImplementation(name: "Umbra Agent", version: "1.0"),
            contextWindow: setup.contextWindow,
            sessionStore: store.map(SessionStore.init(directory:))
        ) { request in
            let workspace = ACPRemoteWorkspace(
                local: DiskAgentWorkspace(root: URL(fileURLWithPath: request.cwd)),
                remoteFileReader: request.remoteFileReader)
            let tools: [any AgentTool] = ReadOnlyTools.all() + EditingTools.all()
                + [TodoTool(), AskUserTool(), ExitPlanModeTool()]
            return AgentSession(
                client: setup.client, tools: tools, workspace: workspace,
                configuration: AgentConfiguration(
                    model: setup.model,
                    systemPrompt: SystemPrompt.make(projectRoot: request.cwd),
                    reasoningEffort: setup.reasoning,
                    contextWindow: setup.contextWindow,
                    compactionThreshold: setup.compactionThreshold,
                    mode: .acceptEdits),
                history: request.history,
                totalUsage: request.totalUsage,
                sessionID: request.sessionID ?? UUID())
        }
        await endpoint.run()
    }
}
