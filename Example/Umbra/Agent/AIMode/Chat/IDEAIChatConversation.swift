import AgentKit
import LocalModelStore
import Foundation
import Observation

/// One plain conversation with a model: no project, no tools, any model. It runs on the same
/// `AgentSession` as Code (retries, compaction, usage, Stop), with an empty tool list, so a model
/// that cannot call tools is fine. It never reaches the window or the project.
@MainActor
@Observable
final class IDEAIChatConversation: Identifiable {
    let id = UUID()
    /// The saved conversation's identity; changes when the chat is emptied or another is loaded.
    private(set) var conversationID = UUID()
    private(set) var entries: [IDEAgentEntry] = []
    var draft = ""
    /// This chat's model. `nil` until one is set; `effectiveChoice` falls back to the default.
    var modelChoice: IDEAIModelChoice?
    private(set) var isRunning = false
    private(set) var status: String?
    private(set) var usage = TokenUsage()
    /// Dollars so far; `nil` when any turn had no known price.
    private(set) var cost: Double? = 0
    private(set) var contextTokens: Int?
    var customTitle: String?
    /// A reply finished while another chat was showing.
    var isUnread = false
    private(set) var createdAt = Date()

    let settings: IDEAgentSettings
    @ObservationIgnored private let aiSettings: IDEAISettings
    @ObservationIgnored private let store: SessionStore?
    @ObservationIgnored private let clientFactory: @MainActor (IDEAgentSettings, IDEAIModelChoice) throws -> any LLMClient
    @ObservationIgnored private let defaultChoice: @MainActor () -> IDEAIModelChoice
    @ObservationIgnored private var session: AgentSession?
    @ObservationIgnored private var sessionFingerprint: String?
    @ObservationIgnored private var restoredItems: [ConversationItem]?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Where the current turn's entries begin, so a resent turn can drop what it had streamed.
    @ObservationIgnored private var turnStart = 0
    /// Called after the chat was saved, so the list of chats can refresh.
    @ObservationIgnored var onPersisted: (() -> Void)?
    /// Called when a run ends.
    @ObservationIgnored var onRunFinished: (() -> Void)?

    /// The root every chat is saved under. It is not a folder: a chat belongs to no project.
    static let storeRoot = "/Umbra/Chats"

    init(
        settings: IDEAgentSettings,
        aiSettings: IDEAISettings,
        store: SessionStore?,
        defaultChoice: @escaping @MainActor () -> IDEAIModelChoice,
        clientFactory: @escaping @MainActor (IDEAgentSettings, IDEAIModelChoice) throws -> any LLMClient
    ) {
        self.settings = settings
        self.aiSettings = aiSettings
        self.store = store
        self.defaultChoice = defaultChoice
        self.clientFactory = clientFactory
    }

    // MARK: - State

    var effectiveChoice: IDEAIModelChoice { modelChoice ?? defaultChoice() }
    var isEmpty: Bool { entries.isEmpty }

    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        for entry in entries where entry.kind == .user {
            let line = entry.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            if !line.isEmpty { return line.count > 60 ? String(line.prefix(60)) + "…" : line }
        }
        return "New chat"
    }

    /// Whether what this chat sends may leave the Mac: the endpoint was accepted, or it runs here.
    var hasConsent: Bool { settings.hasAcceptedDisclosure(for: effectiveChoice.provider) }

    var canSend: Bool {
        !isRunning && hasConsent && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// How full the model's window is, from 0 to 1; `nil` when the window or the use is not known.
    var contextFraction: Double? {
        guard let window = settings.contextWindow(for: effectiveChoice), window > 0, let contextTokens else { return nil }
        return min(1, Double(contextTokens) / Double(window))
    }

    /// What the empty state asks for before a message can be sent, or `nil`.
    var setupHint: String? { settings.setupHint(for: effectiveChoice) }

    // MARK: - Sending

    func send() {
        guard canSend else { return }
        submit(draft.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func submit(_ text: String) {
        guard !isRunning, hasConsent, !text.isEmpty else { return }
        draft = ""
        // The model in use when the first message is sent stays with the chat, even if what the
        // default would be changes later (the Ollama list arrives, a key is added).
        if modelChoice == nil { modelChoice = effectiveChoice }
        entries.append(IDEAgentEntry(kind: .user, text: text))
        start { session in await session.send(text) }
    }

    /// Tries the send that failed because the provider could not be reached, without adding the message again.
    func retry() {
        guard !isRunning, hasConsent, entries.contains(where: \.canRetry) else { return }
        entries.removeAll { $0.canRetry }
        start { session in await session.retry() }
    }

    func stop() {
        guard isRunning else { return }
        stopRequested = true
        let session = session
        Task { await session?.stop() }
    }

    private func start(_ run: @escaping @Sendable (AgentSession) async -> AsyncStream<AgentEvent>) {
        isRunning = true
        status = nil
        stopRequested = false
        turnStart = entries.count
        runTask = Task { [weak self] in
            guard let self else { return }
            let active: AgentSession
            do {
                active = try await self.currentSession()
            } catch {
                self.fail(error.localizedDescription)
                return
            }
            // An on-device model reads gigabytes the first time; say so, and fail visibly.
            let choice = self.effectiveChoice
            if choice.provider == .mlx, let model = self.settings.selectedMLXModel(id: choice.model) {
                let models = IDELocalModelsStore.shared
                if models.loadedID != model.id {
                    self.status = "Loading \(LocalModelFormat.shortName(model.id))…"
                    await models.load(model)
                }
                if let error = models.loadError, models.loadedID != model.id {
                    self.fail(error)
                    return
                }
                self.status = nil
            }
            // A Stop that landed while the session was made or the model loaded ends the run here.
            if self.stopRequested {
                self.finishRun()
                return
            }
            for await event in await run(active) { self.handle(event) }
            self.finishRun()
        }
    }

    private func currentSession() async throws -> AgentSession {
        let choice = effectiveChoice
        let fingerprint = settings.fingerprint(for: choice)
        if let session, sessionFingerprint == fingerprint { return session }

        let client = try clientFactory(settings, choice)
        // A model change keeps the conversation, minus provider items only the old model may be sent back.
        var history: [ConversationItem] = []
        if let previous = session {
            history = await previous.items.filter { if case .opaque = $0 { false } else { true } }
        } else if let restored = restoredItems {
            history = restored
        }
        restoredItems = nil
        let configuration = AgentConfiguration(
            model: choice.model,
            systemPrompt: aiSettings.chatSystemPrompt,
            reasoningEffort: choice.effectiveReasoningEffort,
            cacheKey: "umbra-chat-\(conversationID.uuidString)",
            contextWindow: settings.contextWindow(for: choice),
            compactionThreshold: choice.provider == .ollama ? 0.60 : 0.75)
        // No tools are offered, so the workspace is never read; any folder will do.
        let workspace = DiskAgentWorkspace(root: FileManager.default.temporaryDirectory)
        let created = AgentSession(client: client, tools: [], workspace: workspace, configuration: configuration, history: history)
        session = created
        sessionFingerprint = fingerprint
        return created
    }

    // MARK: - Events

    private func handle(_ event: AgentEvent) {
        switch event {
        case .textDelta(let delta):
            status = nil
            pendingText += delta
            scheduleFlush()
        case .reasoningDelta:
            if status == nil { status = "Thinking…" }
        case .turnRestarted:
            flushTask?.cancel()
            pendingText = ""
            if turnStart < entries.count { entries.removeSubrange(turnStart...) }
        case .assistantMessage(let text):
            flushPending()
            if let index = entries.indices.last, entries[index].kind == .assistant, entries[index].isStreaming {
                entries[index].text = text
                entries[index].isStreaming = false
            } else if !text.isEmpty {
                entries.append(IDEAgentEntry(kind: .assistant, text: text))
            }
        case .usage(let turnUsage):
            if turnUsage.inputTokens > 0 { contextTokens = turnUsage.inputTokens }
            usage = usage + turnUsage
            if let turnCost = settings.cost(of: turnUsage, for: effectiveChoice), let total = cost { cost = total + turnCost } else { cost = nil }
        case .compacted:
            entries.append(IDEAgentEntry(kind: .notice, text: "Earlier messages were summarized to make room in the model's window."))
        case .runEnded(let ending):
            flushPending()
            closeStreamingEntry()
            end(with: ending)
        default:
            break
        }
    }

    private func end(with ending: RunEnding) {
        switch ending {
        case .completed, .stopped:
            break
        case .lengthLimit:
            entries.append(IDEAgentEntry(kind: .notice, text: "The reply was cut off at the model's output limit."))
        case .contentFiltered:
            entries.append(IDEAgentEntry(kind: .notice, text: "The model declined to answer this."))
        case .iterationCap, .budget, .repeatedCall:
            entries.append(IDEAgentEntry(kind: .notice, text: "The run stopped early."))
        case .failed(let message):
            var entry = IDEAgentEntry(kind: .error, text: message)
            entry.canRetry = IDEAgentNetworkFailure.offersRetry(message)
            entries.append(entry)
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.flushPending()
        }
    }

    private func flushPending() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingText.isEmpty else { return }
        if let index = entries.indices.last, entries[index].kind == .assistant, entries[index].isStreaming {
            entries[index].text += pendingText
        } else {
            var entry = IDEAgentEntry(kind: .assistant, text: pendingText)
            entry.isStreaming = true
            entries.append(entry)
        }
        pendingText = ""
    }

    private func closeStreamingEntry() {
        guard let index = entries.indices.last, entries[index].isStreaming else { return }
        entries[index].isStreaming = false
    }

    /// The run could not start (no key, no model, the model failed to load).
    private func fail(_ message: String) {
        entries.append(IDEAgentEntry(kind: .error, text: message))
        finishRun()
    }

    private func finishRun() {
        flushPending()
        closeStreamingEntry()
        isRunning = false
        status = nil
        runTask = nil
        onRunFinished?()
        Task { await persistCurrent() }
    }

    // MARK: - Saving

    private func persistCurrent() async {
        guard let store, !entries.isEmpty else { return }
        let items: [ConversationItem]
        if let session { items = await session.items } else { items = restoredItems ?? [] }
        guard !items.isEmpty else { return }
        let snapshot = SessionSnapshot(
            id: conversationID, projectRoot: Self.storeRoot, title: title, createdAt: createdAt, updatedAt: Date(),
            items: items, totalUsage: usage,
            host: IDEAgentSavedTranscript.encode(
                entries: entries, cost: cost, customTitle: customTitle, modelChoice: modelChoice ?? effectiveChoice))
        // A write failure only costs the history; it is not worth interrupting the user for.
        try? store.save(snapshot)
        onPersisted?()
    }

    /// Summarizes the earlier messages now, to make room in the model's window.
    func compact() async {
        guard !isRunning, let session else { return }
        do {
            let report = try await session.compactNow()
            if report.changedAnything {
                entries.append(IDEAgentEntry(kind: .notice, text: "Earlier messages were summarized to make room in the model's window."))
            }
        } catch {
            entries.append(IDEAgentEntry(kind: .notice, text: "Could not summarize: \(error.localizedDescription)"))
        }
    }

    /// Names the chat; a saved one is saved again so the name outlives the window.
    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        customTitle = trimmed.isEmpty ? nil : String(trimmed.prefix(80))
        Task { await persistCurrent() }
    }

    /// Empties the chat in place, under a new identity. The one being left stays in the history.
    func reset() {
        guard !isRunning else { return }
        session = nil
        sessionFingerprint = nil
        restoredItems = nil
        entries = []
        usage = TokenUsage()
        cost = 0
        contextTokens = nil
        status = nil
        customTitle = nil
        conversationID = UUID()
        createdAt = Date()
    }

    /// Replaces the chat with a saved one.
    func load(_ snapshot: SessionSnapshot) {
        guard !isRunning else { return }
        session = nil
        sessionFingerprint = nil
        let saved = IDEAgentSavedTranscript.decode(snapshot.host)
        entries = saved.entries.compactMap { $0.restoredEntry(blobs: nil) }
        cost = saved.cost
        usage = snapshot.totalUsage
        // Provider items go back only to the model that wrote them; the transcript is enough.
        restoredItems = snapshot.items.filter { if case .opaque = $0 { false } else { true } }
        conversationID = snapshot.id
        createdAt = snapshot.createdAt
        customTitle = saved.customTitle
        modelChoice = saved.modelChoice
        contextTokens = nil
        status = nil
    }

    /// Ends a run and drops the session; the window is closing.
    func teardown() {
        stopRequested = true
        let session = session
        runTask?.cancel()
        Task { await session?.stop() }
        flushTask?.cancel()
        self.session = nil
    }
}
