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
    private(set) var conversations: [IDEAgentConversation]
    private(set) var selectedID: UUID

    var isPanelVisible = false
    /// Called before the chat page opens, so the window can close what it would cover (Settings).
    @ObservationIgnored var onPanelRequested: (() -> Void)?
    /// Bumped when something fills the composer from outside, so the panel moves focus to it.
    var composerFocusRequest = 0
    /// This project's saved conversations, newest first, for the history menu.
    private(set) var history: [SessionSummary] = []

    let settings: IDEAgentSettings

    @ObservationIgnored private weak var host: (any IDEAgentHost)?
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
        wire(first)
    }

    private func wire(_ conversation: IDEAgentConversation) {
        conversation.host = host
        conversation.onPersisted = { [weak self] in self?.refreshHistory() }
        conversation.willSend = { [weak self] in self?.restoreLatestIfNeeded() }
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

    /// What the list above the composer offers for `/` and `@`. Nothing yet: the built-in commands
    /// and the project's files are added with them.
    func suggestions(for trigger: IDEAgentComposerTrigger) -> [IDEAgentSuggestion] { [] }

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

    /// Loads a saved conversation into the selected one.
    func resume(_ id: UUID) {
        guard !selected.isRunning, let store, let root = host?.agentProjectRoot,
              let snapshot = store.load(id, projectRoot: root.path)
        else { return }
        selected.load(snapshot)
        didRestore = true
    }

    func deleteConversation(_ id: UUID) {
        guard let store, let root = host?.agentProjectRoot else { return }
        store.delete(id, projectRoot: root.path)
        if id == selected.conversationID, !selected.isRunning { newConversation() }
        refreshHistory()
    }

    /// Settings ▸ Agent ▸ Clear History: every saved conversation of this project.
    func clearHistory() {
        guard let store, let root = host?.agentProjectRoot else { return }
        store.deleteAll(projectRoot: root.path)
        history = []
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

    /// Starts an empty conversation. The one being left stays in the history.
    func newConversation() {
        selected.reset()
        didRestore = true
    }

    func clear() { newConversation() }
}
