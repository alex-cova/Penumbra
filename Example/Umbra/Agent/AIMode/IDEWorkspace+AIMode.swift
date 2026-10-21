import AppKit

extension IDEWorkspace {
    var isAIMode: Bool { windowMode == .ai }

    /// Shows AI mode over the window, on `tab` when given. The editor keeps its state underneath.
    func showAIMode(tab: IDEAITab? = nil) {
        if let tab { aiTab = tab }
        guard windowMode != .ai else { return }
        prepareForAIMode()
        windowMode = .ai
    }

    /// Back to the editor, with the caret where it was.
    func showEditorMode() {
        guard windowMode == .ai else { return }
        windowMode = .editor
        focusActiveEditor()
    }

    func toggleAIMode() {
        if isAIMode { showEditorMode() } else { showAIMode() }
    }

    /// What the editor-side opens do first: a file, a diff or Settings is shown in the editor, so AI
    /// mode steps aside.
    func leaveAIModeForEditor() {
        guard windowMode == .ai else { return }
        windowMode = .editor
    }
}

extension IDEWorkspace {
    /// Shows this window's project in AI mode, on the chat the request names. The project must be open.
    func applyAIOpen(_ request: IDEAIOpenRequest) {
        showAIMode(tab: .code)
        if let chat = request.resumeChat { agent.resume(chat) }
    }

    /// A project from AI mode's list: it opens where the router puts it (an empty window, a window that
    /// already has it, or a new window) and that window shows AI mode.
    func openProjectInAIMode(_ url: URL, resumeChat: UUID? = nil) {
        let request = IDEAIOpenRequest(resumeChat: resumeChat)
        if project.rootURL?.standardizedFileURL == url.standardizedFileURL {
            applyAIOpen(request)
        } else {
            IDEWindowRegistry.shared.open(urls: [url], origin: .window(windowID), aiOpen: request)
        }
    }

    /// Open Folder… from AI mode.
    func chooseProjectInAIMode() {
        IDEWindowRegistry.shared.chooseFolder(from: .window(windowID), aiOpen: IDEAIOpenRequest())
    }
}

extension IDEWorkspace {
    /// What `tab` still needs before a message can be sent, or `nil` when its model is usable. An
    /// external agent does its own setup, so it never asks.
    func aiModelSetupHint(for tab: IDEAITab) -> String? {
        switch tab {
        case .chat:
            return aiChat.selected.setupHint
        case .code:
            guard !agent.selected.isACPConversation else { return nil }
            return agent.settings.setupHint(for: agent.selected.effectiveChoice)
        }
    }

    /// Makes `choice` the model of the chat or session `tab` shows, and the one new ones start with.
    func selectAIModel(_ choice: IDEAIModelChoice, for tab: IDEAITab) {
        switch tab {
        case .chat:
            aiChat.choose(choice)
        case .code:
            agent.selected.modelChoice = choice
            IDEAISettings.shared.codeChoice = choice
            agent.newChatChoice = choice
        }
    }

    func requestAIModelSetup(for tab: IDEAITab) {
        aiModelSetup = tab
    }

    /// Opens the setup sheet the first time AI mode shows a tab with no usable model. The installed
    /// models are read first: Chat falls back to an Ollama or on-device model once the list is known, and
    /// the sheet must not flash up for a setup that already works.
    func offerAIModelSetupIfNeeded() async {
        guard !hasOfferedAIModelSetup else { return }
        IDELocalModelsStore.shared.prepareIfNeeded()
        await agent.settings.refreshOllamaModels(adjustSelection: false)
        guard !hasOfferedAIModelSetup, isAIMode, aiModelSetup == nil, aiModelSetupHint(for: aiTab) != nil else { return }
        hasOfferedAIModelSetup = true
        aiModelSetup = aiTab
    }
}
