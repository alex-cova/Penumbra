import AgentKit
import Foundation
import GitIntelligence
import LocalModelStore
import Observation

/// One window's agent: the transcript the panel shows, and the `AgentSession` behind it.
///
/// Streaming text is coalesced (flushed about every 50 ms) so a fast model doesn't re-render the
/// transcript per token. Everything the agent touches in the window goes through `IDEAgentHost`,
/// held weakly, so a running session never keeps the window alive; `teardown()` ends it.
@MainActor
@Observable
final class IDEAgentController {
    static let flushInterval: Duration = .milliseconds(50)

    private(set) var entries: [IDEAgentEntry] = []
    private(set) var isRunning = false
    /// What the run is doing right now, for the panel's status line.
    private(set) var status: String?
    private(set) var usage = TokenUsage()
    /// Estimated dollars for the conversation, or `nil` when any turn had no known price (a local
    /// model, or a model the price table doesn't list).
    private(set) var cost: Double? = 0
    /// The model's checklist (`todo`), shown above the transcript.
    private(set) var todos: [TodoItem] = []
    var draft = ""
    var isPanelVisible = false
    /// Called before the chat page opens, so the window can close what it would cover (Settings).
    @ObservationIgnored var onPanelRequested: (() -> Void)?
    /// Bumped when something fills the composer from outside, so the panel moves focus to it.
    var composerFocusRequest = 0
    /// This project's saved conversations, newest first, for the history menu.
    private(set) var history: [SessionSummary] = []
    private(set) var conversationID = UUID()

    let settings: IDEAgentSettings

    @ObservationIgnored private weak var host: (any IDEAgentHost)?
    @ObservationIgnored private var session: AgentSession?
    @ObservationIgnored private var sessionFingerprint: String?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Where the current model turn's entries begin, so a retried turn can drop them.
    @ObservationIgnored private var turnStart = 0
    @ObservationIgnored private var currentRun: RunID?
    @ObservationIgnored private var pendingOutput: [String: String] = [:]
    /// True while a Gradle run the agent started is going, so Stop ends that run and no other.
    @ObservationIgnored var isGradleRunActive = false
    @ObservationIgnored private let clientFactory: @MainActor (IDEAgentSettings) throws -> any LLMClient
    @ObservationIgnored private let store: SessionStore?
    /// Items of a conversation loaded from disk, handed to the session that is created for it.
    @ObservationIgnored private var restoredItems: [ConversationItem]?
    @ObservationIgnored private var restoredTodos: [TodoItem] = []
    @ObservationIgnored private var createdAt = Date()
    @ObservationIgnored private var didRestore = false

    /// For tests that look at the live session's state (its checklist).
    var currentSessionForTesting: AgentSession? { session }

    private var iterationLimit: Int { settings.iterationCap }

    /// Conversations live in Application Support, readable by the user alone.
    static func appStore() -> SessionStore? {
        (try? SessionStore.defaultDirectory(appFolder: "com.umbra.editor")).map(SessionStore.init)
    }

    init(
        settings: IDEAgentSettings = .shared,
        store: SessionStore? = nil,
        clientFactory: @escaping @MainActor (IDEAgentSettings) throws -> any LLMClient = { try $0.makeClient() }
    ) {
        self.settings = settings
        self.store = store
        self.clientFactory = clientFactory
    }

    /// True while the chat covers the editor area. Docked beside the editor it never does, and then
    /// opening a file or another tab leaves it alone.
    var coversEditor: Bool { isPanelVisible && settings.opensAsPage }

    /// Closes the chat if it is open as a page (what choosing an editor tab or file does).
    func dismissPage() {
        if settings.opensAsPage { isPanelVisible = false }
    }

    /// Opens the chat and puts the caret in the composer.
    func showPanel() {
        onPanelRequested?()
        isPanelVisible = true
        composerFocusRequest += 1
    }

    func attach(host: any IDEAgentHost) {
        self.host = host
    }

    var canSend: Bool {
        !isRunning && settings.hasAcceptedDisclosure && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Sending

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, let host else { return }
        guard let root = host.agentProjectRoot else {
            append(.init(kind: .error, text: "Open a project folder first; the agent works inside one."))
            return
        }

        restoreLatestIfNeeded()
        draft = ""
        append(.init(kind: .user, text: text))
        // The model sees the editor's state with the message; the transcript shows only the message.
        let framed = host.agentEditorContext() + "\n\n" + text
        isRunning = true
        status = "Thinking…"
        runTask = Task { [weak self] in
            guard let self else { return }
            let activeSession: AgentSession
            do {
                activeSession = try await self.currentSession(root: root, host: host)
            } catch {
                self.append(.init(kind: .error, text: error.localizedDescription))
                self.isRunning = false
                self.status = nil
                return
            }
            // Loading an on-device model reads gigabytes; say so, and fail visibly rather than inside the first turn.
            if self.settings.provider == .mlx, let model = self.settings.selectedMLXModel {
                let models = IDELocalModelsStore.shared
                if models.loadedID != model.id {
                    self.status = "Loading \(LocalModelFormat.shortName(model.id))…"
                    await models.load(model)
                }
                if let error = models.loadError, models.loadedID != model.id {
                    self.append(.init(kind: .error, text: error))
                    self.isRunning = false
                    self.status = nil
                    return
                }
            }
            await self.consume(await activeSession.send(framed), session: activeSession)
        }
    }

    /// Cancels the stream and running tools. The run ends with a "Stopped." notice and the next
    /// message continues the conversation.
    func stop() {
        guard isRunning, let session else { return }
        Task { await session.stop() }
    }

    /// Starts an empty conversation. The one being left stays in the history.
    func newConversation() {
        endSession()
        entries = []
        usage = TokenUsage()
        cost = 0
        todos = []
        restoredTodos = []
        status = nil
        restoredItems = nil
        conversationID = UUID()
        createdAt = Date()
        didRestore = true
    }

    func clear() { newConversation() }

    // MARK: - History

    /// Brings back the project's most recent conversation the first time the agent is used in a
    /// window. Reverting its changes is not offered: checkpoints do not survive a relaunch.
    func restoreLatestIfNeeded() {
        guard !didRestore else { return }
        didRestore = true
        refreshHistory()
        guard entries.isEmpty, !isRunning, let latest = history.first else { return }
        resume(latest.id)
    }

    func refreshHistory() {
        guard let store, let root = host?.agentProjectRoot else { history = []; return }
        history = store.list(projectRoot: root.path)
    }

    func resume(_ id: UUID) {
        guard !isRunning, let store, let root = host?.agentProjectRoot,
              let snapshot = store.load(id, projectRoot: root.path)
        else { return }
        endSession()
        let saved = IDEAgentSavedTranscript.decode(snapshot.host)
        entries = saved.entries.map(\.entry)
        cost = saved.cost
        todos = saved.todos
        restoredTodos = saved.todos
        usage = snapshot.totalUsage
        // Provider items only the model that produced them may be sent back; the transcript is enough.
        restoredItems = snapshot.items.filter { if case .opaque = $0 { false } else { true } }
        conversationID = snapshot.id
        createdAt = snapshot.createdAt
        status = nil
        didRestore = true
    }

    func deleteConversation(_ id: UUID) {
        guard let store, let root = host?.agentProjectRoot else { return }
        store.delete(id, projectRoot: root.path)
        if id == conversationID, !isRunning { newConversation() }
        refreshHistory()
    }

    /// Settings ▸ Agent ▸ Clear History: every saved conversation of this project.
    func clearHistory() {
        guard let store, let root = host?.agentProjectRoot else { return }
        store.deleteAll(projectRoot: root.path)
        history = []
    }

    private func persist(_ session: AgentSession) async {
        guard let store, let root = host?.agentProjectRoot else { return }
        let items = await session.items
        guard !items.isEmpty else { return }
        let snapshot = SessionSnapshot(
            id: conversationID, projectRoot: root.path, title: SessionStore.title(from: items),
            createdAt: createdAt, updatedAt: Date(), items: items, totalUsage: usage,
            host: IDEAgentSavedTranscript.encode(entries: entries, cost: cost, todos: todos))
        // A write failure only costs the history; it is not worth interrupting the user for.
        try? store.save(snapshot)
        refreshHistory()
    }

    /// Cancels the run and drops the session. A session that outlives its window would keep the
    /// workspace alive through its tools.
    func teardown() {
        endSession()
        host = nil
    }

    private func endSession() {
        let old = session
        runTask?.cancel()
        runTask = nil
        flushTask?.cancel()
        flushTask = nil
        pendingText = ""
        pendingOutput = [:]
        session = nil
        sessionFingerprint = nil
        isRunning = false
        Task { await old?.stop() }
    }

    // MARK: - Session

    private func currentSession(root: URL, host: any IDEAgentHost) async throws -> AgentSession {
        let fingerprint = settings.fingerprint + "|" + root.path + "|" + String(host.agentIsGradleProject)
        if let session, sessionFingerprint == fingerprint { return session }

        let client = try clientFactory(settings)
        // A settings change keeps the conversation, minus provider items that only the old model
        // or endpoint may be sent back.
        var history: [ConversationItem] = []
        if let previous = session {
            history = await previous.items.filter { if case .opaque = $0 { false } else { true } }
        } else if let restored = restoredItems {
            history = restored
        }
        restoredItems = nil
        let box = IDEAgentHostBox(host)
        let workspace = IDEAgentWorkspace(root: root, box: box)
        let support = IDEAgentCommandSupport(root: root, box: box)
        var tools: [any AgentTool] = ReadOnlyTools.all(secretPatterns: settings.secretFilePatterns) + EditingTools.all() + [IDERunCommandTool(support: support)]
        if host.agentIsGradleProject { tools += [IDEGradleTool(support: support), IDERunTestsTool(support: support)] }
        tools += [TodoTool(), AskUserTool()]
        let git = IDEAgentGitSource(
            projectRoot: root, secretPatterns: SecretFilePolicy.patterns(from: settings.secretFilePatterns),
            unsavedBuffers: { await box.read(default: [:]) { $0.agentUnsavedBuffers() } })
        if await GitRepository.discover(from: root, runner: git.runner) != nil {
            tools += [IDEGitStatusTool(source: git), IDEGitDiffTool(source: git)]
        }
        if let navigator = host.agentJavaNavigator() {
            let lineText: @Sendable (URL, Int) async -> String? = { url, line in await box.lineText(url: url, line: line) }
            tools += [
                IDEGoToDefinitionTool(navigator: navigator, lineText: lineText),
                IDEFindUsagesTool(navigator: navigator, lineText: lineText),
            ]
        }
        tools.append(IDEDiagnosticsTool(
            problems: { await box.read(default: []) { $0.agentProblems() } },
            fresh: { await box.freshProblems(relativePaths: $0) }))
        let configuration = AgentConfiguration(
            model: settings.model,
            systemPrompt: SystemPrompt.make(
                projectRoot: workspace.rootPath, notes: IDEAgentProjectNotes.load(root: root), mode: settings.mode),
            reasoningEffort: settings.effectiveReasoningEffort,
            maxIterations: settings.iterationCap,
            cacheKey: "umbra-agent-\(root.path.hashValue)",
            contextWindow: settings.contextWindow,
            mode: settings.mode)
        let created = AgentSession(
            client: client, tools: tools, workspace: workspace, configuration: configuration, history: history)
        // A restored conversation whose checklist the history no longer shows (compaction) keeps the saved one.
        if !restoredTodos.isEmpty, await created.todoList.items.isEmpty { await created.setTodos(restoredTodos) }
        restoredTodos = []
        session = created
        sessionFingerprint = fingerprint
        return created
    }

    // MARK: - Events

    private func consume(_ stream: AsyncStream<AgentEvent>, session: AgentSession) async {
        for await event in stream { handle(event) }
        flush()
        await appendChangeSummary(for: currentRun, session: session)
        currentRun = nil
        isRunning = false
        status = nil
        await persist(session)
    }

    /// "N files changed" for a run that changed any, after its closing notice.
    private func appendChangeSummary(for run: RunID?, session: AgentSession) async {
        guard let run else { return }
        let changes = await session.checkpoints.changes(in: run)
        guard !changes.isEmpty else { return }
        var entry = IDEAgentEntry(kind: .changes, text: "")
        entry.run = run
        entry.fileChanges = changes.map { IDEAgentFileChange(path: $0.path, original: $0.original) }
        append(entry)
    }

    // MARK: - Reverting

    // MARK: - Approvals

    /// Answers the question on a command's card. The run is paused until this is called, or Stop.
    func decide(callID: String, _ decision: ApprovalDecision) {
        guard let session else { return }
        if let index = toolIndex(callID) {
            entries[index].approval = nil
            entries[index].approvalOutcome = switch decision {
            case .approve: "Approved"
            case .approveEditing: "Edited and approved"
            case .deny: "Denied"
            }
        }
        Task { await session.resolveApproval(callID: callID, decision: decision) }
    }

    /// Answers an `ask_user` card; `nil` skips it, and the model is told to use its judgment.
    func answer(callID: String, text: String?) {
        guard let session else { return }
        if let index = toolIndex(callID) {
            entries[index].question = nil
            entries[index].questionOutcome = text == nil ? "Skipped" : "Answered"
        }
        Task { await session.answerQuestion(callID: callID, answer: text) }
    }

    func showDiff(for change: IDEAgentFileChange) {
        host?.agentShowDiff(relativePath: change.path, original: change.original)
    }

    /// Puts a finished run's files back. A file the user changed after the agent wrote it is left
    /// alone and listed on the card, where Show Diff compares it with the original.
    func revert(entryID: UUID) {
        guard !isRunning, let session,
              let entry = entries.first(where: { $0.id == entryID }), let run = entry.run, !entry.isReverted
        else { return }
        Task { [weak self] in
            do {
                let report = try await session.revertRun(run)
                self?.finishRevert(entryID: entryID, report: report)
            } catch {
                self?.append(.init(kind: .error, text: error.localizedDescription))
            }
        }
    }

    private func finishRevert(entryID: UUID, report: RevertReport) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[index].conflicts = report.conflicts.map { IDEAgentFileChange(path: $0.path, original: $0.original) }
        entries[index].isReverted = report.isComplete
        var parts: [String] = []
        if !report.reverted.isEmpty { parts.append("Reverted \(report.reverted.count) \(report.reverted.count == 1 ? "file" : "files").") }
        if !report.conflicts.isEmpty {
            parts.append("\(report.conflicts.count) changed since the agent wrote \(report.conflicts.count == 1 ? "it" : "them") and \(report.conflicts.count == 1 ? "was" : "were") left as is.")
        }
        if !parts.isEmpty { append(.init(kind: .notice, text: parts.joined(separator: " "))) }
        for (path, reason) in report.failures.sorted(by: { $0.key < $1.key }) {
            append(.init(kind: .error, text: "Could not revert \(path): \(reason)"))
        }
    }

    func handle(_ event: AgentEvent) {
        if case .textDelta(let delta) = event {
            pendingText += delta
            scheduleFlush()
            return
        }
        if case .toolCallOutput(let id, let chunk) = event {
            pendingOutput[id, default: ""] += chunk
            scheduleFlush()
            return
        }
        flush()

        switch event {
        case .runStarted(let id):
            currentRun = id
        case .stateChanged(let state):
            switch state {
            case .idle: status = nil
            case .streaming:
                turnStart = entries.count
                status = "Thinking…"
            case .runningTools(let names): status = "Running \(names.joined(separator: ", "))…"
            case .awaitingApproval: status = "Waiting for your approval…"
            case .awaitingAnswer: status = "Waiting for your answer…"
            }
        case .textDelta, .reasoningDelta:
            break
        case .turnRestarted:
            entries.removeSubrange(min(turnStart, entries.count)...)
            status = "Retrying…"
        case .assistantMessage(let text):
            // The turn's finished text. Its streamed copy is already in the transcript, ahead of
            // any tool cards the same turn produced (a tool call closes the streaming entry), so
            // finalize that one instead of adding a second.
            let streamed = entries.indices.last { $0 >= min(turnStart, entries.count) && entries[$0].kind == .assistant }
            if let index = streamed {
                entries[index].text = text
                entries[index].isStreaming = false
            } else {
                append(.init(kind: .assistant, text: text))
            }
        case .toolCallStarted(let id, let name):
            closeStreamingEntry()
            append(.init(kind: .toolCall(name: name), text: "", callID: id))
        case .toolCallArguments(let id, _, let arguments):
            if let index = toolIndex(id) { entries[index].text = arguments }
        case .toolCallFinished(let id, _, let output):
            if let index = toolIndex(id) {
                entries[index].output = output
                // Finished without an answer (Stop): the question is moot.
                entries[index].approval = nil
                entries[index].question = nil
            }
        case .toolCallOutput:
            break
        case .approvalRequested(let request):
            if let index = toolIndex(request.callID) { entries[index].approval = request }
        case .questionAsked(let question):
            if let index = toolIndex(question.callID) { entries[index].question = question }
        case .todosUpdated(let items):
            todos = items
        case .unreadableToolCall:
            // The loop has told the model and it is trying again; say so rather than leave a silent gap.
            append(.init(kind: .notice, text: "The model wrote a tool call that could not be read. Asking it to try again."))
        case .compacted(let report):
            if let notice = Self.compactionNotice(report) { append(.init(kind: .notice, text: notice)) }
        case .usage(let turnUsage):
            usage = usage + turnUsage
            if let turnCost = settings.cost(of: turnUsage), let total = cost { cost = total + turnCost } else { cost = nil }
        case .runEnded(let ending):
            closeStreamingEntry()
            if let message = IDEAgentToolSummary.endingMessage(ending, iterationLimit: iterationLimit) {
                append(.init(kind: message.isError ? .error : .notice, text: message.text))
            }
        }
    }

    /// What the transcript says when the agent shortened its own context. Nothing for a pass that changed nothing.
    static func compactionNotice(_ report: CompactionReport) -> String? {
        guard report.changedAnything else { return nil }
        var parts: [String] = []
        if report.stubbedOutputs > 0 { parts.append("cleared \(report.stubbedOutputs) old tool \(report.stubbedOutputs == 1 ? "output" : "outputs")") }
        if report.summarizedItems > 0 { parts.append("summarized \(report.summarizedItems) earlier messages") }
        var text = "Context was getting full: " + parts.joined(separator: " and ") + "."
        if report.summaryFailed { text += " The summary could not be written, so only old outputs were cleared." }
        return text
    }

    private var streamingIndex: Int? {
        entries.lastIndex { $0.kind == .assistant && $0.isStreaming }
    }

    private func toolIndex(_ id: String) -> Int? {
        entries.lastIndex { $0.callID == id }
    }

    private func closeStreamingEntry() {
        if let index = streamingIndex { entries[index].isStreaming = false }
    }

    private func append(_ entry: IDEAgentEntry) {
        entries.append(entry)
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Moves buffered text into the streaming assistant entry, starting one if needed, and buffered
    /// command output into its tool card.
    private func flush() {
        flushTask?.cancel()
        flushTask = nil
        if !pendingOutput.isEmpty {
            for (id, chunk) in pendingOutput {
                guard let index = toolIndex(id) else { continue }
                entries[index].liveOutput = IDEAgentLiveOutput.append(entries[index].liveOutput, chunk)
            }
            pendingOutput = [:]
        }
        guard !pendingText.isEmpty else { return }
        defer { pendingText = "" }
        if let index = streamingIndex {
            entries[index].text += pendingText
        } else {
            var entry = IDEAgentEntry(kind: .assistant, text: pendingText)
            entry.isStreaming = true
            append(entry)
        }
    }
}
