import AgentKit
import Foundation
import Observation

/// One window's agent: its conversations, the panel's visibility, and what the conversations share
/// (the saved-history list and the settings).
///
/// Each conversation reaches the window only through `IDEAgentHost`, held weakly, so a running
/// session never keeps the window alive; `teardown()` ends them all. The members below the
/// "Selected conversation" mark act on `selected`: they keep the call sites that predate tabs short.
@MainActor
@Observable
final class IDEAgentController {
    /// The chats, in tab order. Each can run on its own.
    private(set) var conversations: [IDEAgentConversation]
    private(set) var selectedID: UUID
    /// Which chat is changing which file, shared by all of them.
    @ObservationIgnored let fileClaims = IDEAgentFileClaims()
    /// The commands and skills on offer.
    @ObservationIgnored private(set) var commandCatalog: IDEAgentCommandCatalog!
    /// Bumped by `/model`, so the panel opens its settings popover.
    var settingsRequest = 0
    /// Set to show the rewind sheet (`/rewind`, a message's Rewind button, Esc Esc).
    var rewindRequest: IDEAgentRewindRequest?
    /// What this project's chats were asked, by project folder.
    @ObservationIgnored private var promptHistories: [String: IDEAgentPromptHistory] = [:]
    /// Whether the user is looking at this window (it is the key window). Without an answer, assume yes.
    @ObservationIgnored var isUserWatching: (() -> Bool)?
    /// Tells the user something about a chat they are not looking at: the chat's id, a title, a detail.
    @ObservationIgnored var onNotify: ((_ chat: UUID, _ title: String, _ detail: String?, _ severity: IDENotificationSeverity) -> Void)?
    /// Opens Settings ▸ Agent (`/permissions`); set by the window.
    @ObservationIgnored var onOpenSettings: (() -> Void)?
    /// Saves an exported transcript: a save panel, unless a test replaces it.
    @ObservationIgnored var exportHandler: @MainActor (_ name: String, _ markdown: String) -> Void = IDEAgentController.presentSavePanel

    var isPanelVisible = false {
        didSet { if oldValue != isPanelVisible { layoutChanged() } }
    }
    /// Called when what a window session keeps of the agent changed: the chats, the selection, the panel.
    @ObservationIgnored var onLayoutChanged: (() -> Void)?
    @ObservationIgnored private var layoutNotificationsSuspended = false
    /// Called before the chat page opens, so the window can close what it would cover (Settings).
    @ObservationIgnored var onPanelRequested: (() -> Void)?
    /// Bumped when something fills the composer from outside, so the panel moves focus to it.
    var composerFocusRequest = 0
    /// This project's saved conversations, newest first, for the history menu.
    private(set) var history: [SessionSummary] = []

    let settings: IDEAgentSettings

    @ObservationIgnored private weak var hostReference: (any IDEAgentHost)?
    /// The window this agent works in; weak, so a chat never keeps it alive.
    var host: (any IDEAgentHost)? {
        get { hostReference }
        set { hostReference = newValue }
    }
    @ObservationIgnored private let store: SessionStore?
    @ObservationIgnored private let appPermissionsFile: URL?
    @ObservationIgnored private let clientFactory: @MainActor (IDEAgentSettings) throws -> any LLMClient
    @ObservationIgnored private var didRestore = false
    /// True while a Gradle run the agent started is going, so Stop ends that run and no other.
    @ObservationIgnored var isGradleRunActive = false

    /// Conversations live in Application Support, readable by the user alone.
    static func appStore() -> SessionStore? {
        (try? SessionStore.defaultDirectory(appFolder: "com.umbra.editor")).map(SessionStore.init)
    }

    init(
        settings: IDEAgentSettings = .shared,
        store: SessionStore? = nil,
        appPermissionsFile: URL? = nil,
        commandsHome: URL? = nil,
        commandsAppSupport: URL? = nil,
        clientFactory: @escaping @MainActor (IDEAgentSettings) throws -> any LLMClient = { try $0.makeClient() }
    ) {
        self.settings = settings
        self.store = store
        self.appPermissionsFile = appPermissionsFile
        self.clientFactory = clientFactory
        let first = IDEAgentConversation(
            settings: settings, store: store, appPermissionsFile: appPermissionsFile, clientFactory: clientFactory)
        conversations = [first]
        selectedID = first.id
        commandCatalog = IDEAgentCommandCatalog(
            root: { [weak self] in self?.host?.agentProjectRoot }, loadsUserFolders: { settings.loadsUserSkills },
            home: commandsHome, appSupport: commandsAppSupport)
        wire(first)
    }

    private func wire(_ conversation: IDEAgentConversation) {
        conversation.host = host
        conversation.fileClaims = fileClaims
        conversation.commandCatalog = commandCatalog
        conversation.onPersisted = { [weak self] in
            self?.refreshHistory()
            self?.layoutChanged()
        }
        conversation.willSend = { [weak self, weak conversation] in
            guard let self, let conversation else { return }
            self.loadPendingIfNeeded(conversation)
            if conversation.id == self.selectedID { self.restoreLatestIfNeeded() }
        }
        conversation.onAttention = { [weak self, weak conversation] attention in
            guard let self, let conversation else { return }
            self.notify(attention, from: conversation)
        }
        conversation.onRunFinished = { [weak self, weak conversation] in
            guard let self, let conversation, conversation.id != self.selectedID else { return }
            conversation.isUnread = true
        }
    }

    /// The conversation the panel shows.
    var selected: IDEAgentConversation {
        conversations.first { $0.id == selectedID } ?? conversations[0]
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
        for conversation in conversations { conversation.host = host }
    }

    /// Cancels every run and drops the sessions. A session that outlives its window would keep the
    /// workspace alive through its tools.
    func teardown() {
        for conversation in conversations { conversation.teardown() }
        host = nil
    }

    var projectRoot: URL? { host?.agentProjectRoot }

    /// What Settings ▸ Agent ▸ Permissions lists and edits.
    func makePermissionsModel() -> IDEAgentPermissionsModel {
        IDEAgentPermissionsModel(projectRoot: { [weak self] in self?.host?.agentProjectRoot }, appFile: appPermissionsFile)
    }


    // MARK: - History

    /// Brings back the project's most recent conversation the first time the agent is used in a
    /// window. Reverting its changes is not offered: checkpoints do not survive a relaunch.
    func restoreLatestIfNeeded() {
        guard !didRestore else { return }
        didRestore = true
        refreshHistory()
        guard selected.isEmpty, !selected.isRunning, let latest = history.first else { return }
        resume(latest.id)
    }

    func refreshHistory() {
        guard let store, let root = host?.agentProjectRoot else { history = []; return }
        history = store.list(projectRoot: root.path)
    }

    /// Shows a saved conversation: in the tab that already has it, else in the selected chat if that is
    /// empty, else in a new one. Never over a chat that has something in it.
    func resume(_ id: UUID) {
        if let open = conversations.first(where: { $0.conversationID == id }) {
            select(open.id)
            didRestore = true
            return
        }
        guard let store, let root = host?.agentProjectRoot, let snapshot = store.load(id, projectRoot: root.path) else { return }
        let target = selected.isEmpty && !selected.isRunning ? selected : addConversation()
        target.load(snapshot)
        didRestore = true
    }

    /// Deletes a saved conversation. A chat showing it is closed, unless it is running.
    func deleteConversation(_ id: UUID) {
        guard let store, let root = host?.agentProjectRoot else { return }
        if let open = conversations.first(where: { $0.conversationID == id }) {
            guard !open.isRunning else { return }
            close(open.id)
        }
        // The originals kept for its runs go with it.
        if let snapshot = store.load(id, projectRoot: root.path) {
            let blobs = IDEAgentCheckpointBlobs(store: store, projectRoot: root.path)
            for run in IDEAgentSavedTranscript.decode(snapshot.host).checkpoints { blobs.removeRun(run.id) }
        }
        store.delete(id, projectRoot: root.path)
        refreshHistory()
    }

    /// Settings ▸ Agent ▸ Clear History: every saved conversation of this project.
    func clearHistory() {
        guard let store, let root = host?.agentProjectRoot else { return }
        store.deleteAll(projectRoot: root.path)
        IDEAgentCheckpointBlobs(store: store, projectRoot: root.path).removeAll()
        promptHistory()?.clear()
        history = []
    }

    // MARK: - Chats

    /// A new, empty chat, selected.
    @discardableResult
    func addConversation() -> IDEAgentConversation {
        let created = IDEAgentConversation(
            settings: settings, store: store, appPermissionsFile: appPermissionsFile, clientFactory: clientFactory)
        wire(created)
        conversations.append(created)
        select(created.id)
        didRestore = true
        return created
    }

    func select(_ id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        selectedID = id
        conversation.isUnread = false
        loadPendingIfNeeded(conversation)
        layoutChanged()
    }

    /// Whether the user can see this chat right now: the window is active, the panel is open, and it is the chat shown.
    func isInView(_ conversation: IDEAgentConversation) -> Bool {
        conversation.id == selectedID && isPanelVisible && (isUserWatching?() ?? true)
    }

    private func notify(_ attention: IDEAgentConversation.Attention, from conversation: IDEAgentConversation) {
        guard !isInView(conversation) else { return }
        switch attention {
        case .needsYou(let what):
            onNotify?(conversation.id, "“\(conversation.title)” needs you", what, .warning)
        case .finished(let ending, let summary):
            switch ending {
            case .completed:
                onNotify?(conversation.id, "“\(conversation.title)” finished", summary.isEmpty ? nil : summary, .success)
            case .stopped:
                break
            default:
                let reason = IDEAgentToolSummary.endingMessage(ending, iterationLimit: settings.iterationCap)?.text
                onNotify?(conversation.id, "“\(conversation.title)” stopped", reason, .error)
            }
        }
    }

    private func layoutChanged() {
        if !layoutNotificationsSuspended { onLayoutChanged?() }
    }

    /// Runs `body` without telling the window its layout changed, for restoring one.
    func withoutLayoutNotifications(_ body: () -> Void) {
        layoutNotificationsSuspended = true
        defer { layoutNotificationsSuspended = false }
        body()
    }

    /// ⌃Tab and ⌃⇧Tab: the next or previous chat, wrapping around.
    func selectNeighbor(_ step: Int) {
        guard conversations.count > 1, let index = conversations.firstIndex(where: { $0.id == selectedID }) else { return }
        select(conversations[(index + step + conversations.count) % conversations.count].id)
    }

    /// Closes a chat, ending its run. The last chat is emptied instead, so there is always one.
    func close(_ id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        guard conversations.count > 1 else {
            conversations[0].reset()
            return
        }
        let closed = conversations.remove(at: index)
        closed.teardown()
        if selectedID == id { select(conversations[min(index, conversations.count - 1)].id) } else { layoutChanged() }
    }

    func closeOthers(keeping id: UUID) {
        for conversation in conversations where conversation.id != id { close(conversation.id) }
        select(id)
    }

    /// A new chat that starts from another's conversation, up to before the message `entryID` (all of it if `nil`).
    @discardableResult
    func fork(_ id: UUID, before entryID: UUID? = nil) async -> IDEAgentConversation? {
        guard let source = conversations.first(where: { $0.id == id }), let state = await source.forkState(before: entryID) else { return nil }
        let created = addConversation()
        created.adoptFork(entries: state.entries, items: state.items, title: state.title)
        return created
    }

    /// This project's prompt history: on disk beside its conversations when there is a store, else in memory.
    func promptHistory() -> IDEAgentPromptHistory? {
        guard let root = host?.agentProjectRoot else { return nil }
        let key = root.standardizedFileURL.path
        if let existing = promptHistories[key] { return existing }
        let file = store.map { $0.projectDirectory(for: root.path).appendingPathComponent("prompts.jsonl") }
        let created = IDEAgentPromptHistory(file: file)
        promptHistories[key] = created
        return created
    }

    /// ↑ (`-1`) and ↓ (`1`) in the message field: the text to show, or `nil` for none.
    func recallPrompt(_ direction: Int) -> String? {
        let prompts = promptHistory()?.prompts ?? []
        return direction < 0
            ? selected.promptRecall.previous(current: selected.draft, in: prompts)
            : selected.promptRecall.next(in: prompts)
    }

    func rename(_ id: UUID, to name: String) {
        conversations.first { $0.id == id }?.rename(name)
    }

    /// Reads a restored tab from disk the first time it is shown. One that is gone becomes an empty chat.
    private func loadPendingIfNeeded(_ conversation: IDEAgentConversation) {
        guard let pending = conversation.pendingLoadID else { return }
        guard let store, let root = host?.agentProjectRoot, let snapshot = store.load(pending, projectRoot: root.path) else {
            conversation.dropPending()
            return
        }
        conversation.load(snapshot)
    }

    /// Brings back the chats a window had open: each tab shows its saved conversation, and only the
    /// selected one is read now. Conversations that are no longer saved are skipped.
    func restoreTabs(_ ids: [UUID], selected selectedConversation: UUID?) {
        guard !didRestore, selected.isEmpty else { return }
        refreshHistory()
        let titles = Dictionary(history.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let saved = ids.filter { titles[$0] != nil }
        guard !saved.isEmpty else { return }
        didRestore = true
        for (position, id) in saved.enumerated() {
            let conversation = position == 0 ? conversations[0] : addConversation()
            conversation.showPending(id: id, title: titles[id] ?? "New Chat")
        }
        let target = conversations.first { $0.conversationID == selectedConversation } ?? conversations[0]
        select(target.id)
    }

    /// What a window session keeps of the tabs: the saved conversations they show, and the selected one.
    var restorableTabs: (ids: [UUID], selected: UUID?) {
        let saved = Set(history.map(\.id))
        let open = conversations.filter { $0.pendingLoadID != nil || saved.contains($0.conversationID) }
        return (open.map(\.conversationID), open.contains { $0.id == selectedID } ? selected.conversationID : nil)
    }

    // MARK: - Selected conversation

    var entries: [IDEAgentEntry] { selected.entries }
    var isRunning: Bool { selected.isRunning }
    var status: String? { selected.status }
    var usage: TokenUsage { selected.usage }
    var cost: Double? { selected.cost }
    var todos: [TodoItem] { selected.todos }
    var conversationID: UUID { selected.conversationID }
    var canSend: Bool { selected.canSend }
    var currentSessionForTesting: AgentSession? { selected.currentSessionForTesting }

    var draft: String {
        get { selected.draft }
        set { selected.draft = newValue }
    }

    func send() { selected.send() }

    func stop() { selected.stop() }

    func handle(_ event: AgentEvent) { selected.handle(event) }

    func decide(callID: String, _ decision: ApprovalDecision) { selected.decide(callID: callID, decision) }

    func answer(callID: String, text: String?) { selected.answer(callID: callID, text: text) }

    func showDiff(for change: IDEAgentFileChange) { selected.showDiff(for: change) }

    func revert(entryID: UUID) { selected.revert(entryID: entryID) }

    var mode: PermissionMode { selected.mode }

    /// A new chat tab (an empty one is reused). The conversation being left stays in the history.
    func newConversation() {
        if selected.isEmpty && !selected.isRunning {
            didRestore = true
            return
        }
        addConversation()
    }

    /// Empties the selected chat in place, keeping its tab.
    func clear() {
        selected.reset()
        didRestore = true
    }
}
