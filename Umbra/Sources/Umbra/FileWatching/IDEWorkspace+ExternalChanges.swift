import AppKit
import Penumbra

/// Open text buffers and their files on disk: the reload primitive every reload goes through, the
/// banner's actions, and the check before a save writes over a newer file. Changes arrive from the
/// window's one watcher (`IDEProjectWatcher`) through ``IDEOpenDocumentDiskSync``.
extension IDEWorkspace {
    /// What the save-conflict alert answered.
    enum SaveConflictChoice {
        case cancel
        case overwrite
        case compare
    }

    func configureDiskSync() {
        diskSync.policy = { [weak self] in self?.preferences.externalChangePolicy ?? .always }
        diskSync.isDirty = { [weak self] path in self?.openTextDocument(atPath: path)?.isDirty }
        diskSync.reload = { [weak self] path in
            guard let self, let document = self.openTextDocument(atPath: path) else { return }
            try? await self.reloadDocumentFromDisk(document)
        }
        diskSync.notify = { [weak self] path, deleted in
            let name = (path as NSString).lastPathComponent
            self?.notifications.post(
                deleted ? "\(name) was deleted on disk" : "\(name) changed on disk",
                detail: deleted
                    ? "The tab keeps its text. Saving recreates the file."
                    : "Umbra did not reload it (Settings ▸ Editor ▸ External Changes). Right-click its tab and choose Reload from Disk to see the new text.",
                category: .general,
                severity: .warning,
                action: .openFile(path)
            )
        }
    }

    /// The open text document for a standardized path.
    func openTextDocument(atPath path: String) -> WorkbenchDocument? {
        workbench.allDocuments().first {
            $0.contentKind == .text && $0.url?.standardizedFileURL.path == path
        }
    }

    /// Tells the watcher and the sync which files are open. Called whenever the tabs change.
    func syncOpenFileRegistrations(openPaths: Set<String>) {
        projectWatcher.setOpenFiles(openPaths)
        let textPaths = Set(workbench.allDocuments().compactMap { document -> String? in
            guard document.contentKind == .text else { return nil }
            return document.url?.standardizedFileURL.path
        })
        diskSync.setOpenFiles(textPaths)
    }

    /// Replaces a text document's buffer with its file, in every pane showing it, keeping each
    /// pane's caret and scroll position. Every reload goes through here: an external change, git,
    /// Reload from Disk and Reopen with Encoding.
    func reloadDocumentFromDisk(_ document: WorkbenchDocument, encoding: TextFileEncoding? = nil) async throws {
        guard document.contentKind == .text, let url = document.url else { return }
        let showing = workbench.panes.filter { $0.selectedDocument === document }
        // A file-backed buffer's state is consumed by the pane that applies it, so each showing
        // pane gets its own load. Generation is bumped once so splits agree.
        var bumped = false
        for pane in showing.isEmpty ? [nil] : showing.map(Optional.some) {
            let loaded = try await loadDocument(from: url, encoding: encoding, preferring: document.encoding)
            guard isOpen(document) else { return }
            installReloaded(loaded, onto: document)
            if !bumped {
                document.contentGeneration &+= 1
                bumped = true
            }
            if let pane { showDocument(in: pane, host: host(for: pane.id)) }
        }
        if workbench.activePane.selectedDocument === document { statusEncoding = document.encoding }
        diskSync.noteReloaded(path: url.standardizedFileURL.path)
        refreshPresentation()
    }

    private func isOpen(_ document: WorkbenchDocument) -> Bool {
        workbench.panes.contains { $0.documents.contains { $0 === document } }
    }

    // MARK: Banner

    func externalChangeState(of document: WorkbenchDocument?) -> IDEExternalChangeState {
        guard let document, document.contentKind == .text else { return .none }
        return diskSync.state(for: document.url?.standardizedFileURL.path)
    }

    /// Reload: the disk wins, unsaved edits are dropped (the user chose it on the banner).
    func reloadFromBanner(_ document: WorkbenchDocument) {
        Task {
            do {
                try await reloadDocumentFromDisk(document)
            } catch {
                presentError(error)
            }
        }
    }

    func keepMineFromBanner(_ document: WorkbenchDocument) {
        guard let path = document.url?.standardizedFileURL.path else { return }
        diskSync.keepMine(path: path)
    }

    /// Keep Editing a deleted file: the buffer becomes unsaved, so a save recreates the file.
    func keepEditingDeleted(_ document: WorkbenchDocument) {
        guard let path = document.url?.standardizedFileURL.path else { return }
        document.isDirty = true
        diskSync.dismissDeleted(path: path)
        refreshPresentation()
    }

    func closeDeleted(_ document: WorkbenchDocument) {
        for pane in workbench.panes where pane.documents.contains(where: { $0 === document }) {
            closeTab(document.id, in: pane.id)
        }
    }

    /// The file on disk on the left, the buffer (with its unsaved edits) on the right.
    func compareWithDisk(_ document: WorkbenchDocument) {
        guard let url = document.url else { return }
        let path = url.standardizedFileURL.path
        let encoding = document.encoding
        Task {
            let disk = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return encoding.decode(data) ?? String(decoding: data, as: UTF8.self)
            }.value
            openDiff(IDEDiffRequest(
                left: IDEDiffSide(source: .text(disk ?? ""), title: "On Disk"),
                right: IDEDiffSide(source: .workingTree(path: path), title: "Yours"),
                filePath: path,
                title: "\(document.displayName) (Disk ↔ Yours)"
            ))
        }
    }

    // MARK: Save conflict

    /// Whether a save of `document` to its own file may go ahead. When the file changed on disk
    /// since the buffer was loaded, asks: Overwrite, Cancel or Compare. `interactive: false` (the
    /// agent's saves) never asks: it refuses and raises the banner instead.
    func confirmOverwriteIfDiskChanged(_ document: WorkbenchDocument, interactive: Bool = true) async -> Bool {
        guard document.contentKind == .text, let url = document.url else { return true }
        let path = url.standardizedFileURL.path
        guard await diskSync.diskChangedSinceLoad(path: path) else { return true }
        guard interactive else {
            diskSync.noteConflict(path: path)
            return false
        }
        switch saveConflictResolver(document) {
        case .overwrite:
            return true
        case .cancel:
            return false
        case .compare:
            compareWithDisk(document)
            return false
        }
    }

    /// The diff viewer's version of the question: it already shows the file, so no Compare.
    static func askToOverwriteChangedFile(named name: String) -> Bool {
        var alert = IDEAlert.confirm(
            "\(name) changed on disk since the diff loaded it.",
            detail: "Saving replaces the version on disk with the text in the diff.",
            confirm: "Overwrite", isDestructive: true)
        return alert.confirms()
    }

    static func askAboutSaveConflict(_ document: WorkbenchDocument) -> SaveConflictChoice {
        // Cancel first, so it is the default answer to Return.
        var alert = IDEAlert.choice(
            "\(document.displayName) changed on disk since you opened it.",
            detail: "Saving replaces the version on disk with yours. Compare to see what changed.",
            buttons: [.init(title: "Cancel"), .init(title: "Overwrite", isDestructive: true), .init(title: "Compare")])
        switch alert.runModal() {
        case 1: return .overwrite
        case 2: return .compare
        default: return .cancel
        }
    }
}
