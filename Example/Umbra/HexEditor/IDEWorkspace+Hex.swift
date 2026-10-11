import AppKit
import Darwin
import Foundation
import HexKit
import Penumbra

/// Where `loadDocument` sends a file. Image wins, then the force lists, then the name classifier,
/// then an 8 KB sniff. Reopen as Hex / Text bypass the classifier.
enum IDEHexRoute: Equatable {
    case image
    case hex(sniffed: Bool)
    case text
}

enum IDEHexRouting {
    @MainActor
    static func route(
        url: URL,
        head: Data?,
        settings: IDEHexSettings,
        openAsHex: Bool,
        openAsText: Bool
    ) -> IDEHexRoute {
        if !openAsHex, !openAsText, ImageContentDetector.isImageFile(url) {
            return .image
        }
        if openAsHex { return .hex(sniffed: false) }
        if openAsText { return .text }
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, settings.forceTextExtensions.contains(ext) { return .text }
        if !ext.isEmpty, settings.forceHexExtensions.contains(ext) { return .hex(sniffed: false) }
        switch BinaryContentDetector.classify(url) {
        case .binary:
            return settings.openBinaryAsHex ? .hex(sniffed: false) : .text
        case .text:
            return .text
        case .unknown:
            guard settings.sniffUnknownFiles, let head else { return .text }
            return BinaryContentDetector.looksBinary(head) ? .hex(sniffed: true) : .text
        }
    }

    /// At most 8 KB. A missing file is an empty head, not an error.
    static func readHead(_ url: URL) -> Data {
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { return Data() }
        defer { Darwin.close(fd) }
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            let result = pread(fd, base, 8 * 1024, 0)
            return result > 0 ? result : 0
        }
        return Data(buffer.prefix(count))
    }
}

extension IDEWorkspace {
    func activeHexSession() -> IDEHexSession? {
        guard let document = workbench.activePane.selectedDocument, document.contentKind == .binary else { return nil }
        return hexSessions[document.id]
    }

    /// Lines for close and quit prompts. A dirty hex tab names the file and how many bytes changed.
    func unsavedChangeLines() -> [String] {
        workbench.allDocuments().filter(\.isDirty).map { document in
            if document.contentKind == .binary {
                let count = hexSessions[document.id]?.changedByteCount ?? 0
                return "\(document.displayName): \(count) changed bytes"
            }
            return "\(document.displayName): unsaved changes"
        }
    }

    func unsavedPromptText() -> String {
        let dirty = workbench.allDocuments().filter(\.isDirty)
        let count = dirty.count
        let head = "\(count) open editor\(count == 1 ? " has" : "s have") unsaved changes that will be lost."
        let hex = unsavedChangeLines().filter { $0.contains("changed bytes") }
        guard !hex.isEmpty else { return head }
        return ([head] + hex).joined(separator: "\n")
    }

    func showHexDocument(_ document: WorkbenchDocument, in pane: EditorPane, host: IDEEditorPaneHost) {
        flushTextLeaving(host, pane: pane, except: document)
        host.diffViewer.hide()
        host.diagramViewer.hide()
        host.imageViewerController.hide()
        host.markdownPreviewController.closeIfNotMarkdown()
        host.hideJSONDiagram()
        host.hideCSVTable()
        guard let session = ensureHexSession(for: document) else {
            host.hexViewer.hide()
            return
        }
        host.hexViewer.show(session)
        host.loadedDocumentID = document.id
        host.loadedGeneration = document.contentGeneration
        if pane.id == workbench.activePaneID {
            statusLanguage = "Hex"
            host.hexViewer.focus()
            syncHexPaletteCommands()
        }
    }

    func hideHexViewer(on host: IDEEditorPaneHost) {
        host.hexViewer.hide()
    }

    @discardableResult
    func saveHexDocument(_ document: WorkbenchDocument, overwriteChanged: Bool = false) async -> Bool {
        guard let session = hexSessions[document.id], let url = document.url else { return false }
        do {
            try await session.save(to: url, overwriteChanged: overwriteChanged)
            session.publish(to: document)
            refreshPresentation()
            return true
        } catch HexWriteError.changedOnDisk {
            let alert = NSAlert()
            alert.messageText = "\(document.displayName) changed on disk"
            alert.informativeText = "The file's size or modification time changed since it was opened."
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            return await saveHexDocument(document, overwriteChanged: true)
        } catch {
            presentError(error)
            return false
        }
    }

    func reopenActiveDocumentAsHex() {
        guard let document = workbench.activePane.selectedDocument else { return }
        Task { await reopenAsHex(document) }
    }

    func reopenActiveDocumentAsText() {
        guard let document = workbench.activePane.selectedDocument else { return }
        Task { await reopenAsText(document) }
    }

    func reopenDocumentAsHex(_ id: UUID) {
        guard let document = workbench.allDocuments().first(where: { $0.id == id }) else { return }
        Task { await reopenAsHex(document) }
    }

    func reopenDocumentAsText(_ id: UUID) {
        guard let document = workbench.allDocuments().first(where: { $0.id == id }) else { return }
        Task { await reopenAsText(document) }
    }

    func toggleHexInsertMode() {
        activeHexSession()?.toggleInsertMode()
        refreshPresentation()
    }

    func toggleHexInspector() {
        guard let session = activeHexSession() else { return }
        session.inspectorVisible.toggle()
        IDEHexSettings.shared.inspectorVisible = session.inspectorVisible
        refreshPresentation()
    }

    func zeroHexSelection() {
        activeHexSession()?.zeroSelection()
    }

    func toggleHexBookmark() {
        guard let document = workbench.activePane.selectedDocument, let session = activeHexSession() else { return }
        session.toggleBookmark()
        session.publish(to: document)
    }

    func compareHexWithDisk() {
        guard let session = activeHexSession() else { return }
        Task { await session.compareWithDisk() }
    }

    func showHexGoToOffset() {
        activeHexSession()?.showsGoToOffset = true
    }

    func showHexFind() {
        guard let session = activeHexSession() else { return }
        session.beginFind()
    }

    /// An external change of an open hex file. Clean sessions refresh in place. Dirty ones ask.
    func noteExternalChange(of paths: [String]) {
        let changed = Set(paths)
        for document in workbench.allDocuments() where document.contentKind == .binary {
            guard let path = document.url?.path, changed.contains(path),
                  let session = hexSessions[document.id] else { continue }
            if session.isModified {
                session.externalChange = true
            } else if (try? session.refreshCleanKeepingViewport()) != nil {
                session.publish(to: document)
            }
        }
        refreshPresentation()
    }

    func reloadHexFromDisk(_ document: WorkbenchDocument) async {
        guard let url = document.url else { return }
        closeHexSession(document.id)
        let loaded = WorkbenchDocument.loadBinary(from: url)
        installReloaded(loaded, onto: document)
        document.contentKind = .binary
        document.contentGeneration &+= 1
        for showing in workbench.panes where showing.selectedDocument === document {
            showDocument(in: showing, host: host(for: showing.id))
        }
        refreshPresentation()
    }

    func reopenAsHex(_ document: WorkbenchDocument) async {
        if document.contentKind == .binary { return }
        if document.isDirty {
            let text = sourceText(for: document)
            let bytes = document.encoding.encode(text) ?? Data(text.utf8)
            let hex = HexDocument.unsaved([UInt8](bytes), changedBytes: Int64(bytes.count))
            adoptHex(hex, for: document, sniffed: false)
            return
        }
        guard let url = document.url else { return }
        let loaded = WorkbenchDocument.loadBinary(from: url)
        installReloaded(loaded, onto: document)
        document.contentKind = .binary
        closeHexSession(document.id)
        document.contentGeneration &+= 1
        showCurrent(document)
    }

    func reopenAsText(_ document: WorkbenchDocument) async {
        if document.contentKind == .text { return }
        if let session = hexSessions[document.id], session.isModified {
            let bytes = session.document.bytes(in: 0..<session.document.count)
            let decoded = decodeHexBytes(bytes, encoding: document.encoding)
            closeHexSession(document.id)
            document.contentKind = .text
            document.text = decoded
            document.isDirty = true
            document.isFileBacked = false
            document.pendingState = TextViewState(text: decoded, theme: IDEEditorTheme.shared.current)
            document.languageIdentifier = document.url.flatMap { LanguageIdentifier.identifier(for: $0) }
            document.contentGeneration &+= 1
            showCurrent(document)
            return
        }
        guard let url = document.url else { return }
        closeHexSession(document.id)
        do {
            let loaded = try await loadDocument(from: url, openAsText: true)
            installReloaded(loaded, onto: document)
            document.contentKind = .text
            document.contentGeneration &+= 1
            showCurrent(document)
        } catch {
            presentError(error)
        }
    }

    func closeHexSession(_ documentID: UUID) {
        guard let session = hexSessions.removeValue(forKey: documentID) else { return }
        for pane in workbench.panes {
            hostCache.peek(pane.id)?.hexViewer.detach(session)
        }
        session.close()
    }

    func closeAllHexSessions() {
        for session in hexSessions.values { session.close() }
        hexSessions.removeAll()
    }

    func syncHexPaletteCommands() {
        guard let palette = paletteController else { return }
        palette.commandRegistry.remove(ids: IDEHexModule.commandIDs)
        palette.commandRegistry.register(IDEHexModule().commands(for: self))
    }

    func ensureHexSession(for document: WorkbenchDocument) -> IDEHexSession? {
        if let existing = hexSessions[document.id] { return existing }
        guard let url = document.url else { return nil }
        guard let source = try? FileByteSource(url: url) else { return nil }
        let identity = try? HexFileIdentity.capture(url: url)
        let hex = HexDocument(source: source, identity: identity)
        let sniffed = hexSniffedPaths.remove(url.path) != nil
        return install(hex, for: document, sniffed: sniffed)
    }

    func confirmMakeHexEditable(_ session: IDEHexSession) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Make this file editable?"
        alert.informativeText = "A save rewrites the whole file. This file is larger than the editing threshold."
        alert.addButton(withTitle: "Make Editable")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        session.makeEditable(confirmed: true)
    }

    private func adoptHex(_ hex: HexDocument, for document: WorkbenchDocument, sniffed: Bool) {
        closeHexSession(document.id)
        document.contentKind = .binary
        document.text = ""
        document.pendingState = nil
        document.isFileBacked = false
        document.isDirty = hex.isModified
        document.language = nil
        _ = install(hex, for: document, sniffed: sniffed)
        document.contentGeneration &+= 1
        showCurrent(document)
    }

    private func install(_ hex: HexDocument, for document: WorkbenchDocument, sniffed: Bool) -> IDEHexSession {
        let location = Int64(document.selectedRange.location)
        let length = Int64(document.selectedRange.length)
        let upper = min(hex.count, location + max(0, length))
        let lower = min(location, hex.count)
        let session = IDEHexSession(
            documentID: document.id,
            document: hex,
            fileURL: document.url,
            openedBySniff: sniffed,
            selection: lower..<max(lower, upper),
            topRow: Int64(document.scrollOffset.y),
            bookmarks: document.hexBookmarks
        )
        wire(session, to: document)
        hexSessions[document.id] = session
        session.publish(to: document)
        return session
    }

    private func wire(_ session: IDEHexSession, to document: WorkbenchDocument) {
        session.onChange = { [weak self, weak document, weak session] in
            guard let self, let document, let session else { return }
            session.publish(to: document)
            self.refreshPresentation()
        }
        session.onReloadFromDisk = { [weak self, weak document] in
            guard let self, let document else { return }
            Task { await self.reloadHexFromDisk(document) }
        }
        session.onOpenAsText = { [weak self, weak document] in
            guard let self, let document else { return }
            Task { await self.reopenAsText(document) }
        }
        session.onCompareWithDisk = { [weak self, weak session] in
            guard let session else { return }
            Task { await session.compareWithDisk() }
            self?.refreshPresentation()
        }
        session.onMakeEditable = { [weak self, weak session] in
            guard let self, let session else { return }
            self.confirmMakeHexEditable(session)
        }
    }

    private func showCurrent(_ document: WorkbenchDocument) {
        for showing in workbench.panes where showing.selectedDocument === document {
            showDocument(in: showing, host: host(for: showing.id))
        }
        refreshPresentation()
        syncHexPaletteCommands()
    }

    private func flushTextLeaving(_ host: IDEEditorPaneHost, pane: EditorPane, except document: WorkbenchDocument) {
        guard let previousID = host.loadedDocumentID, previousID != document.id,
              let previous = pane.documents.first(where: { $0.id == previousID }),
              previous.contentKind == .text else { return }
        syncTextViewToDocument(host.textView, document: previous, from: host)
        previous.pendingState = host.textView.makeCapturedState()
    }

    private func decodeHexBytes(_ bytes: [UInt8], encoding: TextFileEncoding) -> String {
        let data = Data(bytes)
        if let text = encoding.decode(data) { return text }
        let latin1 = TextFileEncoding.all.first { $0.id == "latin1" }
        if let latin1, let text = latin1.decode(data) { return text }
        return String(decoding: bytes, as: UTF8.self)
    }

    func loadTextDocument(
        from url: URL,
        encoding: TextFileEncoding?,
        preferring preferredEncoding: TextFileEncoding?
    ) async throws -> WorkbenchDocument {
        let identifier = LanguageIdentifier.identifier(for: url)
        let language = IDELanguageSupport.language(forIdentifier: identifier, fileURL: url)
        var attempts: [TextFileEncoding?] = [encoding]
        if encoding == nil, let preferredEncoding, preferredEncoding != .utf8 {
            attempts = [preferredEncoding, nil]
        }
        var loaded: WorkbenchDocument?
        for (index, attempt) in attempts.enumerated() {
            do {
                loaded = try await WorkbenchDocument.load(
                    contentsOf: url,
                    theme: IDEEditorTheme.shared.current,
                    lineHeightMultiplier: CGFloat(preferences.lineHeightMultiplier),
                    language: language,
                    languageIdentifier: identifier,
                    languageProvider: Self.languageProvider,
                    encoding: attempt
                )
                break
            } catch DocumentLoadError.invalidEncoding where index < attempts.count - 1 {
                continue
            }
        }
        guard let document = loaded else { throw DocumentLoadError.invalidEncoding }
        document.language = language
        return document
    }
}
