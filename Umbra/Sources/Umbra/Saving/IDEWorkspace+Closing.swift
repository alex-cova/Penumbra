import AppKit
import Penumbra

/// Why closing could not just save a buffer and go on.
enum IDEClosePrompt: Equatable {
    /// A buffer with no file yet.
    case untitled
    /// The buffer has a file, and writing it failed or would overwrite a newer version.
    case couldNotSave(String)
}

enum IDEClosePromptChoice: Equatable {
    /// Name the file and save it (untitled buffers).
    case save
    /// Close and lose the unsaved changes.
    case discard
    case cancel
}

/// File ▸ Close Folder, when an editor still has unsaved changes.
enum IDEFolderCloseChoice: Equatable {
    /// Save what can be saved, then close. A file that cannot be saved asks on its own.
    case save
    /// Close the folder and drop the unsaved changes.
    case discard
    case cancel
}

/// Closing a tab saves what it holds first, as IntelliJ does. Only the user-facing closes (the tab's
/// ×, its context menu, ⌘W) go through here: closing a tab because its file was deleted, or a merge
/// tab applying itself, must never write a file, and `closeTab` still does not.
extension IDEWorkspace {
    func requestCloseActiveTab() {
        guard let document = workbench.activePane.selectedDocument else { return }
        requestClose([document.id], in: workbench.activePane)
    }

    func requestCloseTab(_ id: UUID, in paneID: UUID) {
        guard let pane = workbench.layout.findPane(id: paneID) else { return }
        requestClose([id], in: pane)
    }

    func requestCloseOtherTabs(_ id: UUID, in paneID: UUID) {
        guard let pane = workbench.layout.findPane(id: paneID) else { return }
        requestClose(pane.documents.map(\.id).filter { $0 != id }, in: pane)
    }

    func requestCloseTabsToRight(_ id: UUID, in paneID: UUID) {
        guard let pane = workbench.layout.findPane(id: paneID),
              let index = pane.documents.firstIndex(where: { $0.id == id }) else { return }
        requestClose(pane.documents[(index + 1)...].map(\.id), in: pane)
    }

    func requestCloseAllTabs(in paneID: UUID) {
        guard let pane = workbench.layout.findPane(id: paneID) else { return }
        requestClose(pane.documents.map(\.id), in: pane)
    }

    /// Saves the unsaved documents among `ids` that this close would drop, then closes them all. A
    /// cancelled prompt closes nothing. With nothing unsaved it closes at once.
    private func requestClose(_ ids: [UUID], in pane: EditorPane) {
        let paneID = pane.id
        let dirty = pane.documents.filter { document in
            ids.contains(document.id) && document.isDirty && !isOpenInAnotherPane(document, besides: paneID)
        }
        func closeAll() {
            guard let pane = workbench.layout.findPane(id: paneID) else { return }
            for id in ids where pane.documents.contains(where: { $0.id == id }) {
                closeTab(id, in: paneID)
            }
        }
        guard !dirty.isEmpty else {
            closeAll()
            return
        }
        Task { @MainActor [self] in
            guard await saveForClosing(dirty) else { return }
            closeAll()
        }
    }

    private func isOpenInAnotherPane(_ document: WorkbenchDocument, besides paneID: UUID) -> Bool {
        workbench.panes.contains { $0.id != paneID && $0.documents.contains { $0.id == document.id } }
    }

    /// Writes each document, asking about the ones that cannot be written. Returns whether the
    /// close may go on.
    func saveForClosing(_ documents: [WorkbenchDocument]) async -> Bool {
        for document in documents where document.isDirty {
            let outcome = await saveDocument(document, reason: .closingTab)
            let prompt: IDEClosePrompt
            switch outcome {
            case .saved, .clean:
                continue
            case .skippedUntitled:
                prompt = .untitled
            case .conflict:
                prompt = .couldNotSave("The file changed on disk, and saving would replace the newer version.")
            case .failed(let message):
                prompt = .couldNotSave(message)
            }
            switch closePromptResolver(document, prompt) {
            case .save:
                guard await saveDocument(document, reason: .explicit) == .saved else { return false }
            case .discard:
                continue
            case .cancel:
                return false
            }
        }
        return true
    }

    static func askAboutClosing(_ document: WorkbenchDocument, _ prompt: IDEClosePrompt) -> IDEClosePromptChoice {
        switch prompt {
        case .untitled:
            var alert = IDEAlert.choice(
                "Save changes to “\(document.displayName)”?",
                detail: "Your changes will be lost if you don't save them.",
                buttons: [.init(title: "Save…"), .init(title: "Don't Save", isDestructive: true), .init(title: "Cancel")])
            switch alert.runModal() {
            case 0: return .save
            case 1: return .discard
            default: return .cancel
            }
        case .couldNotSave(let reason):
            var alert = IDEAlert.confirm(
                "“\(document.displayName)” could not be saved.",
                detail: "\(reason)\nClosing the tab loses its unsaved changes.",
                confirm: "Close Anyway", isDestructive: true)
            return alert.confirms() ? .discard : .cancel
        }
    }

    static func askAboutClosingFolder(_ informativeText: String) -> IDEFolderCloseChoice {
        var alert = IDEAlert.choice(
            "Close the open folder?", detail: informativeText,
            buttons: [.init(title: "Save"), .init(title: "Don't Save", isDestructive: true), .init(title: "Cancel")])
        switch alert.runModal() {
        case 0: return .save
        case 1: return .discard
        default: return .cancel
        }
    }
}
