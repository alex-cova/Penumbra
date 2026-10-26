import AgentKit
import AgentKitApple
import AgentKitMLX
import Foundation
import LocalModelStore

/// Builds model clients from a snapshot of the agent settings, so a child session running off the
/// main actor can resolve a model key without touching the settings object. The main chat builds
/// its client the same way, so there is one construction path for both.
struct IDEAgentClientFactory: Sendable {
    var baseURLs: [IDEAgentProvider: String]
    var keyStore: any IDEAgentKeyStore
    var transport: any LLMTransport
    var ollamaModels: [OllamaModel]
    var installedMLXModels: [InstalledLocalModel]
    var localContextLength: Int
    var contextWindowOverride: Int
    var appleStatuses: [AppleModelKind: AppleModelStatus]
    var appleWindows: [AppleModelKind: Int]
    /// Hosted windows by model-name prefix, longest first. Only used to decide when to compact.
    var hostedContextWindows: [(prefix: String, tokens: Int)]
    /// The helper model for chores, if the user set one. Resolved as the `helper` key.
    var helper: IDEAIModelChoice?

    // MARK: - Endpoint

    func baseURL(for provider: IDEAgentProvider) -> String {
        baseURLs[provider] ?? provider.defaultBaseURL
    }

    func endpointURL(for provider: IDEAgentProvider) -> URL? {
        guard provider.hasEndpoint else { return nil }
        let trimmed = baseURL(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil
        else { return nil }
        return url
    }

    func endpointHost(for provider: IDEAgentProvider) -> String {
        switch provider {
        case .mlx, .apple: "this Mac"
        // Not a host, but the key the one-time "Allow Sending" consent is remembered under.
        case .applePCC: "Apple Private Cloud Compute"
        default: endpointURL(for: provider)?.host() ?? baseURL(for: provider)
        }
    }

    /// A server on this Mac: nothing leaves it, so it needs no key and no consent.
    func isLocalEndpoint(for provider: IDEAgentProvider) -> Bool {
        if provider == .mlx || provider == .apple { return true }
        guard let host = endpointURL(for: provider)?.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost")
    }

    // MARK: - API key

    /// A remote OpenAI-style endpoint needs a key; a local one, and Ollama, use one only if saved
    /// (Ollama behind a proxy may want a Bearer [REDACTED]).
    func requiresAPIKey(for provider: IDEAgentProvider) -> Bool {
        provider != .ollama && provider.hasEndpoint && !isLocalEndpoint(for: provider)
    }

    func apiKey(for provider: IDEAgentProvider) -> String? {
        try? keyStore.load(account: endpointHost(for: provider))
    }

    // MARK: - Models

    func selectedOllamaModel(named name: String) -> OllamaModel? {
        ollamaModels.first { $0.name == name }
    }

    func selectedMLXModel(id: String) -> InstalledLocalModel? {
        installedMLXModels.first { $0.id == id }
    }

    /// The window actually requested: the user's cap, limited by what the model supports.
    func effectiveContextLength(for choice: IDEAIModelChoice) -> Int {
        let limit: Int? = choice.provider == .mlx
            ? selectedMLXModel(id: choice.model).flatMap { MLXModelInspector.inspect(directory: $0.directory).contextLength }
            : selectedOllamaModel(named: choice.model)?.contextLength
        return min(localContextLength, limit ?? localContextLength)
    }

    func appleWindow(for kind: AppleModelKind) -> Int? {
        appleWindows[kind] ?? (kind == .onDevice ? AppleModelAvailability.onDeviceContextSize : nil)
    }

    /// The window compaction measures against. Local models use what was requested from them; a hosted
    /// one uses the override, else the table, else nothing (compaction then waits for an overflow).
    func contextWindow(for choice: IDEAIModelChoice) -> Int? {
        if let kind = choice.provider.appleKind { return appleWindow(for: kind) }
        if choice.provider.isLocal { return effectiveContextLength(for: choice) }
        if contextWindowOverride > 0 { return contextWindowOverride }
        let name = choice.model.lowercased()
        return hostedContextWindows.first { name.hasPrefix($0.prefix) }?.tokens
    }

    /// `requiresTools: false` is plain chat: a model the server or its chat template says cannot call
    /// tools is fine, since none are offered.
    func client(for choice: IDEAIModelChoice, requiresTools: Bool = true) throws -> any LLMClient {
        let provider = choice.provider
        if let kind = provider.appleKind {
            if let message = AppleModelAvailability.message(for: appleStatuses[kind] ?? .unavailable("Apple Intelligence is not available."), kind: kind) {
                throw IDEAgentSettings.ConfigurationError.appleUnavailable(message)
            }
            return AppleLLMClient(kind: kind)
        }
        guard !choice.model.trimmingCharacters(in: .whitespaces).isEmpty else { throw IDEAgentSettings.ConfigurationError.missingModel }
        if provider == .mlx { return try makeMLXClient(model: choice.model, requiresTools: requiresTools) }
        guard let url = endpointURL(for: provider) else { throw IDEAgentSettings.ConfigurationError.invalidBaseURL }
        let key = apiKey(for: provider).flatMap { $0.isEmpty ? nil : $0 }
        if requiresAPIKey(for: provider), key == nil { throw IDEAgentSettings.ConfigurationError.missingAPIKey(host: endpointHost(for: provider)) }
        let endpoint = LLMEndpoint(baseURL: url, apiKey: key)

        switch provider {
        case .openAIResponses:
            return OpenAIResponsesClient(endpoint: endpoint)
        case .chatCompletions:
            // The real OpenAI takes strict tools and a cache key; other servers get the conservative subset.
            let isOpenAI = endpointHost(for: provider) == "api.openai.com"
            return OpenAIChatCompletionsClient(endpoint: endpoint, capabilities: isOpenAI ? .openAI : .compatible)
        case .anthropic:
            return AnthropicMessagesClient(endpoint: endpoint)
        case .meta:
            // Meta's Model API is Responses-compatible and takes a Bearer [REDACTED], so it reuses `OpenAIResponsesClient`.
            return OpenAIResponsesClient(endpoint: endpoint)
        case .ollama:
            let info = selectedOllamaModel(named: choice.model)
            // Only refuse on what the server told us: with no list loaded, the request decides.
            if requiresTools, let info, !info.capabilities.isEmpty, !info.supportsTools {
                throw IDEAgentSettings.ConfigurationError.modelCannotUseTools(info.name)
            }
            return OllamaClient(
                endpoint: endpoint, contextLength: effectiveContextLength(for: choice),
                supportsThinking: info?.supportsThinking ?? false)
        case .mlx:
            return try makeMLXClient(model: choice.model, requiresTools: requiresTools)
        case .apple, .applePCC:
            preconditionFailure("handled above")
        }
    }

    private func makeMLXClient(model: String, requiresTools: Bool) throws -> MLXLLMClient {
        let status = MLXAvailability.currentStatus()
        guard status == .available else { throw IDEAgentSettings.ConfigurationError.mlxUnavailable(MLXAvailability.message(for: status)) }
        guard let installed = selectedMLXModel(id: model) else { throw IDEAgentSettings.ConfigurationError.modelNotInstalled(model) }
        // The template decides whether the model can be asked to call a function at all.
        let info = MLXModelInspector.inspect(directory: installed.directory)
        if requiresTools, info.hasChatTemplate, !info.supportsTools { throw IDEAgentSettings.ConfigurationError.modelCannotUseTools(installed.id) }
        return MLXLLMClient(model: installed, settings: MLXGenerationSettings())
    }

    // MARK: - Child resolution

    /// The smallest window a helper may have: the 6 KB explore report and 15 iterations need room.
    static let helperWindowFloor = 16_384

    /// Why the helper cannot be used: no tool support, a window below the floor, a model that is
    /// gone, or a backend that is down. `nil` when none is set or it passes. A model that fails
    /// stays selectable in Settings (so the reason shows there); sessions ignore it.
    func helperIssue() -> String? {
        guard let helper else { return nil }
        let name = "“\(helper.model)”"
        let suffix = "Explore and summaries run on the main model."
        switch helper.provider {
        case .ollama:
            if let info = selectedOllamaModel(named: helper.model),
               !info.capabilities.isEmpty, !info.supportsTools {
                return "Helper model \(name) is not usable: it has no tool support. \(suffix)"
            }
        case .mlx:
            let status = MLXAvailability.currentStatus()
            guard status == .available else {
                return "Helper model \(name) is not usable: \(MLXAvailability.message(for: status)) \(suffix)"
            }
            guard let installed = selectedMLXModel(id: helper.model) else {
                return "Helper model \(name) is not usable: it is not downloaded. \(suffix)"
            }
            let info = MLXModelInspector.inspect(directory: installed.directory)
            if info.hasChatTemplate, !info.supportsTools {
                return "Helper model \(name) is not usable: it has no tool support. \(suffix)"
            }
        case .apple, .applePCC:
            guard let kind = helper.provider.appleKind else { return nil }
            if let message = AppleModelAvailability.message(
                for: appleStatuses[kind] ?? .unavailable("Apple Intelligence is not available."), kind: kind) {
                return "Helper model \(name) is not usable: \(message) \(suffix)"
            }
        default:
            break
        }
        if let window = contextWindow(for: helper), window < Self.helperWindowFloor {
            return "Helper model \(name) is not usable: its \(window.formatted())-token window is below the \(Self.helperWindowFloor.formatted())-token floor. \(suffix)"
        }
        return nil
    }

    /// Resolves a model key to a client for a child session: `helper`, or a `provider:model` id
    /// such as `ollama:qwen3-coder:30b` or `mlx:my-org/my-model`. Throws when the key names no
    /// helper, a helper that fails the gate, or no usable model; the session then runs the child
    /// on the parent's model.
    func childClient(for key: String) throws -> ChildClient {
        let choice: IDEAIModelChoice
        if key == "helper" {
            guard let helper else { throw IDEAgentSettings.ConfigurationError.noHelperModel }
            if let issue = helperIssue() { throw IDEAgentSettings.ConfigurationError.helperUnavailable(issue) }
            choice = helper
        } else if let parsed = IDEAIModelChoice(parsing: key) {
            choice = parsed
        } else {
            throw IDEAgentSettings.ConfigurationError.unknownModel(key)
        }
        let client = try client(for: choice, requiresTools: true)
        return ChildClient(client: client, model: choice.model, contextWindow: contextWindow(for: choice))
    }
}
