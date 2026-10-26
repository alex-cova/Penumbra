import AgentKit
import Foundation
import Observation

/// One window's plain chats: the open conversations, which one shows, and the saved ones. Chats are
/// kept in their own store, apart from any project, so every window lists the same ones.
@MainActor
@Observable
final class IDEAIChatController {
    private(set) var conversations: [IDEAIChatConversation] = []
    private(set) var selectedID: UUID
    /// Saved chats, newest first.
    private(set) var history: [SessionSummary] = []
    /// Bumped to put the caret in the message field.
    var composerFocusRequest = 0
    /// Bumped by `/model`; the view opens the models sheet for it.
    var modelRequest = 0
    /// Tests replace this; the default asks where to save.
    @ObservationIgnored var exportHandler: @MainActor (String, String) -> Void = IDEAgentController.presentSavePanel

    let settings: IDEAgentSettings
    @ObservationIgnored let aiSettings: IDEAISettings
    @ObservationIgnored private let store: SessionStore?
    @ObservationIgnored private let clientFactory: @MainActor (IDEAgentSettings, IDEAIModelChoice) throws -> any LLMClient

    /// Chats live beside the project conversations, in a folder of their own.
    static func appStore() -> SessionStore? {
        (try? SessionStore.defaultDirectory(appFolder: "com.umbra.editor")).map {
            SessionStore(directory: $0.deletingLastPathComponent().appendingPathComponent("Chats", isDirectory: true))
        }
    }

    init(
        settings: IDEAgentSettings = .shared,
        aiSettings: IDEAISettings = .shared,
        store: SessionStore? = nil,
        clientFactory: @escaping @MainActor (IDEAgentSettings, IDEAIModelChoice) throws -> any LLMClient = {
            // Plain chat offers no tools, so a model without tool support is allowed.
            try $0.makeClient(for: $1, requiresTools: false)
        }
    ) {
        self.settings = settings
        self.aiSettings = aiSettings
        self.store = store
        self.clientFactory = clientFactory
        let first = IDEAIChatConversation(
            settings: settings, aiSettings: aiSettings, store: store, defaultChoice: { [aiSettings, settings] in
                IDEAIChatController.defaultChoice(aiSettings: aiSettings, settings: settings)
            }, clientFactory: clientFactory)
        conversations = [first]
        selectedID = first.id
        wire(first)
        refreshHistory()
    }

    /// What a chat with no choice of its own uses: the model last picked for Chat; else the one in
    /// Settings ▸ Agent when it is ready to use; else the first that is (an installed Ollama or
    /// on-device model, then Claude or OpenAI with a key saved), so a first chat does not open on a
    /// "set up" message while something else would work.
    static func defaultChoice(aiSettings: IDEAISettings, settings: IDEAgentSettings) -> IDEAIModelChoice {
        if let chosen = aiSettings.chatChoice { return chosen }
        var global = settings.currentChoice
        global.acpAgentID = nil
        var candidates = [global]
        if let model = settings.ollamaModels.first { candidates.append(IDEAIModelChoice(provider: .ollama, model: model.name)) }
        if let model = IDELocalModelsStore.shared.installed.first { candidates.append(IDEAIModelChoice(provider: .mlx, model: model.id)) }
        // Nothing to download and no key, so a Mac with Apple Intelligence opens Chat on a model that works.
        candidates.append(IDEAIModelChoice(provider: .apple, model: IDEAgentProvider.apple.defaultModel))
        for provider in [IDEAgentProvider.anthropic, .meta, .openAIResponses] where settings.hasAPIKey(for: provider) {
            candidates.append(IDEAIModelChoice(provider: provider, model: settings.model(for: provider)))
        }
        return candidates.first { settings.setupHint(for: $0) == nil } ?? global
    }

    private func makeConversation() -> IDEAIChatConversation {
        let conversation = IDEAIChatConversation(
            settings: settings, aiSettings: aiSettings, store: store,
            defaultChoice: { [aiSettings, settings] in IDEAIChatController.defaultChoice(aiSettings: aiSettings, settings: settings) },
            clientFactory: clientFactory)
        wire(conversation)
        return conversation
    }

    private func wire(_ conversation: IDEAIChatConversation) {
        conversation.onPersisted = { [weak self] in self?.refreshHistory() }
        conversation.onRunFinished = { [weak self, weak conversation] in
            guard let self, let conversation, conversation.id != self.selectedID else { return }
            conversation.isUnread = true
        }
    }

    var selected: IDEAIChatConversation { conversations.first { $0.id == selectedID } ?? conversations[0] }

    func refreshHistory() {
        history = store?.list(projectRoot: IDEAIChatConversation.storeRoot) ?? []
    }

    /// A new, empty chat, selected. An empty one is reused.
    func newChat() {
        if selected.isEmpty && !selected.isRunning {
            composerFocusRequest += 1
            return
        }
        let created = makeConversation()
        // A new chat starts with the model the last one used.
        created.modelChoice = selected.modelChoice
        conversations.append(created)
        select(created.id)
    }

    func select(_ id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        selectedID = id
        conversation.isUnread = false
        composerFocusRequest += 1
    }

    /// Shows a saved chat: in the tab that already has it, else in the selected chat if that is
    /// empty, else in a new one.
    func resume(_ id: UUID) {
        if let open = conversations.first(where: { $0.conversationID == id }) {
            select(open.id)
            return
        }
        guard let store, let snapshot = store.load(id, projectRoot: IDEAIChatConversation.storeRoot) else { return }
        let target: IDEAIChatConversation
        if selected.isEmpty && !selected.isRunning {
            target = selected
        } else {
            target = makeConversation()
            conversations.append(target)
        }
        target.load(snapshot)
        select(target.id)
    }

    /// Deletes a saved chat. A tab showing it is closed, unless it is running.
    func delete(_ id: UUID) {
        if let open = conversations.first(where: { $0.conversationID == id }) {
            guard !open.isRunning else { return }
            close(open.id)
        }
        store?.delete(id, projectRoot: IDEAIChatConversation.storeRoot)
        refreshHistory()
    }

    /// Closes an open chat; the last one is emptied instead.
    func close(_ id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].teardown()
        if conversations.count == 1 {
            conversations[index].reset()
            return
        }
        conversations.remove(at: index)
        if selectedID == id { selectedID = conversations[min(index, conversations.count - 1)].id }
    }

    func rename(_ id: UUID, to name: String) {
        conversations.first { $0.id == id }?.rename(name)
    }

    /// Records the model for the selected chat and for chats started later.
    func choose(_ choice: IDEAIModelChoice) {
        selected.modelChoice = choice
        aiSettings.chatChoice = choice
    }

    func teardown() {
        for conversation in conversations { conversation.teardown() }
    }
}
