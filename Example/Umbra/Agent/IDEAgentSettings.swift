import AgentKit
import AgentKitMLX
import Foundation
import LocalModelStore
import Observation

/// Which API the agent talks to.
enum IDEAgentProvider: String, CaseIterable, Identifiable, Sendable, Codable {
    case openAIResponses = "responses"
    case chatCompletions = "chat"
    /// Claude through Anthropic's Messages API.
    case anthropic = "anthropic"
    case ollama = "ollama"
    /// Runs a downloaded model in this process on the GPU. Nothing is sent anywhere.
    case mlx = "mlx"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAIResponses: "OpenAI (Responses)"
        case .chatCompletions: "OpenAI-compatible (Chat Completions)"
        case .anthropic: "Anthropic (Claude)"
        case .ollama: "Ollama"
        case .mlx: "On this Mac (MLX)"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAIResponses, .chatCompletions: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .ollama: "http://localhost:11434"
        case .mlx: ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openAIResponses, .chatCompletions: "gpt-5"
        case .anthropic: "claude-opus-5-5"
        case .ollama, .mlx: ""
        }
    }

    /// Runs on this Mac, so it needs no consent and its chat template decides whether tools work.
    var isLocal: Bool { self == .ollama || self == .mlx }

    /// What the reasoning picker offers. Claude also takes the two levels above "high".
    var reasoningEfforts: [String] {
        self == .anthropic ? ["off", "low", "medium", "high", "xhigh", "max"] : ["off", "low", "medium", "high"]
    }

    var defaultReasoning: String {
        // A local model that thinks is slow per step; the user turns it on.
        isLocal ? "off" : "medium"
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
        ("claude-haiku-4", 200_000), ("claude-sonnet-4-5", 200_000), ("claude-opus-4-5", 200_000), ("claude-3", 200_000),
        ("claude-", 1_000_000),
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
        get { baseURL(for: provider) }
        set { store(Keys.field("baseURL", provider), newValue) }
    }

    var model: String {
        get { model(for: provider) }
        set { store(Keys.field("model", provider), newValue) }
    }

    var reasoningEffort: String {
        get { reasoningEffort(for: provider) }
        set { store(Keys.field("reasoning", provider), newValue) }
    }

    func setModel(_ value: String, for provider: IDEAgentProvider) { store(Keys.field("model", provider), value) }
    func setBaseURL(_ value: String, for provider: IDEAgentProvider) { store(Keys.field("baseURL", provider), value) }

    func baseURL(for provider: IDEAgentProvider) -> String { values[Keys.field("baseURL", provider)] ?? provider.defaultBaseURL }
    func model(for provider: IDEAgentProvider) -> String { values[Keys.field("model", provider)] ?? provider.defaultModel }
    func reasoningEffort(for provider: IDEAgentProvider) -> String {
        values[Keys.field("reasoning", provider)] ?? provider.defaultReasoning
    }

    /// What a chat with no choice of its own uses: the global provider, model and reasoning, and the
    /// ACP agent chosen in Settings, if any.
    var currentChoice: IDEAIModelChoice {
        IDEAIModelChoice(provider: provider, model: model, reasoningEffort: reasoningEffort, acpAgentID: activeACPAgent?.id)
    }

    /// The context window for local models, capped by the model's own maximum.
    var localContextLength: Int { didSet { defaults.set(localContextLength, forKey: Keys.context) } }

    /// Extra environment variables for agent commands, one `KEY=VALUE` per line. A `PATH` entry is
    /// added in front of the built path.
    var commandEnvironmentText: String { didSet { defaults.set(commandEnvironmentText, forKey: Keys.commandEnvironment) } }
    /// Whether the chat covers the editor (true) or sits docked beside it (false, the default).
    var opensAsPage: Bool { didSet { defaults.set(opensAsPage, forKey: Keys.page) } }
    /// Whether commands and skills in `~/.claude` are offered, besides the project's and Umbra's own.
    var loadsUserSkills: Bool { didSet { defaults.set(loadsUserSkills, forKey: Keys.userSkills) } }
    /// Whether `~/.claude/CLAUDE.md` and Umbra's own instruction file are put in the system prompt.
    var loadsUserInstructions: Bool { didSet { defaults.set(loadsUserInstructions, forKey: Keys.userInstructions) } }
    /// Whether the agent may call `web_search`. Off until the user turns it on; a key is also required.
    var webSearchEnabled: Bool { didSet { defaults.set(webSearchEnabled, forKey: Keys.webSearch) } }
    /// Whether a run that changed files must pass the project's tests before it may end. Off by
    /// default; turning it on is the consent to run the tests. Only applies to Gradle projects.
    var runTestsBeforeFinishing: Bool { didSet { defaults.set(runTestsBeforeFinishing, forKey: Keys.runTestsGate) } }
    /// Whether the agent may keep a per-project memory file across chats. Off by default.
    var memoryEnabled: Bool { didSet { defaults.set(memoryEnabled, forKey: Keys.memory) } }
    /// Whether `remember` applies without asking. Off by default; even then, a run that used web
    /// search or read untrusted content still asks before saving.
    var saveMemoriesWithoutAsking: Bool { didSet { defaults.set(saveMemoriesWithoutAsking, forKey: Keys.memoryNoAsk) } }
    /// Whether agent commands run under the workspace Seatbelt profile. Off by default, direct
    /// builds only (the toggle hides itself in the App Store build). Chosen per session: flipping
    /// it starts a new session, never changing the live run.
    var sandboxCommands: Bool { didSet { defaults.set(sandboxCommands, forKey: Keys.sandbox) } }
    /// Whether the sandbox profile blocks network access. Off by default (Gradle and Maven need
    /// to resolve).
    var sandboxBlockNetwork: Bool { didSet { defaults.set(sandboxBlockNetwork, forKey: Keys.sandboxNoNet) } }
    /// Whether a Brave Search key is saved. Held here so views never read the Keychain.
    private(set) var hasWebSearchKey = false
    /// What the agent may do without asking in a new chat (see `PermissionMode`); each chat can change its own.
    var mode: PermissionMode { didSet { defaults.set(mode.rawValue, forKey: Keys.mode) } }
    /// Model turns per message before the run pauses; `AgentConfiguration.maxIterations` when unset.
    var iterationCap: Int { didSet { defaults.set(iterationCap, forKey: Keys.iterationCap) } }
    /// Input plus output tokens for one run. `0` means no token budget.
    var maxRunTokens: Int { didSet { defaults.set(maxRunTokens, forKey: Keys.runTokens) } }
    /// Wall-clock seconds for one run. `0` means no time budget.
    var maxRunSeconds: Int { didSet { defaults.set(maxRunSeconds, forKey: Keys.runSeconds) } }
    /// US cents for one run, from the price table. `0` means no spend limit. Unknown models never trip it.
    var maxRunCostCents: Int { didSet { defaults.set(maxRunCostCents, forKey: Keys.runCost) } }
    /// The context window of a hosted model the built-in table doesn't know; 0 means use the table.
    var contextWindowOverride: Int { didSet { defaults.set(contextWindowOverride, forKey: Keys.contextOverride) } }
    /// Extra globs for files the agent must not read, one per line, on top of the built-in credential list.
    var secretFilePatternsText: String { didSet { defaults.set(secretFilePatternsText, forKey: Keys.secretPatterns) } }
    /// Dollars per million tokens by model prefix, as editable text (see `IDEAgentPrices`).
    var priceTableText: String { didSet { defaults.set(priceTableText, forKey: Keys.prices) } }
    private(set) var disclosedHosts: Set<String>
    // ACP (external agents, plan step 5). Command-based definitions only in v1.
    /// User-added ACP agents by name + command, persisted as JSON in defaults (never in a repo).
    var acpAgents: [IDEACPDefinition] { didSet { persistACPAgents() } }
    /// The ACP agent new chats use, when set and allowed. `nil` uses the built-in agent.
    var acpActiveAgentID: UUID? { didSet { defaults.set(acpActiveAgentID?.uuidString, forKey: Keys.acpActive) } }
    /// Per-agent "Allow running" consent, mirroring the remote-host consent flow.
    var acpAllowedAgentIDs: Set<UUID> { didSet { defaults.set(acpAllowedAgentIDs.map(\.uuidString).sorted(), forKey: Keys.acpAllowed) } }
    /// Key names with Keychain-backed values per agent id (`[agentUUID: [key]]`; values excluded).
    private(set) var acpEnvKeys: [String: [String]]

    var activeACPAgent: IDEACPDefinition? {
        guard let acpActiveAgentID, acpAllowedAgentIDs.contains(acpActiveAgentID) else { return nil }
        return acpAgents.first { $0.id == acpActiveAgentID }
    }

    /// The ACP agent a choice names, when it may run. A choice with no agent uses the built-in one.
    func acpAgent(for choice: IDEAIModelChoice) -> IDEACPDefinition? {
        guard let id = choice.acpAgentID, acpAllowedAgentIDs.contains(id) else { return nil }
        return acpAgents.first { $0.id == id }
    }

    func addACPAgent(name: String, commandLine: String) {
        guard let parsed = IDEACPDefinition.parseCommandLine(commandLine) else { return }
        let definition = IDEACPDefinition(name: name, command: parsed.command, args: parsed.args)
        acpAgents.append(definition)
        acpActiveAgentID = definition.id
    }

    func removeACPAgent(id: UUID) {
        acpAgents.removeAll { $0.id == id }
        acpAllowedAgentIDs.remove(id)
        for key in acpEnvKeys[id.uuidString] ?? [] { try? keyStore.delete(account: Self.acpEnvAccount(agentID: id, key: key)) }
        acpEnvKeys.removeValue(forKey: id.uuidString)
        defaults.set(acpEnvKeys, forKey: Keys.acpEnvKeys)
        if acpActiveAgentID == id { acpActiveAgentID = nil }
    }

    func setACPAllowed(_ allowed: Bool, agentID: UUID) {
        if allowed { acpAllowedAgentIDs.insert(agentID) } else { acpAllowedAgentIDs.remove(agentID) }
    }

    // ACP secret environment values live in the Keychain (per-agent accounts), never in
    // UserDefaults: `definition.env` is for non-secret values only.
    static func acpEnvAccount(agentID: UUID, key: String) -> String { "acp.\(agentID.uuidString).\(key)" }

    func saveACPEnvValue(_ value: String, agentID: UUID, key: String) throws {
        try keyStore.save(value, account: Self.acpEnvAccount(agentID: agentID, key: key))
        var keys = acpEnvKeys[agentID.uuidString] ?? []
        if !keys.contains(key) {
            keys.append(key)
            acpEnvKeys[agentID.uuidString] = keys
            defaults.set(acpEnvKeys, forKey: Keys.acpEnvKeys)
        }
    }

    func acpKeychainEnv(for agentID: UUID) -> [String: String] {
        var merged: [String: String] = [:]
        for key in acpEnvKeys[agentID.uuidString] ?? [] {
            if let value = try? keyStore.load(account: Self.acpEnvAccount(agentID: agentID, key: key)), !value.isEmpty {
                merged[key] = value
            }
        }
        return merged
    }

    func removeACPEnvValue(agentID: UUID, key: String) {
        try? keyStore.delete(account: Self.acpEnvAccount(agentID: agentID, key: key))
        acpEnvKeys[agentID.uuidString]?.removeAll { $0 == key }
        defaults.set(acpEnvKeys, forKey: Keys.acpEnvKeys)
    }

    private func persistACPAgents() {
        if let data = try? JSONEncoder().encode(acpAgents) { defaults.set(data, forKey: Keys.acpAgents) }
    }

    /// Whether a key is saved for the current endpoint. Held here so views never read the Keychain.
    private(set) var hasAPIKey = false
    /// The same for every provider's endpoint, by host, so a model picker can say which are ready.
    private var savedKeyHosts: Set<String> = []
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
        static let userSkills = "umbra.agent.loadsUserSkills"
        static let userInstructions = "umbra.agent.loadsUserInstructions"
        static let webSearch = "umbra.agent.webSearch"
        static let runTestsGate = "umbra.agent.runTestsBeforeFinishing"
        static let memory = "umbra.agent.memoryEnabled"
        static let memoryNoAsk = "umbra.agent.saveMemoriesWithoutAsking"
        static let sandbox = "umbra.agent.sandboxCommands"
        static let sandboxNoNet = "umbra.agent.sandboxBlockNetwork"
        static let prices = "umbra.agent.priceTable"
        static let secretPatterns = "umbra.agent.secretFilePatterns"
        static let iterationCap = "umbra.agent.iterationCap"
        static let runTokens = "umbra.agent.maxRunTokens"
        static let runSeconds = "umbra.agent.maxRunSeconds"
        static let runCost = "umbra.agent.maxRunCostCents"
        static let contextOverride = "umbra.agent.contextWindowOverride"
        static let acpAgents = "umbra.agent.acpAgents"
        static let acpActive = "umbra.agent.acpActive"
        static let acpAllowed = "umbra.agent.acpAllowed"
        static let acpEnvKeys = "umbra.agent.acpEnvKeys"

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
        loadsUserSkills = defaults.object(forKey: Keys.userSkills) as? Bool ?? true
        loadsUserInstructions = defaults.bool(forKey: Keys.userInstructions)
        webSearchEnabled = defaults.bool(forKey: Keys.webSearch)
        runTestsBeforeFinishing = defaults.bool(forKey: Keys.runTestsGate)
        memoryEnabled = defaults.bool(forKey: Keys.memory)
        saveMemoriesWithoutAsking = defaults.bool(forKey: Keys.memoryNoAsk)
        sandboxCommands = defaults.bool(forKey: Keys.sandbox)
        sandboxBlockNetwork = defaults.bool(forKey: Keys.sandboxNoNet)
        // A table nobody edited moves to the current built-in one, which has the Claude rows.
        priceTableText = defaults.string(forKey: Keys.prices).flatMap {
            IDEAgentPrices.supersededDefaultTexts.contains($0) ? nil : $0
        } ?? IDEAgentPrices.defaultText
        secretFilePatternsText = defaults.string(forKey: Keys.secretPatterns) ?? ""
        mode = defaults.string(forKey: Keys.mode).flatMap(PermissionMode.init(persisted:)) ?? .acceptEdits
        let storedCap = defaults.integer(forKey: Keys.iterationCap)
        iterationCap = storedCap > 0 ? storedCap : Self.defaultIterationCap
        maxRunTokens = max(0, defaults.integer(forKey: Keys.runTokens))
        maxRunSeconds = max(0, defaults.integer(forKey: Keys.runSeconds))
        maxRunCostCents = max(0, defaults.integer(forKey: Keys.runCost))
        contextWindowOverride = max(0, defaults.integer(forKey: Keys.contextOverride))
        acpAgents = (defaults.data(forKey: Keys.acpAgents)).flatMap { try? JSONDecoder().decode([IDEACPDefinition].self, from: $0) } ?? []
        acpActiveAgentID = defaults.string(forKey: Keys.acpActive).flatMap(UUID.init(uuidString:))
        acpAllowedAgentIDs = Set((defaults.stringArray(forKey: Keys.acpAllowed) ?? []).compactMap(UUID.init(uuidString:)))
        acpEnvKeys = (defaults.dictionary(forKey: Keys.acpEnvKeys) as? [String: [String]]) ?? [:]
        disclosedHosts = Set(defaults.stringArray(forKey: Keys.disclosed) ?? [])
        refreshKeyState()
        refreshWebSearchKeyState()
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

    var endpointURL: URL? { endpointURL(for: provider) }
    var endpointHost: String { endpointHost(for: provider) }
    /// A server on this Mac: nothing leaves it, so it needs no consent and no key.
    var isLocalEndpoint: Bool { isLocalEndpoint(for: provider) }

    func endpointURL(for provider: IDEAgentProvider) -> URL? {
        guard provider != .mlx else { return nil }
        let trimmed = baseURL(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil
        else { return nil }
        return url
    }

    func endpointHost(for provider: IDEAgentProvider) -> String {
        provider == .mlx ? "this Mac" : (endpointURL(for: provider)?.host() ?? baseURL(for: provider))
    }

    func isLocalEndpoint(for provider: IDEAgentProvider) -> Bool {
        if provider == .mlx { return true }
        guard let host = endpointURL(for: provider)?.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost")
    }

    /// The effort to send, or `nil` for "off".
    var effectiveReasoningEffort: String? { reasoningEffort == "off" ? nil : reasoningEffort }

    // MARK: - Disclosure

    /// File contents and command output go to this endpoint, so the first use needs an explicit OK
    /// per host, unless the endpoint is on this Mac. Nothing is sent before the user sends a message.
    var hasAcceptedDisclosure: Bool { hasAcceptedDisclosure(for: provider) }

    func hasAcceptedDisclosure(for provider: IDEAgentProvider) -> Bool {
        isLocalEndpoint(for: provider) || disclosedHosts.contains(endpointHost(for: provider))
    }

    func acceptDisclosure() { acceptDisclosure(for: provider) }

    func acceptDisclosure(for provider: IDEAgentProvider) {
        disclosedHosts.insert(endpointHost(for: provider))
        defaults.set(Array(disclosedHosts).sorted(), forKey: Keys.disclosed)
    }

    // MARK: - API key

    /// A remote OpenAI-style endpoint needs a key; a local one, and Ollama, use one only if saved
    /// (Ollama behind a proxy may want a bearer token).
    var requiresAPIKey: Bool { requiresAPIKey(for: provider) }

    func requiresAPIKey(for provider: IDEAgentProvider) -> Bool {
        provider != .ollama && provider != .mlx && !isLocalEndpoint(for: provider)
    }

    /// Whether a key is saved for a provider's endpoint, from the state `refreshKeyState` read.
    func hasAPIKey(for provider: IDEAgentProvider) -> Bool { savedKeyHosts.contains(endpointHost(for: provider)) }

    func refreshKeyState() {
        do {
            hasAPIKey = try keyStore.load(account: endpointHost)?.isEmpty == false
            keyError = nil
        } catch {
            hasAPIKey = false
            keyError = error.localizedDescription
        }
        var hosts: Set<String> = []
        for provider in IDEAgentProvider.allCases where provider != .mlx {
            let host = endpointHost(for: provider)
            if (try? keyStore.load(account: host))?.isEmpty == false { hosts.insert(host) }
        }
        savedKeyHosts = hosts
    }

    func saveAPIKey(_ key: String) { saveAPIKey(key, for: provider) }

    func saveAPIKey(_ key: String, for provider: IDEAgentProvider) {
        do {
            try keyStore.save(key, account: endpointHost(for: provider))
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
        refreshKeyState()
    }

    func removeAPIKey() { removeAPIKey(for: provider) }

    func removeAPIKey(for provider: IDEAgentProvider) {
        do {
            try keyStore.delete(account: endpointHost(for: provider))
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
        refreshKeyState()
    }

    func apiKey() -> String? { apiKey(for: provider) }

    func apiKey(for provider: IDEAgentProvider) -> String? {
        try? keyStore.load(account: endpointHost(for: provider))
    }

    // MARK: - Web search

    /// Keychain account for the Brave Search key. Not the model endpoint's account.
    static let webSearchAccount = "api.search.brave.com"

    func refreshWebSearchKeyState() {
        hasWebSearchKey = (try? keyStore.load(account: Self.webSearchAccount))?.isEmpty == false
    }

    func saveWebSearchKey(_ key: String) {
        do {
            try keyStore.save(key, account: Self.webSearchAccount)
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
        refreshWebSearchKeyState()
    }

    func removeWebSearchKey() {
        do {
            try keyStore.delete(account: Self.webSearchAccount)
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
        refreshWebSearchKeyState()
    }

    func webSearchAPIKey() -> String? {
        try? keyStore.load(account: Self.webSearchAccount)
    }

    /// What the panel's empty state asks for, or `nil` when the agent can be used.
    var setupHint: String? { setupHint(for: currentChoice) }

    func setupHint(for choice: IDEAIModelChoice) -> String? {
        let provider = choice.provider, model = choice.model
        if provider == .mlx {
            let status = MLXAvailability.currentStatus()
            if status != .available { return MLXAvailability.message(for: status) }
            if model.isEmpty { return "Download a model under Manage On-Device Models…, then choose it here." }
            if selectedMLXModel(id: model) == nil { return "“\(model)” is not downloaded. Choose an installed model." }
            return nil
        }
        if endpointURL(for: provider) == nil { return "Set a valid base URL in the agent settings." }
        if provider == .ollama {
            if model.isEmpty { return ollamaError ?? "Choose an Ollama model in the agent settings." }
            return nil
        }
        if model.isEmpty { return "Choose a model." }
        if requiresAPIKey(for: provider) && !hasAPIKey(for: provider) { return "Add an API key in the agent settings." }
        return nil
    }

    // MARK: - On-device (MLX)

    /// The installed model chosen for the MLX provider.
    var selectedMLXModel: InstalledLocalModel? { selectedMLXModel(id: model) }

    func selectedMLXModel(id: String) -> InstalledLocalModel? { installedModels().first { $0.id == id } }

    // MARK: - Ollama

    /// The model's details when the list has been loaded and the model is in it.
    var selectedOllamaModel: OllamaModel? { selectedOllamaModel(named: model) }

    func selectedOllamaModel(named name: String) -> OllamaModel? { ollamaModels.first { $0.name == name } }

    /// The window actually requested: the user's cap, limited by what the model supports.
    var effectiveContextLength: Int { effectiveContextLength(for: currentChoice) }

    func effectiveContextLength(for choice: IDEAIModelChoice) -> Int {
        let limit: Int? = choice.provider == .mlx
            ? selectedMLXModel(id: choice.model).flatMap { MLXModelInspector.inspect(directory: $0.directory).contextLength }
            : selectedOllamaModel(named: choice.model)?.contextLength
        return min(localContextLength, limit ?? localContextLength)
    }

    /// The window compaction measures against. Local models use what was requested from them; a hosted
    /// one uses the override, else the table, else nothing (compaction then waits for an overflow).
    var contextWindow: Int? { contextWindow(for: currentChoice) }

    func contextWindow(for choice: IDEAIModelChoice) -> Int? {
        if choice.provider.isLocal { return effectiveContextLength(for: choice) }
        if contextWindowOverride > 0 { return contextWindowOverride }
        let name = choice.model.lowercased()
        return Self.hostedContextWindows.first { name.hasPrefix($0.prefix) }?.tokens
    }

    /// Loads the installed models from the Ollama endpoint. `adjustSelection: false` leaves the global
    /// model alone, for a picker that only needs the list.
    func refreshOllamaModels(adjustSelection: Bool = true) async {
        guard let url = endpointURL(for: .ollama) else { return }
        isLoadingOllamaModels = true
        defer { isLoadingOllamaModels = false }
        do {
            ollamaModels = try await OllamaModelCatalog(baseURL: url, transport: transport).models()
            ollamaError = nil
            // Keep a valid choice: the saved one if still installed, else the first that can use tools.
            if adjustSelection, provider == .ollama, !ollamaModels.contains(where: { $0.name == model }) {
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

    /// The price of this session's turns, or `nil` for a local model or one the table doesn't list.
    func cost(of usage: TokenUsage) -> Double? { cost(of: usage, for: currentChoice) }

    func cost(of usage: TokenUsage, for choice: IDEAIModelChoice) -> Double? {
        guard !choice.provider.isLocal, !isLocalEndpoint(for: choice.provider) else { return nil }
        return IDEAgentPrices(text: priceTableText).cost(of: usage, model: choice.model)
    }

    /// True when this run's priced usage has reached the spend limit. `nil` when there is no limit.
    /// A model the price table doesn't know never trips it.
    var runIsOverCost: (@Sendable (TokenUsage) -> Bool)? { runIsOverCost(for: currentChoice) }

    func runIsOverCost(for choice: IDEAIModelChoice) -> (@Sendable (TokenUsage) -> Bool)? {
        guard maxRunCostCents > 0 else { return nil }
        let cents = maxRunCostCents
        let table = priceTableText
        let name = choice.model
        return { usage in
            guard let dollars = IDEAgentPrices(text: table).cost(of: usage, model: name) else { return false }
            return dollars * 100 >= Double(cents)
        }
    }

    var secretFilePatterns: [String] { secretFilePatternsText.components(separatedBy: .newlines) }

    /// Everything a session depends on, so a change can start a new session (keeping history).
    /// The price table is part of it only while a spend limit is on, because that is when the session captured the table.
    var fingerprint: String { fingerprint(for: currentChoice) }

    func fingerprint(for choice: IDEAIModelChoice) -> String {
        let provider = choice.provider
        let local = provider.isLocal
        let prices = maxRunCostCents > 0 ? priceTableText : ""
        return "\(provider.rawValue)|\(baseURL(for: provider))|\(choice.model)|\(choice.reasoningEffort)|\(local ? String(effectiveContextLength(for: choice)) : "")|\(iterationCap)|\(maxRunTokens)|\(maxRunSeconds)|\(maxRunCostCents)|\(prices)|\(contextWindow(for: choice) ?? 0)|\(secretFilePatternsText)|\(webSearchEnabled)|\(hasWebSearchKey)|\(runTestsBeforeFinishing)|\(memoryEnabled)|\(saveMemoriesWithoutAsking)|\(sandboxCommands)|\(sandboxBlockNetwork)"
    }

    func makeClient() throws -> any LLMClient { try makeClient(for: currentChoice) }

    /// `requiresTools: false` is plain chat: a model the server or its chat template says cannot call
    /// tools is fine, since none are offered.
    func makeClient(for choice: IDEAIModelChoice, requiresTools: Bool = true) throws -> any LLMClient {
        let provider = choice.provider
        guard !choice.model.trimmingCharacters(in: .whitespaces).isEmpty else { throw ConfigurationError.missingModel }
        if provider == .mlx { return try makeMLXClient(model: choice.model, requiresTools: requiresTools) }
        guard let url = endpointURL(for: provider) else { throw ConfigurationError.invalidBaseURL }
        let key = apiKey(for: provider).flatMap { $0.isEmpty ? nil : $0 }
        if requiresAPIKey(for: provider), key == nil { throw ConfigurationError.missingAPIKey(host: endpointHost(for: provider)) }
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
        case .ollama:
            let info = selectedOllamaModel(named: choice.model)
            // Only refuse on what the server told us: with no list loaded, the request decides.
            if requiresTools, let info, !info.capabilities.isEmpty, !info.supportsTools {
                throw ConfigurationError.modelCannotUseTools(info.name)
            }
            return OllamaClient(
                endpoint: endpoint, contextLength: effectiveContextLength(for: choice),
                supportsThinking: info?.supportsThinking ?? false)
        case .mlx:
            return try makeMLXClient(model: choice.model, requiresTools: requiresTools)
        }
    }

    private func makeMLXClient(model: String, requiresTools: Bool) throws -> MLXLLMClient {
        let status = MLXAvailability.currentStatus()
        guard status == .available else { throw ConfigurationError.mlxUnavailable(MLXAvailability.message(for: status)) }
        guard let installed = selectedMLXModel(id: model) else { throw ConfigurationError.modelNotInstalled(model) }
        // The template decides whether the model can be asked to call a function at all.
        let info = MLXModelInspector.inspect(directory: installed.directory)
        if requiresTools, info.hasChatTemplate, !info.supportsTools { throw ConfigurationError.modelCannotUseTools(installed.id) }
        return MLXLLMClient(model: installed, settings: MLXGenerationSettings())
    }
}
