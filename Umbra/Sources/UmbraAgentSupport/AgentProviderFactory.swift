import AgentKit
import AgentKitApple
import AgentKitMLX
import Foundation
import LocalModelStore

/// Which model API a headless host (the `umbra-agent` CLI, `UmbraACP`) talks to.
///
/// Raw values match the `--provider` flag, `UMBRA_ACP_PROVIDER`, and the app's
/// `IDEAgentProvider` cases, so the three construction sites stay in agreement.
public enum UmbraAgentProvider: String, Sendable, CaseIterable {
    case openAIResponses = "openai"
    case chatCompletions = "chat"
    case anthropic = "anthropic"
    case meta = "meta"
    case ollama = "ollama"
    case mlx = "mlx"
    case apple = "apple"
    case applePCC = "apple-pcc"

    public init?(name: String) {
        let lowered = name.lowercased()
        if lowered == "responses" {
            self = .openAIResponses
            return
        }
        self.init(rawValue: lowered)
    }

    public var displayName: String {
        switch self {
        case .openAIResponses: "OpenAI (Responses)"
        case .chatCompletions: "OpenAI-compatible (Chat Completions)"
        case .anthropic: "Anthropic (Claude)"
        case .meta: "Meta (Muse)"
        case .ollama: "Ollama"
        case .mlx: "On this Mac (MLX)"
        case .apple: "Apple Intelligence (on this Mac)"
        case .applePCC: "Apple Private Cloud Compute"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAIResponses, .chatCompletions: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .meta: "https://api.meta.ai/v1"
        case .ollama: "http://localhost:11434"
        case .mlx, .apple, .applePCC: ""
        }
    }

    /// Environment variable holding this provider's key. CLI runs read keys from the
    /// environment (or the Keychain); never from a command-line argument.
    public var apiKeyEnvironmentVariable: String? {
        switch self {
        case .openAIResponses, .chatCompletions: "OPENAI_API_KEY"
        case .anthropic: "ANTHROPIC_API_KEY"
        case .meta: "META_API_KEY"
        case .ollama, .mlx, .apple, .applePCC: nil
        }
    }

    public var hasEndpoint: Bool {
        switch self {
        case .mlx, .apple, .applePCC: false
        case .openAIResponses, .chatCompletions, .anthropic, .meta, .ollama: true
        }
    }

    public var isLocal: Bool {
        switch self {
        case .ollama, .mlx, .apple: true
        case .openAIResponses, .chatCompletions, .anthropic, .meta, .applePCC: false
        }
    }
}

/// Everything `UmbraAgentProviderFactory.make` needs: the provider and model, an optional
/// base-URL override, the reasoning effort (`nil` or `"off"` sends none), and key material.
/// `apiKey` wins; when it is nil the factory falls back to the provider's environment
/// variable and then to `keyStore`.
public struct UmbraAgentProviderConfig: Sendable {
    public var provider: UmbraAgentProvider
    public var model: String
    public var baseURL: String?
    public var reasoningEffort: String?
    public var apiKey: String?
    public var contextWindow: Int?
    public var keyStore: (any IDEAgentKeyStore)?

    public init(
        provider: UmbraAgentProvider,
        model: String,
        baseURL: String? = nil,
        reasoningEffort: String? = nil,
        apiKey: String? = nil,
        contextWindow: Int? = nil,
        keyStore: (any IDEAgentKeyStore)? = nil
    ) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.reasoningEffort = reasoningEffort
        self.apiKey = apiKey
        self.contextWindow = contextWindow
        self.keyStore = keyStore
    }
}

public struct UmbraAgentProviderSetup: Sendable {
    public var client: any LLMClient
    public var contextWindow: Int?
    public var compactionThreshold: Double
    public var model: String
    public var reasoningEffort: String?

    public init(
        client: any LLMClient, contextWindow: Int? = nil,
        compactionThreshold: Double = 0.75, model: String, reasoningEffort: String? = nil
    ) {
        self.client = client
        self.contextWindow = contextWindow
        self.compactionThreshold = compactionThreshold
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

public enum UmbraAgentProviderError: Error, CustomStringConvertible, Sendable {
    case message(String)

    public var description: String {
        if case .message(let text) = self { return text }
        return ""
    }
}

/// The one provider-construction path for every headless host. The app's own
/// `IDEAgentClientFactory` covers the interactive session (settings UI, helper models);
/// `UmbraACP`, the `umbra-agent` CLI, and tests build their client here so a provider
/// addition lands once.
public enum UmbraAgentProviderFactory {
    public static let defaultLocalContext = 32_768

    public static func make(_ config: UmbraAgentProviderConfig) async throws -> UmbraAgentProviderSetup {
        let model = config.model.trimmingCharacters(in: .whitespaces)
        let reasoning = config.reasoningEffort == "off" ? nil : config.reasoningEffort
        switch config.provider {
        case .apple:
            return try apple(.onDevice, model: model, reasoning: reasoning)
        case .applePCC:
            return try apple(.privateCloudCompute, model: model, reasoning: reasoning)
        case .ollama:
            return try await ollama(model: model, config: config, reasoning: reasoning)
        case .mlx:
            return try mlx(model: model, config: config, reasoning: reasoning)
        case .openAIResponses, .chatCompletions, .anthropic, .meta:
            return try remote(model: model, config: config, reasoning: reasoning)
        }
    }

    // MARK: - Endpoints

    static func endpointURL(baseURL: String?, fallback: String) throws -> URL {
        let text = baseURL ?? fallback
        guard let url = URL(string: text),
              let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil
        else { throw UmbraAgentProviderError.message("“\(text)” is not an http(s) URL.") }
        return url
    }

    static func isLocalHost(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost")
    }

    /// Key resolution order: explicit config, environment, Keychain (by endpoint host).
    /// A remote non-local endpoint without a key throws; local endpoints need none.
    static func apiKey(for provider: UmbraAgentProvider, url: URL, config: UmbraAgentProviderConfig) throws -> String? {
        if let key = config.apiKey, !key.isEmpty { return key }
        let environment = ProcessInfo.processInfo.environment
        if let variable = provider.apiKeyEnvironmentVariable,
           let key = environment[variable], !key.isEmpty {
            return key
        }
        if provider == .openAIResponses || provider == .chatCompletions,
           let key = environment["UMBRA_ACP_API_KEY"], !key.isEmpty {
            return key
        }
        if let host = url.host(), let store = config.keyStore {
            if let key = try? store.load(account: host), !(key.isEmpty) { return key }
        }
        if isLocalHost(url) || provider == .ollama { return nil }
        throw UmbraAgentProviderError.message(
            "No API key for \(url.host() ?? "the server"). Set \(provider.apiKeyEnvironmentVariable ?? "the API key") or save one in Umbra's agent settings.")
    }

    // MARK: - Providers

    private static func remote(
        model: String, config: UmbraAgentProviderConfig, reasoning: String?
    ) throws -> UmbraAgentProviderSetup {
        guard !model.isEmpty else {
            throw UmbraAgentProviderError.message("No model configured. Pass --model or set one in Umbra's agent settings.")
        }
        let url = try endpointURL(baseURL: config.baseURL, fallback: config.provider.defaultBaseURL)
        let key = try apiKey(for: config.provider, url: url, config: config)
        let endpoint = LLMEndpoint(baseURL: url, apiKey: key)
        switch config.provider {
        case .openAIResponses:
            return UmbraAgentProviderSetup(
                client: OpenAIResponsesClient(endpoint: endpoint),
                contextWindow: config.contextWindow, model: model, reasoningEffort: reasoning)
        case .chatCompletions:
            let isOpenAI = url.host() == "api.openai.com"
            return UmbraAgentProviderSetup(
                client: OpenAIChatCompletionsClient(endpoint: endpoint, capabilities: isOpenAI ? .openAI : .compatible),
                contextWindow: config.contextWindow, model: model, reasoningEffort: reasoning)
        case .anthropic:
            return UmbraAgentProviderSetup(
                client: AnthropicMessagesClient(endpoint: endpoint),
                contextWindow: config.contextWindow, model: model, reasoningEffort: reasoning)
        case .meta:
            // Meta's Model API speaks the OpenAI Responses format with a Bearer [REDACTED].
            return UmbraAgentProviderSetup(
                client: OpenAIResponsesClient.meta(endpoint: endpoint),
                contextWindow: config.contextWindow, model: model, reasoningEffort: reasoning)
        default:
            throw UmbraAgentProviderError.message("Unknown provider “\(config.provider.rawValue)”.")
        }
    }

    private static func ollama(
        model: String, config: UmbraAgentProviderConfig, reasoning: String?
    ) async throws -> UmbraAgentProviderSetup {
        guard !model.isEmpty else {
            throw UmbraAgentProviderError.message("No model configured. Pass --model or set one in Umbra's agent settings.")
        }
        let url = try endpointURL(baseURL: config.baseURL, fallback: UmbraAgentProvider.ollama.defaultBaseURL)
        let models: [OllamaModel]
        do {
            models = try await OllamaModelCatalog(baseURL: url).models()
        } catch {
            throw UmbraAgentProviderError.message("Could not reach Ollama at \(url.absoluteString): \(error.localizedDescription)")
        }
        guard let info = models.first(where: { $0.name == model }) else {
            let names = models.map(\.name).prefix(8).joined(separator: ", ")
            throw UmbraAgentProviderError.message("Ollama has no model “\(model)”. Installed: \(names.isEmpty ? "none" : names)")
        }
        if !info.capabilities.isEmpty, !info.supportsTools {
            throw UmbraAgentProviderError.message("“\(model)” does not support tool calling, which the agent needs.")
        }
        let context = min(config.contextWindow ?? defaultLocalContext, info.contextLength ?? .max)
        return UmbraAgentProviderSetup(
            client: OllamaClient(
                endpoint: LLMEndpoint(baseURL: url, apiKey: nil), contextLength: context,
                supportsThinking: info.supportsThinking),
            contextWindow: context, compactionThreshold: 0.60, model: model, reasoningEffort: reasoning)
    }

    private static func mlx(
        model: String, config: UmbraAgentProviderConfig, reasoning: String?
    ) throws -> UmbraAgentProviderSetup {
        guard !model.isEmpty else {
            throw UmbraAgentProviderError.message("No model configured. Pass --model or set one in Umbra's agent settings.")
        }
        let status = MLXAvailability.currentStatus()
        guard status == .available else { throw UmbraAgentProviderError.message(MLXAvailability.message(for: status)) }
        let root = try LocalModelPaths.defaultRoot(folderName: "com.umbra.editor")
        let installed = LocalModelCatalog(paths: LocalModelPaths(root: root)).installed()
        guard let found = installed.first(where: { $0.id == model }) else {
            let names = installed.map(\.id).joined(separator: ", ")
            throw UmbraAgentProviderError.message("“\(model)” is not installed. Installed: \(names.isEmpty ? "none (download one in Umbra)" : names)")
        }
        let info = MLXModelInspector.inspect(directory: found.directory)
        if info.hasChatTemplate, !info.supportsTools {
            throw UmbraAgentProviderError.message("“\(model)” has a chat template without tool support.")
        }
        let context = min(config.contextWindow ?? defaultLocalContext, info.contextLength ?? .max)
        return UmbraAgentProviderSetup(
            client: MLXLLMClient(model: found, settings: MLXGenerationSettings()),
            contextWindow: context, model: model, reasoningEffort: reasoning)
    }

    private static func apple(
        _ kind: AppleModelKind, model: String, reasoning: String?
    ) throws -> UmbraAgentProviderSetup {
        if let message = AppleModelAvailability.message(for: kind) {
            throw UmbraAgentProviderError.message(message)
        }
        let name = kind == .onDevice ? "apple" : "apple-pcc"
        return UmbraAgentProviderSetup(
            client: AppleLLMClient(kind: kind),
            contextWindow: nil, model: model.isEmpty ? name : model, reasoningEffort: reasoning)
    }
}
