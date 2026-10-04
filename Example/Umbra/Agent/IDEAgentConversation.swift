import AgentKit
import Foundation
import GitIntelligence
import LocalModelStore
import Observation

/// One conversation: the transcript the panel shows, and the `AgentSession` behind it.
///
/// Streaming text is coalesced (flushed about every 50 ms) so a fast model doesn't re-render the
/// transcript per token. Everything the agent touches in the window goes through `IDEAgentHost`,
/// held weakly, so a running session never keeps the window alive; `teardown()` ends it.
/// `IDEAgentController` owns the window's conversations and what they share.
@MainActor
@Observable
final class IDEAgentConversation: Identifiable {
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
    /// What the agent may do without asking, in this chat. New chats start from the setting.
    private(set) var mode: PermissionMode
    /// The saved session's identity. It changes when the conversation is reset or another is loaded.
    private(set) var conversationID = UUID()
    /// What names this conversation's tab: stable for as long as the tab exists.
    nonisolated let id = UUID()
    /// A name the user gave the tab; without one it is the first message.
    var customTitle: String?
    /// A reply finished while the tab was in the background.
    var isUnread = false
    /// A saved conversation this tab shows but has not read from disk yet (restored tabs load when selected).
    private(set) var pendingLoadID: UUID?
    private var summaryTitle: String?
    /// The run is waiting for the user: an approval or a question is open.
    private(set) var isAwaitingUser = false

    let settings: IDEAgentSettings

    @ObservationIgnored weak var host: (any IDEAgentHost)?
    /// Shared by the window's chats; `nil` when there is only ever one.
    @ObservationIgnored var fileClaims: IDEAgentFileClaims?
    /// The window's commands and skills; the model is offered the skills.
    @ObservationIgnored var commandCatalog: IDEAgentCommandCatalog?
    /// Called when a run ends, with whether it ended.
    @ObservationIgnored var onRunFinished: (() -> Void)?
    /// Called after the conversation was saved, so the window's history list can refresh.
    @ObservationIgnored var onPersisted: (() -> Void)?
    /// Called when a message is about to be sent, before it is added to the transcript.
    @ObservationIgnored var willSend: (() -> Void)?
    @ObservationIgnored private var session: AgentSession?
    @ObservationIgnored private var sessionFingerprint: String?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Where the current model turn's entries begin, so a retried turn can drop them.
    @ObservationIgnored private var turnStart = 0
    @ObservationIgnored private var currentRun: RunID?
    @ObservationIgnored private var pendingOutput: [String: String] = [:]
    @ObservationIgnored private let clientFactory: @MainActor (IDEAgentSettings) throws -> any LLMClient
    @ObservationIgnored private let store: SessionStore?
    /// The app-wide permission rules file; `nil` in tests, which must not read the user's own.
    @ObservationIgnored private let appPermissionsFile: URL?
    /// Rules that last as long as this chat ("Allow for this chat").
    @ObservationIgnored private var chatRules = PermissionRules()
    /// Rules for the run in progress: the tools a command or skill said it may use.
    @ObservationIgnored private var runRules = PermissionRules()
    /// Items of a conversation loaded from disk, handed to the session that is created for it.
    @ObservationIgnored private var restoredItems: [ConversationItem]?
    @ObservationIgnored private var restoredTodos: [TodoItem] = []
    @ObservationIgnored private var createdAt = Date()

    /// For tests that look at the live session's state (its checklist).
    var currentSessionForTesting: AgentSession? { session }

    private var iterationLimit: Int { settings.iterationCap }

    init(
        settings: IDEAgentSettings,
        store: SessionStore?,
        appPermissionsFile: URL? = nil,
        clientFactory: @escaping @MainActor (IDEAgentSettings) throws -> any LLMClient
    ) {
        self.settings = settings
        self.store = store
        self.appPermissionsFile = appPermissionsFile
        self.clientFactory = clientFactory
        self.mode = settings.mode
    }

    var canSend: Bool {
        !isRunning && settings.hasAcceptedDisclosure && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Sending

    func send() {
        guard canSend else { return }
        submit(text: draft.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Sends a message. The transcript shows `text`; the model gets `modelText` when it differs (a
    /// command's expansion, a skill's instructions), which the row offers as `detail`. `allowedTools` are
    /// permission rules for this run only. The draft is cleared once the message is on its way.
    func submit(text: String, modelText: String? = nil, allowedTools: [String] = []) {
        guard !isRunning, settings.hasAcceptedDisclosure, !text.isEmpty, let host else { return }
        guard let root = host.agentProjectRoot else {
            append(.init(kind: .error, text: "Open a project folder first; the agent works inside one."))
            return
        }

        willSend?()
        commandCatalog?.invalidate()
        draft = ""
        var entry = IDEAgentEntry(kind: .user, text: text)
        if let modelText, modelText != text { entry.detail = modelText }
        append(entry)
        runRules = PermissionRules(allow: allowedTools.compactMap(PermissionRule.init(parsing:)))
        // The model sees the editor's state with the message; the transcript shows only the message.
        let framed = host.agentEditorContext() + "\n\n" + (modelText ?? text)
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
            // Whatever changed since the session was made (the mode, a rules file) applies to this run.
            await activeSession.setMode(self.mode)
            await activeSession.setRules(self.currentRules(root: root))
            await self.consume(await activeSession.send(framed), session: activeSession)
        }
    }

    // MARK: - Permissions

    /// The files' rules and this chat's own, merged.
    private func currentRules(root: URL?) -> PermissionRules {
        IDEAgentPermissionFiles.load(projectRoot: root, appFile: appPermissionsFile).merged(with: chatRules).merged(with: runRules)
    }

    /// Changes the mode for the calls that follow, mid-run if need be.
    func setMode(_ newMode: PermissionMode) {
        guard newMode != mode else { return }
        mode = newMode
        if let session { Task { await session.setMode(newMode) } }
    }

    func cycleMode() { setMode(mode.next) }

    /// What the approval card's extra buttons do, besides running this one call.
    enum ApprovalShortcut {
        /// "Allow … in this chat": a rule that ends with the chat.
        case allowForChat(PermissionRule)
        /// "Always allow … in this project": written to `.umbra/settings.local.json`.
        case allowInProject(PermissionRule)
        /// "Accept all edits in this chat".
        case acceptEdits
    }

    /// Approves the call and applies the shortcut. A rule that cannot be saved is reported, and the
    /// call is still approved: the user asked for this run too.
    func approve(callID: String, shortcut: ApprovalShortcut) {
        switch shortcut {
        case .allowForChat(let rule):
            chatRules.add(rule, to: .allow)
            pushRules()
        case .allowInProject(let rule):
            saveProjectRule(rule)
        case .acceptEdits:
            setMode(.acceptEdits)
        }
        decide(callID: callID, .approve)
    }

    private func saveProjectRule(_ rule: PermissionRule) {
        guard let root = host?.agentProjectRoot,
              let file = IDEAgentPermissionFiles.file(for: .project, projectRoot: root, appFile: appPermissionsFile)
        else { return appendError("Open a project folder first; rules are saved in the project.") }
        let existed = FileManager.default.fileExists(atPath: file.path)
        do {
            try IDEAgentPermissionFiles.add(rule, to: .allow, in: file)
            appendNotice("Saved \(rule) to \(IDEAgentPermissionFiles.projectLocalPath)."
                + (existed ? "" : " It is your own file: add it to .gitignore if the project is shared."))
            pushRules()
        } catch {
            appendError("Could not save the rule: \(error.localizedDescription)")
            chatRules.add(rule, to: .allow)
            pushRules()
        }
    }

    private func pushRules() {
        guard let session, let root = host?.agentProjectRoot else { return }
        let rules = currentRules(root: root)
        Task { await session.setRules(rules) }
    }

    /// Cancels the stream and running tools. The run ends with a "Stopped." notice and the next
    /// message continues the conversation.
    func stop() {
        guard isRunning, let session else { return }
        Task { await session.stop() }
    }

    /// Empties the conversation in place, under a new identity. The one being left stays in the history.
    func reset() {
        endSession()
        entries = []
        usage = TokenUsage()
        cost = 0
        todos = []
        restoredTodos = []
        status = nil
        restoredItems = nil
        chatRules = PermissionRules()
        conversationID = UUID()
        createdAt = Date()
        pendingLoadID = nil
        summaryTitle = nil
        customTitle = nil
        isAwaitingUser = false
        fileClaims?.release(tab: id)
    }

    var isEmpty: Bool { entries.isEmpty && pendingLoadID == nil }

    private static let maxTitleLength = 36

    /// What the tab says: the user's name for it, else the first message, else what was saved.
    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if let first = entries.first(where: { $0.kind == .user }) { return Self.title(fromMessage: first.text) }
        return summaryTitle ?? "New Chat"
    }

    static func title(fromMessage text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > maxTitleLength else { return trimmed.isEmpty ? "New Chat" : trimmed }
        return String(trimmed.prefix(maxTitleLength - 1)) + "…"
    }

    /// Shows a saved conversation without reading it yet.
    func showPending(id: UUID, title: String) {
        conversationID = id
        pendingLoadID = id
        summaryTitle = title
    }

    /// A pending conversation that turned out to be gone becomes an empty chat.
    func dropPending() {
        pendingLoadID = nil
        summaryTitle = nil
        conversationID = UUID()
    }

    // MARK: - Saving and loading

    /// Replaces the conversation with a saved one.
    func load(_ snapshot: SessionSnapshot) {
        guard !isRunning else { return }
        endSession()
        let saved = IDEAgentSavedTranscript.decode(snapshot.host)
        entries = saved.entries.map(\.entry)
        cost = saved.cost
        todos = saved.todos
        restoredTodos = saved.todos
        usage = snapshot.totalUsage
        // Provider items only the model that produced them may be sent back; the transcript is enough.
        restoredItems = snapshot.items.filter { if case .opaque = $0 { false } else { true } }
        chatRules = PermissionRules()
        conversationID = snapshot.id
        createdAt = snapshot.createdAt
        pendingLoadID = nil
        summaryTitle = snapshot.title
        customTitle = saved.customTitle
        status = nil
    }

    private func persist(items: [ConversationItem]) {
        guard let store, let root = host?.agentProjectRoot, !items.isEmpty else { return }
        let snapshot = SessionSnapshot(
            id: conversationID, projectRoot: root.path, title: customTitle ?? SessionStore.title(from: items),
            createdAt: createdAt, updatedAt: Date(), items: items, totalUsage: usage,
            host: IDEAgentSavedTranscript.encode(entries: entries, cost: cost, todos: todos, customTitle: customTitle))
        // A write failure only costs the history; it is not worth interrupting the user for.
        try? store.save(snapshot)
        onPersisted?()
    }

    /// Names the tab. A saved conversation is saved again so the name outlives the window.
    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        customTitle = trimmed.isEmpty ? nil : String(trimmed.prefix(80))
        Task {
            if let session { persist(items: await session.items) } else if let restoredItems { persist(items: restoredItems) }
        }
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
        isAwaitingUser = false
        runRules = PermissionRules()
        fileClaims?.release(tab: id)
        Task { await old?.stop() }
    }

    // MARK: - Session

    private func currentSession(root: URL, host: any IDEAgentHost) async throws -> AgentSession {
        // Skills are in the tool list, so a changed one starts a new session (which keeps the conversation).
        let skills = commandCatalog.map(\.skillCatalog).flatMap { $0.skills.isEmpty ? nil : $0 }
        let fingerprint = settings.fingerprint + "|" + root.path + "|" + String(host.agentIsGradleProject) + "|" + (skills?.fingerprint ?? "")
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
        if let skills { tools.append(SkillTool(catalog: skills)) }
        tools.append(IDEDiagnosticsTool(
            problems: { await box.read(default: []) { $0.agentProblems() } },
            fresh: { await box.freshProblems(relativePaths: $0) }))
        let configuration = AgentConfiguration(
            model: settings.model,
            systemPrompt: SystemPrompt.make(
                projectRoot: workspace.rootPath, notes: IDEAgentProjectNotes.load(root: root), mode: mode),
            reasoningEffort: settings.effectiveReasoningEffort,
            maxIterations: settings.iterationCap,
            cacheKey: Self.cacheKey(root: root, conversationID: conversationID),
            contextWindow: settings.contextWindow,
            mode: mode,
            permissions: currentRules(root: root),
            gate: fileClaims.map { claims in
                IDEAgentClaimsGate(claims: claims, tab: id, title: { [weak self] in self?.title ?? "another chat" })
            },
            secretPatterns: SecretFilePolicy.patterns(from: settings.secretFilePatterns))
        let created = AgentSession(
            client: client, tools: tools, workspace: workspace, configuration: configuration, history: history)
        // A restored conversation whose checklist the history no longer shows (compaction) keeps the saved one.
        if !restoredTodos.isEmpty, await created.todoList.items.isEmpty { await created.setTodos(restoredTodos) }
        restoredTodos = []
        session = created
        sessionFingerprint = fingerprint
        return created
    }

    /// Stable across launches (`hashValue` is seeded per process, which made it change every time), so
    /// the provider can keep reusing its cache of this conversation's prefix.
    nonisolated static func cacheKey(root: URL, conversationID: UUID) -> String {
        "umbra-agent-\(String(CheckpointLog.hash(of: root.standardizedFileURL.path), radix: 16))-\(conversationID.uuidString)"
    }

    // MARK: - Events

    private func consume(_ stream: AsyncStream<AgentEvent>, session: AgentSession) async {
        for await event in stream { handle(event) }
        flush()
        await appendChangeSummary(for: currentRun, session: session)
        currentRun = nil
        isRunning = false
        isAwaitingUser = false
        status = nil
        runRules = PermissionRules()
        fileClaims?.release(tab: id)
        persist(items: await session.items)
        onRunFinished?()
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
        isAwaitingUser = entries.contains { $0.approval != nil || $0.question != nil }
        Task { await session.resolveApproval(callID: callID, decision: decision) }
    }

    /// Answers an `ask_user` card; `nil` skips it, and the model is told to use its judgment.
    func answer(callID: String, text: String?) {
        guard let session else { return }
        if let index = toolIndex(callID) {
            entries[index].question = nil
            entries[index].questionOutcome = text == nil ? "Skipped" : "Answered"
        }
        isAwaitingUser = entries.contains { $0.approval != nil || $0.question != nil }
        Task { await session.answerQuestion(callID: callID, answer: text) }
    }

    // MARK: - Reverting

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
            isAwaitingUser = true
        case .questionAsked(let question):
            if let index = toolIndex(question.callID) { entries[index].question = question }
            isAwaitingUser = true
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

    func appendNotice(_ text: String) { append(.init(kind: .notice, text: text)) }

    func appendError(_ text: String) { append(.init(kind: .error, text: text)) }

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
