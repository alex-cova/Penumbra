import AgentKit
import Foundation
import GitIntelligence
import JavaIntelligence
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
    /// Tokens the conversation takes in the model's window, as the provider last reported them (or as
    /// compaction left them). `nil` until a turn has reported, e.g. in a chat just restored.
    private(set) var contextTokens: Int?
    /// `/compact` is summarizing the conversation.
    private(set) var isCompacting = false

    /// A message written while a run was going, waiting for the model's next turn.
    struct QueuedMessage: Identifiable, Equatable {
        let id = UUID()
        var text: String
    }

    /// Messages written during a run, in order. The model sees them on its next turn (or, if the run
    /// ends first, they go as the next message); stopping the run puts them back in the field.
    private(set) var queue: [QueuedMessage] = []
    @ObservationIgnored private var lastEnding: RunEnding?
    /// Stop was pressed; a run that has not started streaming yet ends instead of starting.
    @ObservationIgnored private var stopRequested = false
    /// Commands the user ran with `!`, with their output, to go with the next message.
    @ObservationIgnored private var shellContext: [String] = []
    @ObservationIgnored private var shellTask: Task<Void, Never>?

    let settings: IDEAgentSettings

    /// The model this chat was given in AI mode; `nil` follows the global agent settings (the docked
    /// panel's behavior). Saved with the chat. Changing it starts a new session on the next send,
    /// which keeps the conversation.
    var modelChoice: IDEAIModelChoice?
    /// Builds the client for a chat that has its own choice. The factory given at creation serves the
    /// chats that follow the settings, so existing callers and tests are unchanged.
    @ObservationIgnored var choiceClientFactory: @MainActor (IDEAgentSettings, IDEAIModelChoice) throws -> any LLMClient = {
        try $0.makeClient(for: $1)
    }

    /// What this chat uses now: its own choice, else the global settings.
    var effectiveChoice: IDEAIModelChoice { modelChoice ?? settings.currentChoice }

    /// The external agent driving this chat, when it has one and may run it.
    private var acpDefinition: IDEACPDefinition? { settings.acpAgent(for: effectiveChoice) }

    @ObservationIgnored weak var host: (any IDEAgentHost)?
    /// Shared by the window's chats; `nil` when there is only ever one.
    @ObservationIgnored var fileClaims: IDEAgentFileClaims?
    /// The window's commands and skills; the model is offered the skills.
    @ObservationIgnored var commandCatalog: IDEAgentCommandCatalog?
    /// Called when a run ends, with whether it ended.
    @ObservationIgnored var onRunFinished: (() -> Void)?
    /// Called when the chat has something the user may want to know about while looking elsewhere.
    @ObservationIgnored var onAttention: ((Attention) -> Void)?

    enum Attention: Equatable {
        /// The run needs an approval, an answer or a decision on a plan; the text says what.
        case needsYou(String)
        /// The run ended.
        case finished(RunEnding, summary: String)
    }
    /// Called after the conversation was saved, so the window's history list can refresh.
    @ObservationIgnored var onPersisted: (() -> Void)?
    /// Called when a message is about to be sent, before it is added to the transcript.
    @ObservationIgnored var willSend: (() -> Void)?
    @ObservationIgnored private var session: AgentSession?
    @ObservationIgnored private var sessionFingerprint: String?
    // ACP backend (plan steps 5-6): an external agent presenting the same AgentEvent stream.
    @ObservationIgnored private var acpSession: ACPClientSession?
    @ObservationIgnored private var acpTransport: IDEACPTransport?
    @ObservationIgnored private var acpFingerprint: String?
    @ObservationIgnored private var lastACPSessionID: String?
    @ObservationIgnored private var pendingElicitations: [String: CheckedContinuation<String?, Never>] = [:]
    /// Agent-advertised modes for the ACP header chip; empty for the built-in agent.
    private(set) var acpAvailableModes: [ACPSessionMode] = []
    private(set) var acpCurrentModeID: String?
    /// Agent-advertised config options, shown read-only in the panel header.
    private(set) var acpConfigOptions: [ACPConfigOption] = []
    private(set) var acpAgentName: String?

    /// Whether this chat is driven by an external ACP agent (its own choice, else the one selected in Settings ▸ Agent).
    var isACPConversation: Bool { acpDefinition != nil }
    /// Rewind/compact/checkpoints owned by AgentKit are not available for ACP conversations.
    var supportsAgentKitOnlyFeatures: Bool { !isACPConversation }
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Where the current model turn's entries begin, so a retried turn can drop them.
    @ObservationIgnored private var turnStart = 0
    /// The next run is a Retry of a send the provider never answered: drop that error once it starts.
    @ObservationIgnored private var dismissRetryError = false
    @ObservationIgnored private var currentRun: RunID?
    @ObservationIgnored private var pendingOutput: [String: String] = [:]
    @ObservationIgnored private let clientFactory: @MainActor (IDEAgentSettings) throws -> any LLMClient
    @ObservationIgnored private let store: SessionStore?
    /// This chat's checkpoints. One for the life of the chat, so a new session (a settings change) keeps
    /// Revert for the runs before it; its originals also go to disk, so Revert survives a relaunch.
    @ObservationIgnored private var checkpointLog: CheckpointLog?
    /// Runs saved with the chat, put into the log when it is first needed.
    @ObservationIgnored private var restoredRuns: [RunSnapshot] = []
    /// Set while this chat reverts files, so Local History records those writes as reverts.
    @ObservationIgnored private let writeFlag = WriteSourceFlag()
    /// The workspace the session reads and writes through, kept so mentions read files the same way.
    @ObservationIgnored private var agentWorkspace: IDEAgentWorkspace?
    /// The app-wide permission rules file; `nil` in tests, which must not read the user's own.
    @ObservationIgnored private let appPermissionsFile: URL?
    /// Rules that last as long as this chat ("Allow for this chat").
    @ObservationIgnored private var chatRules = PermissionRules()
    /// Where ↑ and ↓ are in the prompt history for this chat's field.
    @ObservationIgnored var promptRecall = IDEAgentPromptRecall()
    /// Rules for the run in progress: the tools a command or skill said it may use.
    @ObservationIgnored private var runRules = PermissionRules()
    /// Items of a conversation loaded from disk, handed to the session that is created for it.
    @ObservationIgnored private var restoredItems: [ConversationItem]?
    @ObservationIgnored private var restoredTodos: [TodoItem] = []
    @ObservationIgnored private var createdAt = Date()

    /// The history as of the last step that left no tool call open, with how many transcript rows and which
    /// checkpoint runs went with it: what a save in the middle of a run writes, so it never holds a half step.
    @ObservationIgnored private var stepItems: [ConversationItem]?
    @ObservationIgnored private var stepEntryCount = 0
    @ObservationIgnored private var stepCheckpoints: [RunSnapshot] = []
    @ObservationIgnored private var stepSaveTask: Task<Void, Never>?
    @ObservationIgnored private var lastStepSave = Date.distantPast
    /// At most one save in the middle of a run per this long; a busy run would otherwise write the whole history every step.
    static let stepSaveInterval: TimeInterval = 2

    /// For tests that look at the live session's state (its checklist).
    var currentSessionForTesting: AgentSession? { session }
    /// For tests: how many history items the last finished step of the run in progress left.
    var finishedStepItemCountForTesting: Int? { stepItems?.count }

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

    /// How full the model's window is, from 0 to 1; `nil` when the window or the use is not known.
    var contextFraction: Double? {
        guard let window = settings.contextWindow(for: effectiveChoice), window > 0, let contextTokens else { return nil }
        return min(1, Double(contextTokens) / Double(window))
    }

    var canSend: Bool {
        !isRunning && !isCompacting && hasConsent && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether what this chat sends may leave the Mac: the endpoint was accepted, or it runs on this Mac,
    /// or an external agent the user allowed does the work.
    var hasConsent: Bool { settings.hasAcceptedDisclosure(for: effectiveChoice.provider) || isACPConversation }

    // MARK: - Sending

    func send() {
        guard canSend else { return }
        submit(text: draft.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Sends a message. The transcript shows `text`; the model gets `modelText` when it differs (a
    /// command's expansion, a skill's instructions), which the row offers as `detail`. `allowedTools` are
    /// permission rules for this run only. The draft is cleared once the message is on its way.
    func submit(text: String, modelText: String? = nil, allowedTools: [String] = []) {
        guard !isRunning, !isCompacting, hasConsent, !text.isEmpty, let host else { return }
        guard let root = host.agentProjectRoot else {
            append(.init(kind: .error, text: "Open a project folder first; the agent works inside one."))
            return
        }

        willSend?()
        commandCatalog?.invalidate()
        promptRecall.reset()
        draft = ""
        var entry = IDEAgentEntry(kind: .user, text: text)
        // What the model reads: the output of commands the user ran since the last message, then the message.
        let fullText = IDEAgentShellContext.prefix(for: shellContext) + (modelText ?? text)
        shellContext = []
        if fullText != text { entry.detail = fullText }
        append(entry)
        runRules = PermissionRules(allow: allowedTools.compactMap(PermissionRule.init(parsing:)))
        // The model sees the editor's state with the message; the transcript shows only the message.
        let context = host.agentEditorContext()
        let body = fullText
        let entryID = entry.id
        if isACPConversation {
            openACPRun(root: root, host: host) { acp in
                let resolution = await IDEAgentMentionResolver.resolve(body, sources: self.mentionSources(root: root))
                if let index = self.entries.firstIndex(where: { $0.id == entryID }) {
                    self.entries[index].attachments = resolution.attachments.map(\.summary)
                }
                if self.stopRequested { return nil }
                if let index = self.entries.lastIndex(where: \.canRetry) { self.entries[index].canRetry = false }
                return await acp.send(context + "\n\n" + body + resolution.modelBlock)
            }
            return
        }
        openRun(root: root, host: host) { session in
            let framed = await self.frame(context: context, body: body, entryID: entryID, root: root, session: session)
            if self.stopRequested { return nil }
            // The new message is on its way, so the previous failure's Retry no longer applies, nor Resume.
            if let index = self.entries.lastIndex(where: \.canRetry) { self.entries[index].canRetry = false }
            self.clearResume()
            return await session.send(framed)
        }
    }

    /// Tries the send that failed because the provider could not be reached. The message is already in
    /// the transcript and in the history, so this does not add another copy of it.
    func retry() {
        guard !isRunning, !isCompacting, hasConsent, let host, let root = host.agentProjectRoot else { return }
        guard entries.contains(where: \.canRetry) else { return }
        willSend?()
        commandCatalog?.invalidate()
        promptRecall.reset()
        dismissRetryError = true
        if isACPConversation {
            // The message is already in the transcript; resend its text to the external agent.
            let text = entries.last(where: { $0.kind == .user })?.text ?? ""
            openACPRun(root: root, host: host) { acp in await acp.send(text) }
            return
        }
        openRun(root: root, host: host) { session in
            await session.retry()
        }
    }

    /// Carries on with a run the app was closed in the middle of. The saved history already holds its
    /// finished steps; the session tells the model what happened. Nothing is added to the transcript.
    func resume() {
        guard !isRunning, !isCompacting, hasConsent, !isACPConversation, let host, let root = host.agentProjectRoot else { return }
        guard entries.contains(where: \.canResume) else { return }
        willSend?()
        commandCatalog?.invalidate()
        promptRecall.reset()
        clearResume()
        openRun(root: root, host: host) { session in
            await session.resume()
        }
    }

    private func clearResume() {
        for index in entries.indices where entries[index].canResume { entries[index].canResume = false }
    }

    /// Makes the session, then runs `makeStream`. `nil` means Stop landed before anything was sent.
    private func openRun(
        root: URL, host: any IDEAgentHost,
        makeStream: @escaping @MainActor (AgentSession) async -> AsyncStream<AgentEvent>?
    ) {
        stopRequested = false
        isRunning = true
        status = "Thinking…"
        runTask = Task { [weak self] in
            guard let self else { return }
            let activeSession: AgentSession
            do {
                activeSession = try await self.currentSession(root: root, host: host)
            } catch {
                self.abandonRun(error: error.localizedDescription)
                return
            }
            // Loading an on-device model reads gigabytes; say so, and fail visibly rather than inside the first turn.
            if self.effectiveChoice.provider == .mlx, let model = self.settings.selectedMLXModel(id: self.effectiveChoice.model) {
                let models = IDELocalModelsStore.shared
                if models.loadedID != model.id {
                    self.status = "Loading \(LocalModelFormat.shortName(model.id))…"
                    await models.load(model)
                }
                if let error = models.loadError, models.loadedID != model.id {
                    self.abandonRun(error: error)
                    return
                }
            }
            // Whatever changed since the session was made (the mode, a rules file) applies to this run.
            await activeSession.setMode(self.mode)
            await activeSession.setRules(self.currentRules(root: root))
            // Stop pressed while the session was being made or a model loaded: end here, before anything is sent.
            if self.stopRequested { return self.endBeforeStarting() }
            guard let stream = await makeStream(activeSession) else { return self.endBeforeStarting() }
            if self.dismissRetryError {
                self.dismissRetryError = false
                if let index = self.entries.lastIndex(where: \.canRetry) { self.entries.remove(at: index) }
            }
            // A Stop that landed between the check above and the run starting.
            if self.stopRequested { await activeSession.stop() }
            await self.consume(stream, session: activeSession)
        }
    }

    // MARK: - ACP backend

    private func openACPRun(
        root: URL, host: any IDEAgentHost,
        makeStream: @escaping @MainActor (ACPClientSession) async -> AsyncStream<AgentEvent>?
    ) {
        stopRequested = false
        isRunning = true
        status = "Thinking…"
        runTask = Task { [weak self] in
            guard let self else { return }
            let active: ACPClientSession
            do {
                active = try await self.currentACPSession(root: root, host: host)
            } catch {
                self.abandonRun(error: error.localizedDescription)
                return
            }
            await active.setMode(self.mode)
            await active.setRules(self.currentRules(root: root))
            if self.stopRequested { return self.endBeforeStarting() }
            guard let stream = await makeStream(active) else { return self.endBeforeStarting() }
            if self.dismissRetryError {
                self.dismissRetryError = false
                if let index = self.entries.lastIndex(where: \.canRetry) { self.entries.remove(at: index) }
            }
            if self.stopRequested { await active.stop() }
            await self.consumeACP(stream, session: active)
        }
    }

    private func currentACPSession(root: URL, host: any IDEAgentHost) async throws -> ACPClientSession {
        guard let definition = acpDefinition else {
            throw ACPError.agentError(JSONRPCError(code: -32000, message: "No ACP agent is selected and allowed in Settings ▸ Agent."))
        }
        let fingerprint = "\(definition.id.uuidString)|\(definition.command)|\(definition.args.joined(separator: " "))|\(root.path)"
        if let acpSession, acpFingerprint == fingerprint, await acpSession.isConnected {
            return acpSession
        }
        // Crash/settings change: respawn. The old process is killed with its transport.
        if let oldTransport = acpTransport { Task { await oldTransport.close() } }
        acpSession = nil
        let box = IDEAgentHostBox(host)
        let writeFlag = self.writeFlag
        let workspace = IDEAgentWorkspace(root: root, box: box, onWrite: { [weak self] path, before, after in
            let isRevert = writeFlag.isReverting
            Task { @MainActor in self?.noteAgentWrite(path: path, before: before, after: after, isRevert: isRevert) }
        })
        agentWorkspace = workspace
        var environment = await host.agentCommandEnvironment()
        for (key, value) in definition.env { environment[key] = value }
        for (key, value) in settings.acpKeychainEnv(for: definition.id) { environment[key] = value }
        let transport = IDEACPTransport(definition: definition, workingDirectory: root, environment: environment)
        var services = IDEACPHostServices.make(workspace: workspace, root: root)
        services.askText = { [weak self] prompt in await self?.askElicitation(prompt) }
        let created = ACPClientSession(
            transport: transport,
            hostServices: services,
            cwd: root.path,
            mode: mode,
            rules: currentRules(root: root),
            checkpoints: await ensureCheckpointLog())
        acpTransport = transport
        acpSession = created
        acpFingerprint = fingerprint
        _ = try await created.connect()
        do {
            if let previous = lastACPSessionID, await created.agentCapabilities?.loadSession == true {
                _ = try await created.loadSession(id: previous)
            } else {
                _ = try await created.newSession()
            }
        } catch {
            // A failed load falls back to a fresh session on the same connection.
            if lastACPSessionID != nil { _ = try await created.newSession() } else { throw error }
        }
        lastACPSessionID = await created.sessionId
        acpAgentName = definition.displayName
        refreshACPHeaderState()
        return created
    }

    private func refreshACPHeaderState() {
        guard let acpSession else { return }
        Task {
            acpAvailableModes = await acpSession.modeState?.availableModes ?? []
            acpCurrentModeID = await acpSession.currentModeId
            acpConfigOptions = await acpSession.configOptions
        }
    }

    /// Switches the external agent's own mode (`session/set_mode`). Umbra's `PermissionMode`
    /// continues to gate local fs/terminal effects independently (plan step 6).
    func setACPMode(_ modeID: String) {
        guard let acpSession else { return }
        Task {
            do {
                try await acpSession.setAgentMode(modeID)
                acpCurrentModeID = modeID
            } catch {
                appendError(error.localizedDescription)
            }
        }
    }

    private func consumeACP(_ stream: AsyncStream<AgentEvent>, session: ACPClientSession) async {
        for await event in stream {
            handle(event)
            if case .runStarted = event { refreshACPHeaderState() }
        }
        flush()
        if let currentRun, let checkpoints = session.checkpoints {
            let changes = await checkpoints.changes(in: currentRun)
            if !changes.isEmpty {
                var entry = IDEAgentEntry(kind: .changes, text: "")
                entry.run = currentRun
                entry.fileChanges = changes.map { IDEAgentFileChange(path: $0.path, original: $0.original) }
                append(entry)
            }
        }
        currentRun = nil
        isRunning = false
        isAwaitingUser = false
        status = nil
        runRules = PermissionRules()
        fileClaims?.release(tab: id)
        // Transcript persistence via the host blob; items are synthesized from the transcript.
        let items: [ConversationItem] = entries.compactMap { entry in
            switch entry.kind {
            case .user: .user(entry.text)
            case .assistant: .assistant(entry.text)
            default: nil
            }
        }
        persist(items: items, checkpoints: await session.checkpoints?.snapshot() ?? [])
        onRunFinished?()
        if let ending = lastEnding {
            let lastAnswer = entries.last(where: { $0.kind == .assistant })?.text ?? ""
            onAttention?(.finished(ending, summary: Self.firstLine(of: lastAnswer, limit: 140)))
        }
        refreshACPHeaderState()
        drainQueue()
    }

    /// Restarts a crashed ACP agent process; the next send respawns it.
    func restartACP() {
        let transport = acpTransport
        let session = acpSession
        acpSession = nil
        acpTransport = nil
        acpFingerprint = nil
        Task {
            await session?.close()
            await transport?.close()
        }
        appendNotice("The ACP agent will restart on the next message.")
    }

    /// The run never started. A Retry that was waiting stays, so the button is still there.
    private func abandonRun(error: String) {
        dismissRetryError = false
        append(.init(kind: .error, text: error))
        isRunning = false
        status = nil
    }

    /// Stop was pressed before the run began: say so and put anything queued back in the field.
    private func endBeforeStarting() {
        dismissRetryError = false
        append(.init(kind: .notice, text: "Stopped."))
        isRunning = false
        status = nil
        lastEnding = .stopped
        drainQueue()
    }

    /// What the model is sent: the editor's state, the message, and what its `@` mentions attach. Files
    /// attached whole are recorded as read, so an edit to one needs no `read_file` first.
    private func frame(context: String, body: String, entryID: UUID, root: URL, session: AgentSession) async -> String {
        let resolution = await IDEAgentMentionResolver.resolve(body, sources: mentionSources(root: root))
        if let index = entries.firstIndex(where: { $0.id == entryID }) {
            entries[index].attachments = resolution.attachments.map(\.summary)
            // Where this message will sit in the history: what rewinding cuts before.
            entries[index].itemIndex = await session.items.count
        }
        for (mention, reason) in resolution.unresolved {
            // A bare word with no slash or dot is probably a name (@alex), not a path that failed.
            if reason == "no such file", !mention.contains("/"), !mention.contains(".") { continue }
            appendNotice("Could not attach \(mention): \(reason.trimmingCharacters(in: CharacterSet(charactersIn: "."))).")
        }
        for attachment in resolution.attachments {
            if let read = attachment.readFile { await session.recordRead(path: read.path, text: read.text) }
        }
        return context + "\n\n" + body + resolution.modelBlock
    }

    /// A file was written by this chat's run: tell Local History which chat and message did it.
    private func noteAgentWrite(path: String, before: String?, after: String?, isRevert: Bool) {
        if isRevert {
            host?.agentRecordWrite(path: path, before: before, after: after, source: .revert, group: nil)
        } else {
            let prompt = entries.last(where: { $0.kind == .user })?.text ?? ""
            host?.agentRecordWrite(
                path: path, before: before, after: after, source: .agent(tab: title, prompt: String(prompt.prefix(200))), group: currentRun)
        }
    }

    private func mentionSources(root: URL) -> IDEAgentMentionSources {
        var sources = IDEAgentMentionSources(projectRoot: root)
        let secrets = SecretFilePolicy.patterns(from: settings.secretFilePatterns)
        sources.secretPatterns = secrets
        if let workspace = agentWorkspace {
            sources.readText = { try await workspace.readText(path: $0) }
            sources.listDirectory = { path in
                let folder = path.hasSuffix("/") ? String(path.dropLast()) : path
                return (try? await workspace.listDirectory(path: folder))?.map { $0.isDirectory ? $0.name + "/" : $0.name }
            }
        }
        sources.selection = { [weak host] in host?.agentSelection() }
        sources.problems = { [weak host] in host?.agentProblems() ?? [] }
        sources.openFiles = { [weak host] in host?.agentOpenFilePaths() ?? [] }
        sources.terminalTail = { [weak host] in host?.agentTerminalTail(lines: $0) }
        sources.skill = { [weak self] name in self?.commandCatalog?.skillCatalog.skill(named: name) }
        if let workspace = agentWorkspace, let host {
            let box = IDEAgentHostBox(host)
            let git = IDEAgentGitSource(
                projectRoot: root, secretPatterns: secrets,
                unsavedBuffers: { await box.read(default: [:]) { $0.agentUnsavedBuffers() } })
            sources.gitDiff = {
                guard await GitRepository.discover(from: root, runner: git.runner) != nil else { return nil }
                let context = ToolContext(workspace: workspace, ledger: ReadLedger(), callID: "mention")
                let output = await IDEGitDiffTool(source: git).execute(argumentsJSON: "{}", context: context)
                return output.isError ? nil : output.text
            }
        }
        return sources
    }

    // MARK: - Commands you run yourself

    /// `!command` in the message field: runs it in the project like a terminal would, without asking (you
    /// wrote it), shows the output as a command card, and gives the agent the output with your next message.
    /// Not while a run is going.
    func runShell(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !isCompacting, !trimmed.isEmpty, let host, let root = host.agentProjectRoot else { return }
        draft = ""
        promptRecall.reset()
        append(IDEAgentEntry(kind: .user, text: "!" + trimmed))
        let callID = "shell-" + UUID().uuidString
        let arguments = (try? JSONValue.object(["command": .string(trimmed)]).serialized()) ?? "{}"
        append(IDEAgentEntry(kind: .toolCall(name: "run_command"), text: arguments, callID: callID))
        isRunning = true
        status = "Running…"
        shellTask = Task { [weak self] in
            let timeout = IDEAgentShellContext.timeout
            var output: ToolOutput
            var formatted: String
            do {
                let environment = await host.agentCommandEnvironment()
                let result = try await AgentCommandRunner.run(
                    AgentCommandSpec(command: trimmed, workingDirectory: root, environment: environment, timeout: timeout),
                    onOutput: { chunk in Task { @MainActor in self?.handle(.toolCallOutput(id: callID, chunk: chunk)) } })
                formatted = IDERunCommandTool.format(command: trimmed, result: result, timeout: timeout)
                output = ToolOutput(formatted, isError: result.exitCode != 0)
            } catch {
                formatted = "$ \(trimmed)\n\(error.localizedDescription)"
                output = .error(error.localizedDescription)
            }
            guard let self else { return }
            self.handle(.toolCallFinished(id: callID, name: "run_command", output: output))
            self.shellContext.append(formatted)
            self.shellContext = IDEAgentShellContext.bounded(self.shellContext)
            self.isRunning = false
            self.status = nil
            self.shellTask = nil
        }
    }

    // MARK: - Queued messages

    /// Writes a message while a run is going. It joins the conversation at the model's next turn.
    func enqueue(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRunning, !trimmed.isEmpty else { return }
        queue.append(QueuedMessage(text: trimmed))
        draft = ""
        promptRecall.reset()
    }

    /// Takes a message back out of the queue.
    func removeQueued(_ id: UUID) {
        queue.removeAll { $0.id == id }
    }

    /// Called by the session at a turn boundary: moves the queue into the transcript, resolving each
    /// message's `@` mentions, and returns what the model is to be sent.
    private func deliverQueued(itemCount: Int) async -> [String] {
        guard !queue.isEmpty, let root = host?.agentProjectRoot else { return [] }
        let batch = queue
        queue = []
        flush()
        var texts: [String] = []
        for (offset, message) in batch.enumerated() {
            let resolution = await IDEAgentMentionResolver.resolve(message.text, sources: mentionSources(root: root))
            var entry = IDEAgentEntry(kind: .user, text: message.text)
            entry.itemIndex = itemCount + offset
            entry.attachments = resolution.attachments.map(\.summary)
            append(entry)
            for (mention, reason) in resolution.unresolved {
                if reason == "no such file", !mention.contains("/"), !mention.contains(".") { continue }
                appendNotice("Could not attach \(mention): \(reason.trimmingCharacters(in: CharacterSet(charactersIn: "."))).")
            }
            for attachment in resolution.attachments {
                if let read = attachment.readFile { await session?.recordRead(path: read.path, text: read.text) }
            }
            texts.append(message.text + resolution.modelBlock)
        }
        return texts
    }

    // MARK: - Permissions

    /// The files' rules and this chat's own, merged.
    private func currentRules(root: URL?) -> PermissionRules {
        var rules = IDEAgentPermissionFiles.load(projectRoot: root, appFile: appPermissionsFile).merged(with: chatRules).merged(with: runRules)
        if settings.memoryEnabled, !settings.saveMemoriesWithoutAsking {
            // Saving a memory asks first. (An untrusted run asks even without this rule.)
            rules.add(PermissionRule(tool: "remember"), to: .ask)
        }
        return rules
    }

    /// Changes the mode for the calls that follow, mid-run if need be.
    func setMode(_ newMode: PermissionMode) {
        guard newMode != mode else { return }
        mode = newMode
        if let session { Task { await session.setMode(newMode) } }
        if let acpSession { Task { await acpSession.setMode(newMode) } }
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
            var notice = "Saved \(rule) to \(IDEAgentPermissionFiles.projectLocalPath)."
            if !existed {
                let added = host?.agentOfferGitignore(IDEAgentPermissionFiles.projectLocalPath) == true
                notice += added
                    ? " Added it to .gitignore."
                    : " It is your own file: add it to .gitignore if the project is shared."
            }
            appendNotice(notice)
            pushRules()
        } catch {
            appendError("Could not save the rule: \(error.localizedDescription)")
            chatRules.add(rule, to: .allow)
            pushRules()
        }
    }

    private func pushRules() {
        guard let root = host?.agentProjectRoot else { return }
        let rules = currentRules(root: root)
        if let session { Task { await session.setRules(rules) } }
        if let acpSession { Task { await acpSession.setRules(rules) } }
    }

    /// Cancels the stream and running tools. The run ends with a "Stopped." notice and the next
    /// message continues the conversation.
    func stop() {
        shellTask?.cancel()
        // A run still being set up (the session, a local model loading) has no session to stop yet: the run
        // looks at this before it starts. (Not Task cancellation: that would also end the loop that reads
        // the run's events, and the run's ending would never reach the transcript.)
        stopRequested = true
        cancelElicitations()
        guard isRunning else { return }
        if let session { Task { await session.stop() } }
        if let acpSession {
            let transport = acpTransport
            Task {
                await acpSession.stop()
                // Grace period, then the process group is killed (plan step 5).
                try? await Task.sleep(for: .seconds(2))
                transport?.terminate()
            }
        }
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
        queue = []
        checkpointLog = nil
        restoredRuns = []
        conversationID = UUID()
        createdAt = Date()
        pendingLoadID = nil
        summaryTitle = nil
        customTitle = nil
        isAwaitingUser = false
        contextTokens = nil
        // A new conversation is a new external session too.
        lastACPSessionID = nil
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

    /// The first non-empty line, cut to `limit` characters.
    static func firstLine(of text: String, limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
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

    /// The history without the items only the model that wrote them may be sent back, with the positions
    /// recorded on the user messages moved to match.
    private func droppingOpaque(_ items: [ConversationItem]) -> [ConversationItem] {
        var removedBefore = 0
        var moved: [Int: Int] = [:]
        var kept: [ConversationItem] = []
        for (index, item) in items.enumerated() {
            if case .opaque = item {
                removedBefore += 1
            } else {
                moved[index] = index - removedBefore
                kept.append(item)
            }
        }
        for index in entries.indices {
            if let old = entries[index].itemIndex { entries[index].itemIndex = moved[old] }
        }
        return kept
    }

    // MARK: - Saving and loading

    /// Replaces the conversation with a saved one.
    func load(_ snapshot: SessionSnapshot) {
        guard !isRunning else { return }
        endSession()
        let saved = IDEAgentSavedTranscript.decode(snapshot.host)
        let blobs = checkpointBlobs()
        entries = saved.entries.compactMap { $0.restoredEntry(blobs: blobs) }
        restoredRuns = saved.checkpoints
        checkpointLog = nil
        cost = saved.cost
        todos = saved.todos
        restoredTodos = saved.todos
        usage = snapshot.totalUsage
        // Provider items only the model that produced them may be sent back; the transcript is enough.
        restoredItems = droppingOpaque(snapshot.items)
        chatRules = PermissionRules()
        conversationID = snapshot.id
        createdAt = snapshot.createdAt
        pendingLoadID = nil
        contextTokens = nil
        summaryTitle = snapshot.title
        customTitle = saved.customTitle
        modelChoice = saved.modelChoice
        lastACPSessionID = nil
        status = nil
        if saved.runInProgress { restoreInterruptedRun(queued: saved.queued) }
    }

    /// The saved file says a run was going and never ended. Its finished steps are in the history; say so,
    /// offer to carry on (never automatically: edits apply without asking, so the user decides), give back
    /// the messages that were waiting, and write the file again without the mark, so this appears once.
    private func restoreInterruptedRun(queued: [String]) {
        var notice = IDEAgentEntry(
            kind: .error,
            text: "The last run was interrupted when Umbra closed. The steps above were saved; Resume carries on from them.")
        notice.canResume = true
        entries.append(notice)
        if !queued.isEmpty {
            let text = queued.joined(separator: "\n\n")
            draft = draft.isEmpty ? text : draft + "\n\n" + text
        }
        persist(items: restoredItems ?? [], checkpoints: restoredRuns)
    }

    /// The originals of the files agents changed, on disk beside this project's conversations.
    private func checkpointBlobs() -> IDEAgentCheckpointBlobs? {
        guard let store, let root = host?.agentProjectRoot else { return nil }
        return IDEAgentCheckpointBlobs(store: store, projectRoot: root.path)
    }

    private func ensureCheckpointLog() async -> CheckpointLog {
        if let checkpointLog { return checkpointLog }
        let log = CheckpointLog(blobs: checkpointBlobs())
        await log.restore(restoredRuns)
        checkpointLog = log
        return log
    }

    /// `interrupted` marks a save made while a run is going: if it is the last write, the run was cut off.
    /// Then `entries` is the transcript as of the last finished step, and the queue is kept with it.
    private func persist(
        items: [ConversationItem], checkpoints: [RunSnapshot], entries savedEntries: ArraySlice<IDEAgentEntry>? = nil,
        interrupted: Bool = false
    ) {
        guard let store, let root = host?.agentProjectRoot, !items.isEmpty else { return }
        let snapshot = SessionSnapshot(
            id: conversationID, projectRoot: root.path, title: customTitle ?? SessionStore.title(from: items),
            createdAt: createdAt, updatedAt: Date(), items: items, totalUsage: usage,
            host: IDEAgentSavedTranscript.encode(
                entries: savedEntries.map(Array.init) ?? entries, cost: cost, todos: todos, customTitle: customTitle,
                checkpoints: checkpoints, modelChoice: modelChoice,
                runInProgress: interrupted, queued: queue.map(\.text)))
        // A write failure only costs the history; it is not worth interrupting the user for.
        try? store.save(snapshot)
        // The originals are kept for the newest runs of the project; this chat's own are never the ones to go.
        // (Not on a save in the middle of a run: it comes every few seconds and the end of the run prunes.)
        if !interrupted { checkpointBlobs()?.prune(keeping: Set(checkpoints.map(\.id))) }
        onPersisted?()
    }

    /// Names the tab. A saved conversation is saved again so the name outlives the window.
    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        customTitle = trimmed.isEmpty ? nil : String(trimmed.prefix(80))
        Task {
            if let session {
                persist(items: await session.items, checkpoints: await session.checkpoints.snapshot())
            } else if let restoredItems {
                persist(items: restoredItems, checkpoints: restoredRuns)
            }
        }
    }

    /// Cancels the run and drops the session. A session that outlives its window would keep the
    /// workspace alive through its tools.
    func teardown() {
        saveInterrupted()
        endSession()
        host = nil
    }

    private func endSession() {
        let old = session
        let oldACP = acpSession
        let oldTransport = acpTransport
        runTask?.cancel()
        runTask = nil
        flushTask?.cancel()
        flushTask = nil
        pendingText = ""
        pendingOutput = [:]
        session = nil
        sessionFingerprint = nil
        acpSession = nil
        acpTransport = nil
        acpFingerprint = nil
        acpAvailableModes = []
        acpCurrentModeID = nil
        acpConfigOptions = []
        acpAgentName = nil
        cancelElicitations()
        isRunning = false
        isAwaitingUser = false
        runRules = PermissionRules()
        fileClaims?.release(tab: id)
        Task {
            await old?.stop()
            await oldACP?.close()
            await oldTransport?.close()
        }
    }

    // MARK: - Session

    private func currentSession(root: URL, host: any IDEAgentHost) async throws -> AgentSession {
        // Skills are in the tool list, so a changed one starts a new session (which keeps the conversation).
        let skills = commandCatalog.map(\.skillCatalog).flatMap { $0.skills.isEmpty ? nil : $0 }
        // Likewise the subagents `task` offers: the list is in the tool's description.
        let agents = commandCatalog?.agentCatalog ?? .builtIn
        // Memory loads once, at session start: a write never changes the live request, and shows
        // from the next session on (whose fingerprint then differs).
        let memoryDirectory = (settings.memoryEnabled ? store : nil)?.projectDirectory(for: root.path)
        let memoryText = memoryDirectory.flatMap { ProjectMemory.load(at: $0) }
        let choice = effectiveChoice
        let fingerprint = settings.fingerprint(for: choice) + "|" + root.path + "|" + String(host.agentIsGradleProject) + "|" + (skills?.fingerprint ?? "")
            + "|" + agents.fingerprint + "|" + ProjectMemory.fingerprint(of: memoryText)
        if let session, sessionFingerprint == fingerprint { return session }

        let client = modelChoice == nil ? try clientFactory(settings) : try choiceClientFactory(settings, choice)
        // A settings change keeps the conversation, minus provider items that only the old model
        // or endpoint may be sent back.
        var history: [ConversationItem] = []
        if let previous = session {
            history = droppingOpaque(await previous.items)
        } else if let restored = restoredItems {
            history = restored
        }
        restoredItems = nil
        let box = IDEAgentHostBox(host)
        let writeFlag = self.writeFlag
        let workspace = IDEAgentWorkspace(root: root, box: box, onWrite: { [weak self] path, before, after in
            // Read now, while the write is happening: a revert is over by the time the main actor gets to it.
            let isRevert = writeFlag.isReverting
            Task { @MainActor in self?.noteAgentWrite(path: path, before: before, after: after, isRevert: isRevert) }
        })
        agentWorkspace = workspace
        let support = IDEAgentCommandSupport(root: root, box: box)
        var tools: [any AgentTool] = ReadOnlyTools.all(secretPatterns: settings.secretFilePatterns)
            + [IDEShowFileTool(root: root, box: box)]
        if let search = IDEAgentWebSearch.tool(settings: settings) { tools.append(search) }
        if settings.webFetchEnabled { tools.append(WebFetchTool()) }
        // The sandbox choice is per session: resolved here, so a mid-run toggle flip never
        // touches the live run (and the fingerprint above starts a new session for it).
        let sandbox: IDEAgentSandboxChoice? = if settings.sandboxCommands, IDEAgentSandbox.isAvailable {
            IDEAgentSandboxChoice(profile: IDEAgentSandboxProfile.make(
                projectRoot: root.path, secretGlobs: settings.secretFilePatterns,
                blockNetwork: settings.sandboxBlockNetwork))
        } else {
            nil
        }
        tools += EditingTools.all()
            + [IDERunCommandTool(support: support, sandbox: sandbox)]
        if host.agentIsGradleProject { tools += [IDEGradleTool(support: support), IDERunTestsTool(support: support)] }
        if !host.agentProjectTaskNames().isEmpty {
            tools.append(IDEProjectTaskTool(host: box))
        }
        tools += [TodoTool(), AskUserTool(), ExitPlanModeTool(), ExploreTool(), TaskTool(catalog: agents)]
        if let memoryDirectory { tools.append(RememberTool(memoryDirectory: memoryDirectory)) }
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
        let profile = ModelProfile.choose(provider: choice.provider.rawValue, model: choice.model)
        // The blocking gate and the soft nudge are alternatives: the toggle picks the gate.
        let stopGateOn = settings.runTestsBeforeFinishing && host.agentIsGradleProject
        let stopGatePolicies: [any TurnPolicy] = stopGateOn
            ? [StopGatePolicy(check: { [support] _ in try await Self.runTestsForStopGate(support: support) })]
            : []
        // Output too large to show is kept beside the conversation; the sweep drops what is old.
        let toolOutputs = store.map {
            IDEAgentToolOutputs(store: $0, projectRoot: root.path, conversationID: conversationID)
        }
        if let toolOutputs {
            let directory = toolOutputs.directory
            Task.detached(priority: .utility) { IDEAgentToolOutputs.sweep(directory: directory) }
        }
        let projectNotes = IDEAgentProjectNotes.load(root: root)
        let configuration = AgentConfiguration(
            model: choice.model,
            systemPrompt: SystemPrompt.make(
                projectRoot: workspace.rootPath, notes: projectNotes, mode: mode,
                userNotes: IDEAgentProjectNotes.loadUser(settings: settings), variant: profile.promptVariant,
                memory: memoryText),
            reasoningEffort: choice.effectiveReasoningEffort,
            maxIterations: settings.iterationCap,
            cacheKey: Self.cacheKey(root: root, conversationID: conversationID),
            contextWindow: settings.contextWindow(for: choice),
            compactionThreshold: choice.provider == .ollama ? 0.60 : 0.75,
            mode: mode,
            permissions: currentRules(root: root),
            gate: fileClaims.map { claims in
                IDEAgentClaimsGate(claims: claims, tab: id, title: { [weak self] in self?.title ?? "another chat" })
            },
            secretPatterns: SecretFilePolicy.patterns(from: settings.secretFilePatterns),
            pendingMessages: { [weak self] itemCount in await self?.deliverQueued(itemCount: itemCount) ?? [] },
            verifyBeforeStopping: !stopGateOn,
            maxRunTokens: settings.maxRunTokens > 0 ? settings.maxRunTokens : nil,
            maxRunSeconds: settings.maxRunSeconds > 0 ? TimeInterval(settings.maxRunSeconds) : nil,
            runIsOverCost: settings.runIsOverCost(for: choice),
            editTolerance: profile.editTolerance,
            policies: stopGatePolicies,
            shapeToolOutput: { IDEAgentOutputScrubber.shape($0) },
            currentInstructions: { IDEAgentProjectNotes.current(root: root) },
            instructionsBaseline: projectNotes,
            toolOutputStore: toolOutputs,
            snapshotter: IDEAgentGitSnapshotter(projectRoot: root))
        let created = AgentSession(
            client: client, tools: tools, workspace: workspace, configuration: configuration, history: history,
            checkpoints: await ensureCheckpointLog())
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

    /// The Stop-gate check behind "Run tests before finishing": Gradle `test` through the same
    /// runner the `run_tests` tool uses, summarized the same way. The toggle is the consent to run
    /// them, so no approval card is raised. Anything the gate cannot judge (Gradle not started, the
    /// run refused) skips instead of blocking.
    static func runTestsForStopGate(support: IDEAgentCommandSupport) async throws -> StopGateVerdict {
        await support.box.revealGradle()
        let started = Date()
        let outcome = await support.box.runGradle(tasks: ["test"], options: [], timeout: IDEGradleTool.defaultTimeout)
        switch outcome {
        case .notStarted, .failed:
            return .skip
        case .cancelled:
            // Stop ends the wait; the gate fails open so the run stops instead of continuing.
            throw CancellationError()
        case .timedOut(let partial):
            return .block(reason: gateSummary(
                commandLine: "gradle test", root: support.root, started: started,
                exitCode: nil, stdout: partial.stdout, stderr: partial.stderr, timedOut: true))
        case .finished(let result):
            if result.exitCode == 0 { return .pass }
            return .block(reason: gateSummary(
                commandLine: "gradle test", root: support.root, started: started,
                exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr, timedOut: false))
        }
    }

    private static func gateSummary(
        commandLine: String, root: URL, started: Date, exitCode: Int32?,
        stdout: String, stderr: String, timedOut: Bool
    ) -> String {
        var input = IDEGradleSummary.Input(
            commandLine: commandLine, projectRoot: root, exitCode: exitCode, stdout: stdout, stderr: stderr,
            duration: Date().timeIntervalSince(started))
        input.timedOut = timedOut
        let directories = IDEGradleSummary.freshTestReportDirectories(under: root, since: started)
        if !directories.isEmpty {
            input.tests = JUnitXMLReportParser.parseReports(in: directories, projectRoot: root)
        } else if stdout.contains("tests completed") || stderr.contains("tests completed") {
            input.tests = JUnitXMLReportParser.parseGradleSummary(stdout + "\n" + stderr)
        }
        return IDEGradleSummary.make(input)
    }

    // MARK: - Saving during a run

    /// Writes down, before the first step, that a run is going. If the app closes or dies now, the
    /// conversation reopens as interrupted (with the message in it) instead of as if it had never been
    /// sent. The end of the run writes the same file again without the mark.
    private func claimRun(session: AgentSession) async {
        stepItems = await session.items
        stepEntryCount = entries.count
        stepCheckpoints = await session.checkpoints.snapshot()
        lastStepSave = Date()
        if let items = stepItems {
            persist(items: items, checkpoints: stepCheckpoints, entries: entries.prefix(stepEntryCount), interrupted: true)
        }
    }

    /// A step finished with no tool call left open: remember it, and save it soon.
    private func noteStep(_ items: [ConversationItem]) {
        flush()
        stepItems = items
        stepEntryCount = entries.count
        guard stepSaveTask == nil else { return }
        let wait = max(0, Self.stepSaveInterval - Date().timeIntervalSince(lastStepSave))
        stepSaveTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self else { return }
            self.stepSaveTask = nil
            await self.saveStep()
        }
    }

    private func saveStep() async {
        guard isRunning, let session else { return }
        let checkpoints = await session.checkpoints.snapshot()
        // The run may have ended while the checkpoints were read: its own save is the later one.
        guard isRunning, let items = stepItems else { return }
        stepCheckpoints = checkpoints
        lastStepSave = Date()
        persist(items: items, checkpoints: checkpoints, entries: entries.prefix(stepEntryCount), interrupted: true)
    }

    /// The window is closing, or the app quitting, in the middle of a run: write the last finished step down
    /// as interrupted before the run is cancelled and the host goes, so the conversation reopens with its
    /// work and a Resume button rather than without the run's latest steps.
    private func saveInterrupted() {
        guard isRunning, !isACPConversation, let items = stepItems else { return }
        stepSaveTask?.cancel()
        stepSaveTask = nil
        persist(items: items, checkpoints: stepCheckpoints, entries: entries.prefix(stepEntryCount), interrupted: true)
    }

    // MARK: - Events

    private func consume(_ stream: AsyncStream<AgentEvent>, session: AgentSession) async {
        await claimRun(session: session)
        for await event in stream { handle(event) }
        flush()
        stepSaveTask?.cancel()
        stepSaveTask = nil
        stepItems = nil
        await appendChangeSummary(for: currentRun, session: session)
        currentRun = nil
        isRunning = false
        isAwaitingUser = false
        status = nil
        runRules = PermissionRules()
        fileClaims?.release(tab: id)
        persist(items: await session.items, checkpoints: await session.checkpoints.snapshot())
        onRunFinished?()
        if let ending = lastEnding {
            let lastAnswer = entries.last(where: { $0.kind == .assistant })?.text ?? ""
            onAttention?(.finished(ending, summary: Self.firstLine(of: lastAnswer, limit: 140)))
        }
        drainQueue()
    }

    /// What was queued and the run did not take: sent as the next message if the run finished, else back in the field.
    private func drainQueue() {
        let texts = queue.map(\.text)
        queue = []
        switch Self.drainAction(queued: texts, ending: lastEnding) {
        case .none: break
        case .send(let text): submit(text: text)
        case .restore(let text): draft = draft.isEmpty ? text : draft + "\n\n" + text
        }
    }

    enum DrainAction: Equatable {
        case none
        /// The run finished normally: send them as the next message.
        case send(String)
        /// The run did not finish normally (stopped, failed): put them back in the field so nothing is lost
        /// and nothing is sent that the user may no longer want.
        case restore(String)
    }

    static func drainAction(queued: [String], ending: RunEnding?) -> DrainAction {
        guard !queued.isEmpty else { return .none }
        let text = queued.joined(separator: "\n\n")
        return ending == .completed ? .send(text) : .restore(text)
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
        guard session != nil || acpSession != nil else { return }
        if let index = toolIndex(callID) {
            entries[index].approval = nil
            entries[index].approvalOutcome = switch decision {
            case .approve: "Approved"
            case .approveEditing: "Edited and approved"
            case .deny: "Denied"
            }
        }
        isAwaitingUser = entries.contains { $0.approval != nil || $0.question != nil || $0.plan != nil || $0.elicitation != nil }
        if let session { Task { await session.resolveApproval(callID: callID, decision: decision) } }
        if let acpSession { Task { await acpSession.resolveApproval(callID: callID, decision: decision) } }
    }

    /// Answers an `ask_user` card; `nil` skips it, and the model is told to use its judgment.
    func answer(callID: String, text: String?) {
        guard session != nil || acpSession != nil else { return }
        if let index = toolIndex(callID) {
            entries[index].question = nil
            entries[index].questionOutcome = text == nil ? "Skipped" : "Answered"
        }
        isAwaitingUser = entries.contains { $0.approval != nil || $0.question != nil || $0.plan != nil || $0.elicitation != nil }
        if let session { Task { await session.answerQuestion(callID: callID, answer: text) } }
        if let acpSession { Task { await acpSession.answerQuestion(callID: callID, answer: text) } }
    }

    /// Answers an external agent's `elicitation/create` card; `nil` declines it.
    func answerElicitation(callID: String, text: String?) {
        if let index = toolIndex(callID) {
            entries[index].elicitation = nil
            entries[index].elicitationOutcome = text == nil ? "Declined" : "Answered"
        }
        isAwaitingUser = entries.contains { $0.approval != nil || $0.question != nil || $0.plan != nil || $0.elicitation != nil }
        if let continuation = pendingElicitations.removeValue(forKey: callID) {
            continuation.resume(returning: text)
        }
    }

    /// Serves `ACPClientSession`'s `askText`: shows the elicitation as a card and waits.
    /// Plan mode declines without a card, mirroring permission auto-reject.
    private func askElicitation(_ prompt: ACPElicitationPrompt) async -> String? {
        guard mode != .plan else { return nil }
        let callID = prompt.toolCallId ?? UUID().uuidString
        if let index = toolIndex(callID) {
            entries[index].elicitation = prompt
        } else {
            append(.init(kind: .toolCall(name: prompt.title), text: "", callID: callID, elicitation: prompt))
        }
        isAwaitingUser = true
        onAttention?(.needsYou(prompt.message.isEmpty ? prompt.title : prompt.message))
        return await withCheckedContinuation { continuation in
            pendingElicitations[callID] = continuation
            if stopRequested { answerElicitation(callID: callID, text: nil) }
        }
    }

    private func cancelElicitations() {
        let pending = pendingElicitations
        pendingElicitations = [:]
        for (callID, continuation) in pending {
            if let index = toolIndex(callID) { entries[index].elicitation = nil }
            continuation.resume(returning: nil)
        }
        isAwaitingUser = entries.contains { $0.approval != nil || $0.question != nil || $0.plan != nil || $0.elicitation != nil }
    }

    // MARK: - Reverting

    /// Answers a plan card. Approving also switches this chat to that mode.
    func approvePlan(callID: String, mode: PermissionMode) {
        guard let session else { return }
        if let index = toolIndex(callID) {
            entries[index].plan = nil
            entries[index].planOutcome = "Approved · \(mode.displayName)"
        }
        if mode != .plan { self.mode = mode }
        isAwaitingUser = entries.contains { $0.approval != nil || $0.question != nil || $0.plan != nil || $0.elicitation != nil }
        Task { await session.resolvePlan(callID: callID, decision: .approve(mode)) }
    }

    /// "Keep planning": the model revises with the user's words.
    func revisePlan(callID: String, feedback: String) {
        guard let session else { return }
        if let index = toolIndex(callID) {
            entries[index].plan = nil
            entries[index].planOutcome = "Changes requested"
        }
        isAwaitingUser = entries.contains { $0.approval != nil || $0.question != nil || $0.plan != nil || $0.elicitation != nil }
        Task { await session.resolvePlan(callID: callID, decision: .revise(feedback)) }
    }

    func showDiff(for change: IDEAgentFileChange) {
        host?.agentShowDiff(relativePath: change.path, original: change.original)
    }

    /// Puts a finished run's files back. A file the user changed after the agent wrote it is left
    /// alone and listed on the card, where Show Diff compares it with the original.
    func revert(entryID: UUID) {
        guard !isRunning, let host, let root = host.agentProjectRoot,
              let entry = entries.first(where: { $0.id == entryID }), let run = entry.run, !entry.isReverted
        else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let report: RevertReport
                self.writeFlag.isReverting = true
                defer { self.writeFlag.isReverting = false }
                if let session = self.session {
                    report = try await session.revertRun(run)
                } else {
                    // After a relaunch there is no session yet, and reverting must not need one (it would
                    // need a working provider setup): the log and the workspace are enough.
                    let log = await self.ensureCheckpointLog()
                    let workspace = self.agentWorkspace ?? IDEAgentWorkspace(root: root, box: IDEAgentHostBox(host))
                    report = await log.revert(run, using: workspace)
                }
                self.finishRevert(entryID: entryID, report: report)
            } catch {
                self.append(.init(kind: .error, text: error.localizedDescription))
            }
        }
    }

    private func finishRevert(entryID: UUID, report: RevertReport) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[index].conflicts = report.conflicts.map { IDEAgentFileChange(path: $0.path, original: $0.original) }
        entries[index].isReverted = report.isComplete
        announce(report)
    }

    /// What a revert did, as notices (and errors for what could not be done).
    private func announce(_ report: RevertReport, prefix: String = "") {
        var parts: [String] = []
        if !report.reverted.isEmpty { parts.append("Reverted \(report.reverted.count) \(report.reverted.count == 1 ? "file" : "files").") }
        if !report.conflicts.isEmpty {
            parts.append("\(report.conflicts.count) changed since the agent wrote \(report.conflicts.count == 1 ? "it" : "them") and \(report.conflicts.count == 1 ? "was" : "were") left as is.")
        }
        if !prefix.isEmpty || !parts.isEmpty { append(.init(kind: .notice, text: ([prefix] + parts).filter { !$0.isEmpty }.joined(separator: " "))) }
        for (path, reason) in report.failures.sorted(by: { $0.key < $1.key }) {
            append(.init(kind: .error, text: "Could not revert \(path): \(reason)"))
        }
    }

    // MARK: - Shortening

    /// `/compact`: summarizes the earlier conversation to free up the window. `focus` says what to keep in detail.
    func compact(focus: String?) async {
        guard supportsAgentKitOnlyFeatures else {
            appendNotice("Shortening is not available for an external ACP agent.")
            return
        }
        guard !isRunning, !isCompacting, let host, let root = host.agentProjectRoot else { return }
        guard session != nil || !(restoredItems ?? []).isEmpty else {
            appendNotice("There is nothing to shorten yet.")
            return
        }
        isCompacting = true
        status = "Summarizing the conversation…"
        defer {
            isCompacting = false
            status = nil
        }
        do {
            let active = try await currentSession(root: root, host: host)
            let report = try await active.compactNow(focus: focus)
            if report.changedAnything {
                handle(.compacted(report))
                persist(items: await active.items, checkpoints: await active.checkpoints.snapshot())
            } else if report.summaryFailed {
                appendError("The summary could not be written, so the conversation was not shortened.")
            } else {
                appendNotice("The conversation is already short; there is nothing to summarize yet.")
            }
        } catch {
            appendError(error.localizedDescription)
        }
    }

    // MARK: - Rewinding and forking

    /// The messages this chat can go back to, newest first. Empty for ACP conversations:
    /// rewind is an AgentKit-session feature an external agent cannot honour.
    var rewindTargets: [IDEAgentRewindTarget] {
        supportsAgentKitOnlyFeatures ? IDEAgentRewind.targets(in: entries) : []
    }

    /// Goes back to before the user message `entryID`: its conversation, the files the agent changed since,
    /// or both. The message goes back into the field to be sent again, or changed. Not while a run is going.
    @discardableResult
    func rewind(to entryID: UUID, scope: IDEAgentRewind.Scope) async -> Bool {
        guard !isRunning, let host, let root = host.agentProjectRoot,
              let position = entries.firstIndex(where: { $0.id == entryID }), entries[position].kind == .user,
              let target = rewindTargets.first(where: { $0.id == entryID })
        else { return false }

        var report: RevertReport?
        if scope != .conversation, !target.runs.isEmpty {
            writeFlag.isReverting = true
            defer { writeFlag.isReverting = false }
            if let session {
                do { report = try await session.revertRuns(target.runs) } catch {
                    append(.init(kind: .error, text: error.localizedDescription))
                    return false
                }
            } else {
                // After a relaunch there is no session, and going back must not need one.
                let log = await ensureCheckpointLog()
                report = await log.revertRuns(target.runs, using: agentWorkspace ?? IDEAgentWorkspace(root: root, box: IDEAgentHostBox(host)))
            }
        }

        guard scope != .code else {
            if let report { markReverted(report, inEntriesAfter: position) }
            announce(report ?? RevertReport(), prefix: report == nil ? "No file changes to revert from this message on." : "")
            return true
        }

        let itemIndex = target.itemIndex
        if let session {
            do { try await session.rewind(toBeforeItem: itemIndex) } catch {
                append(.init(kind: .error, text: error.localizedDescription))
                return false
            }
            todos = await session.todoList.items
        } else {
            restoredItems = Array((restoredItems ?? []).prefix(itemIndex))
            todos = TodoList.latest(in: restoredItems ?? [])
            restoredTodos = []
        }
        let text = entries[position].text
        entries.removeSubrange(position...)
        draft = text
        status = nil
        if let report {
            announce(report, prefix: "Went back to before that message.")
        } else {
            append(.init(kind: .notice, text: "Went back to before that message."))
        }
        let items = await session?.items ?? restoredItems ?? []
        persist(items: items, checkpoints: await checkpointLog?.snapshot() ?? restoredRuns)
        return true
    }

    /// The cards of the runs a revert reached show what happened to their files.
    private func markReverted(_ report: RevertReport, inEntriesAfter position: Int) {
        for index in entries.indices where index > position && entries[index].kind == .changes {
            let paths = Set(entries[index].fileChanges.map(\.path))
            let conflicts = report.conflicts.filter { paths.contains($0.path) }
            entries[index].conflicts = conflicts.map { IDEAgentFileChange(path: $0.path, original: $0.original) }
            entries[index].isReverted = conflicts.isEmpty && report.failures.keys.allSatisfy { !paths.contains($0) }
        }
    }

    /// What a fork starts from: this chat's transcript and history up to before `entryID` (all of it if
    /// `nil`). "Files changed" cards are left out: their originals belong to this chat. `nil` while a run is going.
    func forkState(before entryID: UUID?) async -> (entries: [IDEAgentEntry], items: [ConversationItem], title: String)? {
        guard !isRunning else { return nil }
        let allItems = await session?.items ?? restoredItems ?? []
        var keptEntries = entries
        var keptItems = allItems
        if let entryID {
            guard let position = entries.firstIndex(where: { $0.id == entryID }), entries[position].kind == .user,
                  let itemIndex = entries[position].itemIndex, itemIndex <= allItems.count
            else { return nil }
            keptEntries = Array(entries[..<position])
            keptItems = Array(allItems.prefix(itemIndex))
        }
        keptEntries.removeAll { $0.kind == .changes }
        return (keptEntries, keptItems, title)
    }

    /// Makes this (new, empty) chat a fork of another.
    func adoptFork(entries newEntries: [IDEAgentEntry], items: [ConversationItem], title: String) {
        guard isEmpty, !isRunning else { return }
        entries = newEntries
        restoredItems = items
        todos = TodoList.latest(in: items)
        restoredTodos = todos
        customTitle = title + " (fork)"
        persist(items: items, checkpoints: [])
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
            case .awaitingPlanApproval: status = "Waiting for you to approve the plan…"
            }
        case .textDelta, .reasoningDelta:
            break
        case .turnRestarted:
            entries.removeSubrange(min(turnStart, entries.count)...)
            status = "Retrying…"
        case .retryScheduled(let attempt, let delay):
            status = IDEAgentToolSummary.retryStatus(attempt: attempt, delay: delay)
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
                entries[index].plan = nil
                entries[index].elicitation = nil
            }
        case .toolCallOutput:
            break
        case .approvalRequested(let request):
            if let index = toolIndex(request.callID) { entries[index].approval = request }
            isAwaitingUser = true
            onAttention?(.needsYou(request.diff != nil ? "Wants to change a file: \(request.command)" : "Wants to run: \(request.command)"))
        case .questionAsked(let question):
            if let index = toolIndex(question.callID) { entries[index].question = question }
            isAwaitingUser = true
            onAttention?(.needsYou(question.question))
        case .planProposed(let callID, let plan):
            if let index = toolIndex(callID) { entries[index].plan = plan }
            isAwaitingUser = true
            onAttention?(.needsYou("A plan is ready for your approval."))
        case .todosUpdated(let items):
            todos = items
        case .unreadableToolCall:
            // The loop has told the model and it is trying again; say so rather than leave a silent gap.
            append(.init(kind: .notice, text: "The model wrote a tool call that could not be read. Asking it to try again."))
        case .compacted(let report):
            // A summary replaces the start of the history, so every recorded position is now wrong.
            if report.summarizedItems > 0 { for index in entries.indices { entries[index].itemIndex = nil } }
            if report.estimatedTokensAfter > 0 { contextTokens = report.estimatedTokensAfter }
            if let notice = Self.compactionNotice(report) { append(.init(kind: .notice, text: notice)) }
        case .continuing(let reason, let attempt):
            append(.init(kind: .notice, text: IDEAgentToolSummary.continuationNotice(reason, attempt: attempt)))
        case .stepFinished(let items):
            noteStep(items)
        case .stopGateChecked(let passed, let summary):
            // A pass is silent; a block shows why the run continues instead of ending.
            if !passed { append(.init(kind: .notice, text: summary)) }
        case .subagent:
            // Progress UI for a delegated child (collapsible card) plugs in here; the summary
            // already lands on the explore tool's own card.
            break
        case .subagentFinished(_, let agent, let description, _, let ending):
            // A background child's report goes to the model as a note; the user sees that it finished.
            var text = "Subagent “\(description)” (\(agent)) finished in the background."
            if case .failed(let message) = ending { text = "Subagent “\(description)” (\(agent)) failed: \(message)" }
            append(.init(kind: .notice, text: text))
        case .usage(let turnUsage):
            // The input of the latest turn is what the window holds right now.
            if turnUsage.inputTokens > 0 { contextTokens = turnUsage.inputTokens }
            usage = usage + turnUsage
            if let turnCost = settings.cost(of: turnUsage, for: effectiveChoice), let total = cost { cost = total + turnCost } else { cost = nil }
        case .runEnded(let ending):
            lastEnding = ending
            closeStreamingEntry()
            if case .failed(let message) = ending, IDEAgentNetworkFailure.offersRetry(message) {
                // The turn never landed in the history. Drop its partial text so Retry starts clean.
                dropUncommittedTurn()
                var entry = IDEAgentEntry(kind: .error, text: message)
                entry.canRetry = true
                append(entry)
            } else if let message = IDEAgentToolSummary.endingMessage(ending, iterationLimit: iterationLimit) {
                append(.init(kind: message.isError ? .error : .notice, text: message.text))
            }
        }
    }

    /// Removes the model turn that failed before it was saved. A user message is never part of it.
    private func dropUncommittedTurn() {
        guard entries.indices.contains(turnStart) else { return }
        guard !entries[turnStart...].contains(where: { $0.kind == .user }) else { return }
        entries.removeSubrange(turnStart...)
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

/// Whether the writes happening now are a revert. Read from the thread a write happens on, so it is locked.
final class WriteSourceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var reverting = false

    var isReverting: Bool {
        get { lock.withLock { reverting } }
        set { lock.withLock { reverting = newValue } }
    }
}

/// What the model is told about commands the user ran themselves.
enum IDEAgentShellContext {
    /// A user-run command may take longer than one the agent asks for: they are watching it.
    static let timeout: TimeInterval = 300
    static let maxCharacters = 16_000
    static let maxCommands = 5

    /// The text put before the user's next message, or nothing.
    static func prefix(for commands: [String]) -> String {
        guard !commands.isEmpty else { return "" }
        return UntrustedContent.wrap(commands.joined(separator: "\n\n"), source: "commands the user ran") + "\n\n"
    }

    /// The newest few commands, each cut to a share of the budget so one noisy build cannot push out the rest.
    static func bounded(_ commands: [String]) -> [String] {
        let recent = Array(commands.suffix(maxCommands))
        let share = max(1_000, maxCharacters / max(recent.count, 1))
        return recent.map { OutputTruncation.headAndTail($0, maxCharacters: share) }
    }
}
