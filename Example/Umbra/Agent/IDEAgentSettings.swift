import AgentKit
import AgentKitMLX
import Foundation
import LocalModelStore
import Observation

/// Which API the agent talks to.
enum IDEAgentProvider: String, CaseIterable, Identifiable, Sendable {
    case openAIResponses = "responses"
    case chatCompletions = "chat"
    case ollama = "ollama"
    /// Runs a downloaded model in this process on the GPU. Nothing is sent anywhere.
    case mlx = "mlx"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAIResponses: "OpenAI (Responses)"
        case .chatCompletions: "OpenAI-compatible (Chat Completions)"
        case .ollama: "Ollama"
        case .mlx: "On this Mac (MLX)"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAIResponses, .chatCompletions: "https://api.openai.com/v1"
        case .ollama: "http://localhost:11434"
        case .mlx: ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openAIResponses, .chatCompletions: "gpt-5"
        case .ollama, .mlx: ""
        }
    }

    var defaultReasoning: String {
        // A local model that thinks is slow per step; the user turns it on.
        self == .ollama || self == .mlx ? "off" : "medium"
    }
}

/// Agent preferences, kept on this Mac and out of the preferences snapshot. API keys are in the
/// Keychain, one per endpoint host.
@MainActor
@Observable
final class IDEAgentSettings {
    static let shared = IDEAgentSettings()

    static let defaultBaseURL = IDEAgentProvider.openAIResponses.defaultBaseURL
    static let defaultModel = IDEAgentProvider.openAIResponses.defaultModel
    /// "off" sends no `reasoning` field, which models without reasoning require.
    static let reasoningEfforts = ["off", "low", "medium", "high"]
    /// Context sizes offered for local models: the KV cache grows with the window, and so do memory
    /// and prefill time, so the default is modest.
    static let contextChoices = [8_192, 16_384, 32_768, 65_536, 131_072]
    static let defaultContext = 32_768
    static let defaultIterationCap = AgentConfiguration(model: "").maxIterations
    static let iterationCapChoices = [10, 20, 40, 80, 160]

    /// Context windows of hosted models by name prefix, longest prefix first. Only used to decide
    /// when to compact; a wrong guess costs an early or late summary, never a failed request,
    /// because a provider overflow forces compaction anyway.
    static let hostedContextWindows: [(prefix: String, tokens: Int)] = [
        ("gpt-5", 400_000), ("gpt-4.1", 1_000_000), ("gpt-4o", 128_000), ("o4", 200_000), ("o3", 200_000),
    ]

    var provider: IDEAgentProvider {
        didSet {
            guard provider != oldValue else { return }
            defaults.set(provider.rawValue, forKey: Keys.provider)
            refreshKeyState()
        }
    }

    /// Per provider, so switching back and forth keeps each one's URL, model and reasoning.
    private var values: [String: String]

    var baseURL: String {
        get { values[Keys.field("baseURL", provider)] ?? provider.defaultBaseURL }
        set { store(Keys.field("baseURL", provider), newValue) }
    }

    var model: String {
        get { values[Keys.field("model", provider)] ?? provider.defaultModel }
        set { store(Keys.field("model", provider), newValue) }
    }

    var reasoningEffort: String {
        get { values[Keys.field("reasoning", provider)] ?? provider.defaultReasoning }
        set { store(Keys.field("reasoning", provider), newValue) }
    }

    /// The context window for local models, capped by the model's own maximum.
    var localContextLength: Int { didSet { defaults.set(localContextLength, forKey: Keys.context) } }

    /// Extra environment variables for agent commands, one `KEY=VALUE` per line. A `PATH` entry is
    /// added in front of the built path.
    var commandEnvironmentText: String { didSet { defaults.set(commandEnvironmentText, forKey: Keys.commandEnvironment) } }
    /// Whether the chat opens over the editor like Settings (true) or docked beside it (false, the default).
    var opensAsPage: Bool { didSet { defaults.set(opensAsPage, forKey: Keys.page) } }
    /// What the agent may do without asking in a new chat (see `PermissionMode`); each chat can change its own.
    var mode: PermissionMode { didSet { defaults.set(mode.rawValue, forKey: Keys.mode) } }
    /// Model turns per message before the run pauses; `AgentConfiguration.maxIterations` when unset.
    var iterationCap: Int { didSet { defaults.set(iterationCap, forKey: Keys.iterationCap) } }
    /// The context window of a hosted model the built-in table doesn't know; 0 means use the table.
    var contextWindowOverride: Int { didSet { defaults.set(contextWindowOverride, forKey: Keys.contextOverride) } }
    /// Extra globs for files the agent must not read, one per line, on top of the built-in credential list.
    var secretFilePatternsText: String { didSet { defaults.set(secretFilePatternsText, forKey: Keys.secretPatterns) } }
    /// Dollars per million tokens by model prefix, as editable text (see `IDEAgentPrices`).
    var priceTableText: String { didSet { defaults.set(priceTableText, forKey: Keys.prices) } }
    private(set) var disclosedHosts: Set<String>
    /// Whether a key is saved for the current endpoint. Held here so views never read the Keychain.
    private(set) var hasAPIKey = false
    private(set) var keyError: String?

    // Ollama
    private(set) var ollamaModels: [OllamaModel] = []
    private(set) var ollamaError: String?
    private(set) var isLoadingOllamaModels = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keyStore: any IDEAgentKeyStore
    @ObservationIgnored private let transport: any LLMTransport
    @ObservationIgnored private let installedModels: @MainActor () -> [InstalledLocalModel]

    private enum Keys {
        static let provider = "umbra.agent.provider"
        static let context = "umbra.agent.localContext"
        static let disclosed = "umbra.agent.disclosedHosts"
        static let commandEnvironment = "umbra.agent.commandEnvironment"
        static let mode = "umbra.agent.mode"
        static let page = "umbra.agent.opensAsPage"
        static let prices = "umbra.agent.priceTable"
        static let secretPatterns = "umbra.agent.secretFilePatterns"
        static let iterationCap = "umbra.agent.iterationCap"
        static let contextOverride = "umbra.agent.contextWindowOverride"

        /// `umbra.agent.baseURL` for the original (Responses) provider, so earlier settings carry over.
        static func field(_ name: String, _ provider: IDEAgentProvider) -> String {
            provider == .openAIResponses ? "umbra.agent.\(name)" : "umbra.agent.\(name).\(provider.rawValue)"
        }
    }

    init(
        defaults: UserDefaults = .standard,
        keyStore: any IDEAgentKeyStore = IDEAgentKeychain(),
        transport: any LLMTransport = URLSessionTransport(),
        installedModels: @escaping @MainActor () -> [InstalledLocalModel] = { IDELocalModelsStore.shared.installed }
    ) {
        self.defaults = defaults
        self.keyStore = keyStore
        self.transport = transport
        self.installedModels = installedModels
        provider = defaults.string(forKey: Keys.provider).flatMap(IDEAgentProvider.init(rawValue:)) ?? .openAIResponses
        var values: [String: String] = [:]
        for provider in IDEAgentProvider.allCases {
            for name in ["baseURL", "model", "reasoning"] {
                let key = Keys.field(name, provider)
                if let stored = defaults.string(forKey: key) { values[key] = stored }
            }
        }
        self.values = values
        let storedContext = defaults.integer(forKey: Keys.context)
        localContextLength = storedContext > 0 ? storedContext : Self.defaultContext
        commandEnvironmentText = defaults.string(forKey: Keys.commandEnvironment) ?? ""
        opensAsPage = defaults.bool(forKey: Keys.page)
        priceTableText = defaults.string(forKey: Keys.prices) ?? IDEAgentPrices.defaultText
        secretFilePatternsText = defaults.string(forKey: Keys.secretPatterns) ?? ""
        mode = defaults.string(forKey: Keys.mode).flatMap(PermissionMode.init(persisted:)) ?? .acceptEdits
        let storedCap = defaults.integer(forKey: Keys.iterationCap)
        iterationCap = storedCap > 0 ? storedCap : Self.defaultIterationCap
        contextWindowOverride = max(0, defaults.integer(forKey: Keys.contextOverride))
        disclosedHosts = Set(defaults.stringArray(forKey: Keys.disclosed) ?? [])
        refreshKeyState()
    }

    private func store(_ key: String, _ value: String) {
        values[key] = value
        defaults.set(value, forKey: key)
    }

    /// `commandEnvironmentText` as a dictionary; blank lines and `#` comments are skipped.
    var commandEnvironment: [String: String] {
        var result: [String: String] = [:]
        for line in commandEnvironmentText.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    // MARK: - Endpoint

    var endpointURL: URL? {
        guard provider != .mlx else { return nil }
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil
        else { return nil }
        return url
    }

    var endpointHost: String { provider == .mlx ? "this Mac" : (endpointURL?.host() ?? baseURL) }

    /// A server on this Mac: nothing leaves it, so it needs no consent and no key.
    var isLocalEndpoint: Bool {
        if provider == .mlx { return true }
        guard let host = endpointURL?.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost")
    }

    /// The effort to send, or `nil` for "off".
    var effectiveReasoningEffort: String? { reasoningEffort == "off" ? nil : reasoningEffort }

    // MARK: - Disclosure

    /// File contents and command output go to this endpoint, so the first use needs an explicit OK
    /// per host, unless the endpoint is on this Mac. Nothing is sent before the user sends a message.
    var hasAcceptedDisclosure: Bool { isLocalEndpoint || disclosedHosts.contains(endpointHost) }

    func acceptDisclosure() {
        disclosedHosts.insert(endpointHost)
        defaults.set(Array(disclosedHosts).sorted(), forKey: Keys.disclosed)
    }

    // MARK: - API key

    /// A remote OpenAI-style endpoint needs a key; a local one, and Ollama, use one only if saved
    /// (Ollama behind a proxy may want a bearer token).
    var requiresAPIKey: Bool { provider != .ollama && provider != .mlx && !isLocalEndpoint }

    func refreshKeyState() {
        do {
            hasAPIKey = try keyStore.load(account: endpointHost)?.isEmpty == false
            keyError = nil
        } catch {
            hasAPIKey = false
            keyError = error.localizedDescription
        }
    }

    func saveAPIKey(_ key: String) {
        do {
            try keyStore.save(key, account: endpointHost)
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
        refreshKeyState()
    }

    func removeAPIKey() {
        do {
            try keyStore.delete(account: endpointHost)
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
        refreshKeyState()
    }

    func apiKey() -> String? {
        try? keyStore.load(account: endpointHost)
    }

    /// What the panel's empty state asks for, or `nil` when the agent can be used.
    var setupHint: String? {
        if provider == .mlx {
            let status = MLXAvailability.currentStatus()
            if status != .available { return MLXAvailability.message(for: status) }
            if model.isEmpty { return "Download a model under Manage On-Device Models…, then choose it here." }
            if selectedMLXModel == nil { return "“\(model)” is not downloaded. Choose an installed model." }
            return nil
        }
        if endpointURL == nil { return "Set a valid base URL in the agent settings." }
        if provider == .ollama {
            if model.isEmpty { return ollamaError ?? "Choose an Ollama model in the agent settings." }
            return nil
        }
        if requiresAPIKey && !hasAPIKey { return "Add an API key in the agent settings." }
        return nil
    }

    // MARK: - On-device (MLX)

    /// The installed model chosen for the MLX provider.
    var selectedMLXModel: InstalledLocalModel? { installedModels().first { $0.id == model } }

    // MARK: - Ollama

    /// The model's details when the list has been loaded and the model is in it.
    var selectedOllamaModel: OllamaModel? { ollamaModels.first { $0.name == model } }

    /// The window actually requested: the user's cap, limited by what the model supports.
    var effectiveContextLength: Int {
        let limit: Int? = provider == .mlx
            ? selectedMLXModel.flatMap { MLXModelInspector.inspect(directory: $0.directory).contextLength }
            : selectedOllamaModel?.contextLength
        return min(localContextLength, limit ?? localContextLength)
    }

    /// The window compaction measures against. Local models use what was requested from them; a hosted
    /// one uses the override, else the table, else nothing (compaction then waits for an overflow).
    var contextWindow: Int? {
        if provider == .ollama || provider == .mlx { return effectiveContextLength }
        if contextWindowOverride > 0 { return contextWindowOverride }
        let name = model.lowercased()
        return Self.hostedContextWindows.first { name.hasPrefix($0.prefix) }?.tokens
    }

    func refreshOllamaModels() async {
        guard let url = endpointURL else { return }
        isLoadingOllamaModels = true
        defer { isLoadingOllamaModels = false }
        do {
            ollamaModels = try await OllamaModelCatalog(baseURL: url, transport: transport).models()
            ollamaError = nil
            // Keep a valid choice: the saved one if still installed, else the first that can use tools.
            if !ollamaModels.contains(where: { $0.name == model }) {
                model = ollamaModels.first(where: \.supportsTools)?.name ?? ""
            }
            if ollamaModels.isEmpty { ollamaError = "No models are installed. Run `ollama pull <model>`." }
        } catch {
            ollamaModels = []
            ollamaError = error.localizedDescription
        }
    }

    // MARK: - Building a client

    enum ConfigurationError: Error, LocalizedError, Equatable {
        case invalidBaseURL
        case missingAPIKey(host: String)
        case missingModel
        case modelCannotUseTools(String)
        case modelNotInstalled(String)
        case mlxUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL: "The base URL is not a valid http(s) address."
            case .missingAPIKey(let host): "Add an API key for \(host) in the agent settings."
            case .missingModel: "Choose a model in the agent settings."
            case .modelCannotUseTools(let name): "“\(name)” does not support tool calling, which the agent needs. Choose another model."
            case .modelNotInstalled(let name): "“\(name)” is not downloaded. Choose an installed model, or download it under Manage On-Device Models…"
            case .mlxUnavailable(let reason): reason
            }
        }
    }

    /// Everything a session depends on, so a change can start a new session (keeping history).
    /// The price of this session's turns, or `nil` for a local model or one the table doesn't list.
    func cost(of usage: TokenUsage) -> Double? {
        guard provider != .ollama, provider != .mlx, !isLocalEndpoint else { return nil }
        return IDEAgentPrices(text: priceTableText).cost(of: usage, model: model)
    }

    var secretFilePatterns: [String] { secretFilePatternsText.components(separatedBy: .newlines) }

    var fingerprint: String {
        let local = provider == .ollama || provider == .mlx
        return "\(provider.rawValue)|\(baseURL)|\(model)|\(reasoningEffort)|\(local ? String(effectiveContextLength) : "")|\(iterationCap)|\(contextWindow ?? 0)|\(secretFilePatternsText)"
    }

    func makeClient() throws -> any LLMClient {
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { throw ConfigurationError.missingModel }
        if provider == .mlx { return try makeMLXClient() }
        guard let url = endpointURL else { throw ConfigurationError.invalidBaseURL }
        let key = apiKey().flatMap { $0.isEmpty ? nil : $0 }
        if requiresAPIKey, key == nil { throw ConfigurationError.missingAPIKey(host: endpointHost) }
        let endpoint = LLMEndpoint(baseURL: url, apiKey: key)

        switch provider {
        case .openAIResponses:
            return OpenAIResponsesClient(endpoint: endpoint)
        case .chatCompletions:
            // The real OpenAI takes strict tools and a cache key; other servers get the conservative subset.
            let isOpenAI = endpointHost == "api.openai.com"
            return OpenAIChatCompletionsClient(endpoint: endpoint, capabilities: isOpenAI ? .openAI : .compatible)
        case .ollama:
            // Only refuse on what the server told us: with no list loaded, the request decides.
            if let info = selectedOllamaModel, !info.capabilities.isEmpty, !info.supportsTools {
                throw ConfigurationError.modelCannotUseTools(info.name)
            }
            return OllamaClient(
                endpoint: endpoint, contextLength: effectiveContextLength,
                supportsThinking: selectedOllamaModel?.supportsThinking ?? false)
        case .mlx:
            return try makeMLXClient()
        }
    }

    private func makeMLXClient() throws -> MLXLLMClient {
        let status = MLXAvailability.currentStatus()
        guard status == .available else { throw ConfigurationError.mlxUnavailable(MLXAvailability.message(for: status)) }
        guard let installed = selectedMLXModel else { throw ConfigurationError.modelNotInstalled(model) }
        // The template decides whether the model can be asked to call a function at all.
        let info = MLXModelInspector.inspect(directory: installed.directory)
        if info.hasChatTemplate, !info.supportsTools { throw ConfigurationError.modelCannotUseTools(installed.id) }
        return MLXLLMClient(model: installed, settings: MLXGenerationSettings())
    }
}
