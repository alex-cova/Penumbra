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
