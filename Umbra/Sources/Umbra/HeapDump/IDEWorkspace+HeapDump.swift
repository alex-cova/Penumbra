import AppKit
import JavaIntelligence
import Penumbra
import UniformTypeIdentifiers

/// Heap dumps (`.hprof`) as editor tabs: opening one (Explorer, Finder, File ▸ Open Heap Dump…,
/// the palette), the tab's viewer, Reopen as Hex, closing.
extension IDEWorkspace {
    /// Opens `url` in a heap dump tab, or selects the tab already showing it.
    func openHeapDump(file url: URL) {
        let standard = url.standardizedFileURL
        for pane in workbench.panes {
            for document in pane.documents where document.contentKind == .heapDump {
                if document.url?.standardizedFileURL == standard {
                    selectTab(document.id, in: pane.id)
                    return
                }
            }
        }
        let document = WorkbenchDocument(displayName: url.lastPathComponent)
        document.contentKind = .heapDump
        document.url = url
        heapDumpSessionStore.register(makeHeapDumpSession(url: url, title: url.lastPathComponent), for: document.id)
        presentDiagramDocument(document)
    }

    /// File ▸ Open Heap Dump…
    func chooseHeapDump() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Java heap dump (.hprof)."
        if let type = UTType(filenameExtension: "hprof") { panel.allowedContentTypes = [type] }
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recordRecentFile(url)
        openHeapDump(file: url)
    }

    /// `Caches/com.umbra.editor/HeapDumpIndexes`: one folder per dump, rebuilt when the dump changes.
    static let heapIndexStore: HeapIndexStore? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        .map { HeapIndexStore(root: $0.appendingPathComponent("com.umbra.editor/HeapDumpIndexes", isDirectory: true)) }

    func makeHeapDumpSession(url: URL, title: String) -> IDEHeapDumpSession {
        let session = IDEHeapDumpSession(url: url, title: title, indexStore: Self.heapIndexStore)
        session.openSource = { [weak self] className in
            self?.openProfileFrame(className: className, line: 0)
        }
        session.openAsHex = { [weak self, weak session] in
            guard let self, let session else { return }
            self.reopenHeapDumpAsHex(sessionID: session.id)
        }
        session.revealInFinder = {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        return session
    }

    /// Reopen as Hex for a heap dump tab: the same tab shows the file's bytes.
    func reopenHeapDumpAsHex(sessionID: UUID) {
        guard let documentID = heapDumpSessionStore.documentID(forSessionID: sessionID) else { return }
        for pane in workbench.panes {
            guard let document = pane.documents.first(where: { $0.id == documentID }) else { continue }
            closeHeapDumpSession(document.id, in: pane)
            Task { await reopenAsHex(document) }
            return
        }
    }

    func closeHeapDumpSession(_ documentID: UUID, in pane: EditorPane) {
        guard let session = heapDumpSessionStore.removeSession(for: documentID) else { return }
        hostCache.peek(pane.id)?.heapDumpViewer.detach(session)
        session.cancel()
    }

    func closeAllHeapDumpSessions() {
        heapDumpSessionStore.closeAll()
    }

    /// Puts a heap dump tab's viewer over the pane's editor, keeping the text document it replaces.
    func showHeapDumpDocument(_ document: WorkbenchDocument, in pane: EditorPane, host: IDEEditorPaneHost) {
        var session = heapDumpSessionStore.session(for: document.id)
        if session == nil {
            // A tab restored with the session: its file is the dump, or the tab goes.
            guard let url = document.url, FileManager.default.fileExists(atPath: url.path) else {
                let id = document.id
                Task { @MainActor [weak self] in self?.closeTab(id, in: pane.id) }
                return
            }
            let made = makeHeapDumpSession(url: url, title: document.displayName)
            heapDumpSessionStore.register(made, for: document.id)
            session = made
        }
        guard let session else { return }
        changeMarkers.hide(on: host.textView)
        if let previousID = host.loadedDocumentID,
           previousID != document.id,
           let previous = pane.documents.first(where: { $0.id == previousID }),
           previous.contentKind == .text {
            syncTextViewToDocument(host.textView, document: previous, from: host)
            previous.pendingState = host.textView.makeCapturedState()
        }
        host.markdownPreviewController.closeIfNotMarkdown()
        host.hideJSONDiagram(hidingViewer: false)
        host.hideCSVTable()
        host.imageViewerController.hide()
        host.diffViewer.hide()
        host.diagramViewer.hide()
        host.hexViewer.hide()
        host.profileViewer.hide()
        host.heapDumpViewer.show(session)
        host.loadedDocumentID = document.id
        host.loadedGeneration = document.contentGeneration
        if pane.id == workbench.activePaneID {
            host.heapDumpViewer.focus()
        }
    }
}
