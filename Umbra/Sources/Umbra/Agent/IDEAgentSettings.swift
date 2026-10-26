import AgentKit
import AgentKitApple
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
    /// Muse from Meta through the Meta Model API (`api.meta.ai`), which speaks the OpenAI
    /// Responses format with a Bearer key, so it reuses `OpenAIResponsesClient`.
    case meta = "meta"
    case ollama = "ollama"
    /// Runs a downloaded model in this process on the GPU. Nothing is sent anywhere.
    case mlx = "mlx"
    /// Apple's foundation model on this Mac (Apple Intelligence). Nothing is sent anywhere.
    case apple = "apple"
    /// Apple's larger model on Private Cloud Compute (macOS 27). The request leaves the Mac, for Apple's servers.
    case applePCC = "apple-pcc"

    var id: String { rawValue }

    var title: String {
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

    var defaultBaseURL: String {
        switch self {
        case .openAIResponses, .chatCompletions: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .meta: "https://api.meta.ai/v1"
        case .ollama: "http://localhost:11434"
        case .mlx, .apple, .applePCC: ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openAIResponses, .chatCompletions: "gpt-5"
        case .anthropic: "claude-opus-5-5"
        case .meta: "muse-spark-1.3"
        case .ollama, .mlx: ""
        case .apple: "system"
        case .applePCC: "pcc"
        }
    }

    /// Runs on this Mac, so it needs no consent and its chat template decides whether tools work.
    var isLocal: Bool { self == .ollama || self == .mlx || self == .apple }

    /// Apple's models: no URL, no key, and a window the framework reports.
    var appleKind: AppleModelKind? {
        switch self {
        case .apple: .onDevice
        case .applePCC: .privateCloudCompute
        default: nil
        }
    }

    /// Whether the provider is reached at a base URL. The on-device ones are not.
    var hasEndpoint: Bool { self != .mlx && appleKind == nil }

    /// What the reasoning picker offers. Claude also takes the two levels above "high"; Apple's models have no setting.
    var reasoningEfforts: [String] {
        if appleKind != nil { return ["off"] }
        return self == .anthropic ? ["off", "low", "medium", "high", "xhigh", "max"] : ["off", "low", "medium", "high"]
    }

    var defaultReasoning: String {
        // A local model that thinks is slow per step; the user turns it on.
        isLocal || appleKind != nil ? "off" : "medium"
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
        ("muse-", 1_048_576),
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
    /// Offers `web_fetch`. Off until the user turns it on: the address of every page goes to its site.
    var webFetchEnabled: Bool { didSet { defaults.set(webFetchEnabled, forKey: Keys.webFetch) } }
    /// The agent's `browser_inspect` (and later `browser_act`) over the Browser tab's page. On by default: pages on
    /// this Mac are readable at once and any other site asks first.
    var browserToolsEnabled: Bool { didSet { defaults.set(browserToolsEnabled, forKey: Keys.browserTools) } }
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
    /// The helper model for chores (`explore`, summaries): a cheaper or local model whose output
    /// a wrong answer barely hurts. `nil` runs everything on the chat's model.
    var helperChoice: IDEAIModelChoice? {
        didSet {
            if let helperChoice, let data = try? JSONEncoder().encode(helperChoice) {
                defaults.set(data, forKey: Keys.helperModel)
            } else {
                defaults.removeObject(forKey: Keys.helperModel)
            }
        }
    }

    /// Whether a helper model is set, for the settings toggle. Enabling picks the Ollama default;
    /// the provider and model rows below refine it.
    var helperEnabled: Bool {
        get { helperChoice != nil }
        set {
            if newValue, helperChoice == nil {
                helperChoice = IDEAIModelChoice(provider: .ollama, model: selectedOllamaModel(named: model(for: .ollama))?.name ?? "")
            } else if !newValue {
                helperChoice = nil
            }
        }
    }

    var helperProvider: IDEAgentProvider {
        get { helperChoice?.provider ?? .ollama }
        set {
            var choice = helperChoice ?? IDEAIModelChoice(provider: .ollama, model: "")
            if choice.provider != newValue { choice.model = "" }
            choice.provider = newValue
            choice.reasoningEffort = newValue.defaultReasoning
            choice.acpAgentID = nil
            helperChoice = choice
        }
    }

    var helperModelName: String {
        get { helperChoice?.model ?? "" }
        set {
            var choice = helperChoice ?? IDEAIModelChoice(provider: .ollama, model: "")
            choice.model = newValue
            helperChoice = choice
        }
    }

    /// Why the helper cannot be used, for the settings caption and the session notice.
    var helperIssue: String? { clientFactory().helperIssue() }
    /// Whether a Brave Search key is saved. Loaded from the Keychain on first read, so creating
    /// settings never prompts for keychain access. Held here so views never read the Keychain.
    private var _hasWebSearchKey = false
    var hasWebSearchKey: Bool {
        ensureKeyStateLoaded()
        return _hasWebSearchKey
    }
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
    var hasAPIKey: Bool { hasAPIKey(for: provider) }
    /// Key state loads from the Keychain on first use, never in `init`, so opening the app does
    /// not prompt for keychain access. The first send, or agent key UI, triggers the load.
    private var didLoadKeyState = false
    /// The same for every provider's endpoint, by host, so a model picker can say which are ready.
    private var savedKeyHosts: Set<String> = []
    private(set) var keyError: String?

    // Ollama
    private(set) var ollamaModels: [OllamaModel] = []
    private(set) var ollamaError: String?
    private(set) var isLoadingOllamaModels = false

    // Meta: the models `api.meta.ai` lists today, fetched with the saved key. Empty until a
    // fetch succeeds; the picker then falls back to the curated ids in `IDEAIModelNames`.
    private(set) var metaModels: [String] = []
    private(set) var metaError: String?
    private(set) var isLoadingMetaModels = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keyStore: any IDEAgentKeyStore
    /// The MCP servers the user added, and what they said about the project's. Environment values are in the same Keychain.
    @ObservationIgnored let mcp: IDEMCPStore
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
        static let webFetch = "umbra.agent.webFetch"
        static let browserTools = "umbra.agent.browserTools"
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
        static let helperModel = "umbra.agent.helperModel"
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
        self.mcp = IDEMCPStore(defaults: defaults, keyStore: keyStore)
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
        webFetchEnabled = defaults.bool(forKey: Keys.webFetch)
        browserToolsEnabled = defaults.object(forKey: Keys.browserTools) as? Bool ?? true
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
        helperChoice = defaults.data(forKey: Keys.helperModel).flatMap { try? JSONDecoder().decode(IDEAIModelChoice.self, from: $0) }
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

    func endpointURL(for provider: IDEAgentProvider) -> URL? { clientFactory().endpointURL(for: provider) }

    func endpointHost(for provider: IDEAgentProvider) -> String { clientFactory().endpointHost(for: provider) }

    func isLocalEndpoint(for provider: IDEAgentProvider) -> Bool { clientFactory().isLocalEndpoint(for: provider) }

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

    func requiresAPIKey(for provider: IDEAgentProvider) -> Bool { clientFactory().requiresAPIKey(for: provider) }

    /// Whether a key is saved for a provider's endpoint, loading the cached state on first use.
    func hasAPIKey(for provider: IDEAgentProvider) -> Bool {
        ensureKeyStateLoaded()
        return savedKeyHosts.contains(endpointHost(for: provider))
    }

    /// Reads the cached key flags once; later reads reuse them until a save, removal,
    /// or provider or URL change refreshes them.
    func ensureKeyStateLoaded() {
        guard !didLoadKeyState else { return }
        refreshKeyState()
        refreshWebSearchKeyState()
    }

    func refreshKeyState() {
        didLoadKeyState = true
        do {
            _ = try keyStore.load(account: endpointHost)
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
        var hosts: Set<String> = []
        for provider in IDEAgentProvider.allCases where provider.hasEndpoint {
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

    func apiKey(for provider: IDEAgentProvider) -> String? { clientFactory().apiKey(for: provider) }

    // MARK: - Web search

    /// Keychain account for the Brave Search key. Not the model endpoint's account.
    static let webSearchAccount = "api.search.brave.com"

    func refreshWebSearchKeyState() {
        didLoadKeyState = true
        _hasWebSearchKey = (try? keyStore.load(account: Self.webSearchAccount))?.isEmpty == false
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
    var setupHint: String? { setupHint(for: currentChoice) ?? codeHint(for: currentChoice) }

    func setupHint(for choice: IDEAIModelChoice) -> String? {
        let provider = choice.provider, model = choice.model
        if let kind = provider.appleKind { return AppleModelAvailability.message(for: appleStatus(kind), kind: kind) }
        if provider == .mlx {
            let status = MLXAvailability.currentStatus()
            if status != .available { return MLXAvailability.message(for: status) }
            if model.isEmpty { return "Download a model under Manage On-Device Models…, then choose it here." }
            guard let installed = selectedMLXModel(id: model) else {
                return "“\(model)” is not downloaded. Choose an installed model."
            }
            if let message = MLXModelInspector.unsupportedQuantizationMessage(
                modelID: model, bits: MLXModelInspector.quantizationBits(in: installed.directory)) {
                return message
            }
            if let message = MLXModelInspector.baseModelMessage(modelID: model) { return message }
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

    // MARK: - Apple Intelligence

    /// Whether Apple's model can be used right now. Replaceable, so tests do not depend on the machine.
    var appleStatus: @MainActor (AppleModelKind) -> AppleModelStatus = { AppleModelAvailability.status(for: $0) }

    /// Windows read from the framework by `refreshAppleModels()`. The on-device one is also read directly.
    var appleContextSizes: [AppleModelKind: Int] = [:]

    /// Code needs the system prompt and about thirty tool definitions (about 5,000 tokens in a Java project, measured
    /// with `ContextBudget`) and room to work, so a window under this is chat only. The on-device model's is 8,192.
    static let minimumAppleCodeContext = 16_384

    func appleContextSize(for kind: AppleModelKind) -> Int? {
        clientFactory().appleWindow(for: kind)
    }

    /// Whether Apple's model has the room Code needs. A window that is not known yet is given the benefit of the doubt
    /// for Private Cloud Compute (its size is read asynchronously); the session still checks the real prompt.
    func appleFitsCode(_ kind: AppleModelKind) -> Bool {
        appleContextSize(for: kind).map { $0 >= Self.minimumAppleCodeContext } ?? (kind == .privateCloudCompute)
    }

    /// Why a choice cannot be used for Code, or `nil`. Only Apple's on-device model has such a limit.
    func codeHint(for choice: IDEAIModelChoice) -> String? {
        guard let kind = choice.provider.appleKind, !appleFitsCode(kind) else { return nil }
        let size = appleContextSize(for: kind).map { "\($0.formatted()) tokens" } ?? "a small window"
        return "Apple's on-device model has \(size), too small for Code's tools. Use it in Chat, or pick another model."
    }

    /// Reads the windows of the Apple models that can be used.
    func refreshAppleModels() async {
        for kind in AppleModelKind.allCases where appleStatus(kind) == .available {
            if let size = await AppleModelAvailability.contextSize(for: kind) { appleContextSizes[kind] = size }
        }
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
        clientFactory().effectiveContextLength(for: choice)
    }

    /// The window compaction measures against. Local models use what was requested from them; a hosted
    /// one uses the override, else the table, else nothing (compaction then waits for an overflow).
    var contextWindow: Int? { contextWindow(for: currentChoice) }

    func contextWindow(for choice: IDEAIModelChoice) -> Int? {
        clientFactory().contextWindow(for: choice)
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

    // MARK: - Meta models

    /// The Muse models the picker offers: what the endpoint lists today when a fetch has
    /// succeeded, else the curated ids shipped with the app, so the menu works before a key
    /// is saved, offline, and when the list call fails. The configured model is always kept,
    /// so a saved choice never vanishes from its own menu.
    var offeredMetaModels: [String] {
        var ids = metaModels.isEmpty ? IDEAIModelNames.muse.map(\.id) : metaModels
        let configured = model(for: .meta)
        if !configured.isEmpty, !ids.contains(configured) { ids.append(configured) }
        return ids
    }

    /// Fetches the models `api.meta.ai` offers (`GET /v1/models` with the saved key), so a model
    /// released after this app was built appears without an app update. Without a key there is
    /// nothing to ask with, and the curated fallback stays; a failed fetch keeps the last list
    /// (or the fallback) and records why in `metaError` for Settings to show.
    func refreshMetaModels() async {
        guard let url = endpointURL(for: .meta), let key = apiKey(for: .meta), !key.isEmpty else { return }
        isLoadingMetaModels = true
        defer { isLoadingMetaModels = false }
        do {
            metaModels = try await HostedModelCatalog(
                endpoint: LLMEndpoint(baseURL: url, apiKey: key), transport: transport).models()
            metaError = metaModels.isEmpty ? "Meta listed no models." : nil
        } catch {
            metaError = error.localizedDescription
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
        case appleUnavailable(String)
        case noHelperModel
        case unknownModel(String)
        case helperUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL: "The base URL is not a valid http(s) address."
            case .missingAPIKey(let host): "Add an API key for \(host) in the agent settings."
            case .missingModel: "Choose a model in the agent settings."
            case .modelCannotUseTools(let name): "“\(name)” does not support tool calling, which the agent needs. Choose another model."
            case .modelNotInstalled(let name): "“\(name)” is not downloaded. Choose an installed model, or download it under Manage On-Device Models…"
            case .mlxUnavailable(let reason), .appleUnavailable(let reason): reason
            case .noHelperModel: "No helper model is set. Choose one in the agent settings."
            case .unknownModel(let key): "“\(key)” is not a model this host understands (helper, or provider:model)."
            case .helperUnavailable(let issue): issue
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
        let local = provider.isLocal && provider.appleKind == nil
        let prices = maxRunCostCents > 0 ? priceTableText : ""
        let helper = helperChoice.map { "\($0.provider.rawValue)|\($0.model)|\($0.reasoningEffort)" } ?? "none"
        return "\(provider.rawValue)|\(baseURL(for: provider))|\(choice.model)|\(choice.reasoningEffort)|\(local ? String(effectiveContextLength(for: choice)) : "")|\(iterationCap)|\(maxRunTokens)|\(maxRunSeconds)|\(maxRunCostCents)|\(prices)|\(contextWindow(for: choice) ?? 0)|\(secretFilePatternsText)|\(webSearchEnabled)|\(hasWebSearchKey)|\(webFetchEnabled)|\(browserToolsEnabled)|\(runTestsBeforeFinishing)|\(memoryEnabled)|\(saveMemoriesWithoutAsking)|\(sandboxCommands)|\(sandboxBlockNetwork)|\(helper)"
    }

    func makeClient() throws -> any LLMClient { try makeClient(for: currentChoice) }

    /// `requiresTools: false` is plain chat: a model the server or its chat template says cannot call
    /// tools is fine, since none are offered. Built through the client factory, so the main chat
    /// and child sessions share one construction path.
    func makeClient(for choice: IDEAIModelChoice, requiresTools: Bool = true) throws -> any LLMClient {
        try clientFactory().client(for: choice, requiresTools: requiresTools)
    }

    /// A snapshot builder for model clients, safe to use off the main actor (child sessions).
    func clientFactory() -> IDEAgentClientFactory {
        IDEAgentClientFactory(
            baseURLs: Dictionary(uniqueKeysWithValues: IDEAgentProvider.allCases.map { ($0, baseURL(for: $0)) }),
            keyStore: keyStore, transport: transport, ollamaModels: ollamaModels,
            installedMLXModels: installedModels(), localContextLength: localContextLength,
            contextWindowOverride: contextWindowOverride,
            appleStatuses: Dictionary(uniqueKeysWithValues: AppleModelKind.allCases.map { ($0, appleStatus($0)) }),
            appleWindows: appleContextSizes, hostedContextWindows: Self.hostedContextWindows,
            helper: helperChoice)
    }
}
