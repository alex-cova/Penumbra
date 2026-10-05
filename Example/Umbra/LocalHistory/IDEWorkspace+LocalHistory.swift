import AgentKit
import AppKit
import EditorIntelligence
import Foundation

/// What the History tab is showing.
enum IDELocalHistoryScope: Equatable, Hashable {
    /// The active editor, or `localHistoryFile` when one is pinned.
    case file
    /// Every revision under this project-relative folder.
    case folder(String)
    /// Recent changes across the project.
    case project
}

/// What a revision is compared with.
enum IDELocalHistoryComparison {
    /// The file as it is now.
    case current
    /// The revision before it: what this change did.
    case previous
}

extension IDEWorkspace {
    // MARK: - Showing

    /// Opens the History tab on the active file, or on every file's recent changes.
    func showLocalHistory(project: Bool = false) {
        localHistoryFile = nil
        localHistoryScope = project ? .project : .file
        showSidebarTab(.history)
    }

    /// Opens the History tab on one project file, or on a folder's revisions.
    func showLocalHistory(for url: URL) {
        guard let path = localHistory.relativePath(of: url) else { return }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            localHistoryFile = nil
            localHistoryScope = .folder(path)
        } else {
            localHistoryFile = path
            localHistoryScope = .file
        }
        showSidebarTab(.history)
    }

    /// "Local History" in the editor's right-click menu: this file's history, or a label for this version.
    func localHistoryContextMenuItems(url: URL?) -> [NSMenuItem] {
        guard hasOpenProject, let url, localHistory.relativePath(of: url) != nil, localHistory.store != nil else { return [] }
        let submenu = NSMenu(title: "Local History")
        submenu.addItem(IDEClosureMenuItem(title: "Show History") { [weak self] in self?.showLocalHistory() })
        submenu.addItem(IDEClosureMenuItem(title: "Recent Changes") { [weak self] in self?.showLocalHistory(project: true) })
        submenu.addItem(.separator())
        submenu.addItem(IDEClosureMenuItem(title: "Put Label…") { [weak self] in self?.putLocalHistoryLabel() })
        let item = NSMenuItem(title: "Local History", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return [item]
    }

    /// An applier that notes in Local History every closed file it rewrites, as one action named `name`.
    /// Files open in an editor change in their buffer and are recorded when saved.
    func historyRecordingApplier(named name: String) -> IDEWorkspaceEditApplier {
        let group = UUID()
        var applier = IDEWorkspaceEditApplier(host: self)
        applier.onDiskRewrite = { [weak self] url, before, after in
            guard let self, let path = self.localHistory.relativePath(of: url) else { return }
            self.localHistory.record(path: path, text: after, source: .refactor(name), group: group, before: before)
        }
        return applier
    }

    // MARK: - Comparing

    /// Opens the revision against the file as it is now, or against the revision before it, in the diff viewer.
    func localHistoryOpenDiff(_ event: IDELocalHistoryEvent, against comparison: IDELocalHistoryComparison) {
        guard let store = localHistory.store, let root = project.rootURL else { return }
        let url = root.appendingPathComponent(event.path).standardizedFileURL
        let time = IDELocalHistoryPresentation.time(event.time)
        Task { @MainActor in
            switch comparison {
            case .current:
                guard let text = await store.text(of: event) else { return presentLocalHistoryUnavailable() }
                openDiff(IDEDiffRequest(
                    left: IDEDiffSide(source: .text(text), title: "Revision of \(time)"),
                    right: IDEDiffSide(source: .workingTree(path: url.path), title: "Now"),
                    filePath: url.path, title: "\(url.lastPathComponent) (history)"))
            case .previous:
                guard let after = await store.text(of: event) ?? (event.after == nil ? "" : nil) else { return presentLocalHistoryUnavailable() }
                let before = event.before == nil ? "" : await store.text(of: event, before: true)
                guard let before else { return presentLocalHistoryUnavailable() }
                openDiff(IDEDiffRequest(
                    left: IDEDiffSide(source: .text(before), title: event.before == nil ? "Before (new file)" : "Before"),
                    right: IDEDiffSide(source: .text(after), title: "Revision of \(time)"),
                    filePath: url.path, title: "\(url.lastPathComponent) (change)"))
            }
        }
    }

    /// Puts the revision's text on the clipboard. A missing blob is reported; a deleted file has nothing to copy.
    func localHistoryCopy(_ event: IDELocalHistoryEvent) {
        guard event.after != nil, let store = localHistory.store else { return }
        Task { @MainActor in
            guard let text = await store.text(of: event) else { return presentLocalHistoryUnavailable() }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func presentLocalHistoryUnavailable() {
        notifications.post(
            "That revision is no longer stored",
            detail: "Local History keeps revisions for a limited time; older ones are removed.", severity: .warning)
    }

    // MARK: - Restoring

    /// Puts a file back to `text` (`nil`: deletes it), through the editor so an open file changes in its
    /// buffer as one undo step, and notes it in the history as a revert. Returns whether it worked.
    @discardableResult
    func localHistoryRestore(path: String, to text: String?) async -> Bool {
        guard let root = project.rootURL else { return false }
        let url = root.appendingPathComponent(path).standardizedFileURL
        let applier = IDEWorkspaceEditApplier(host: self)
        let failure: String?
        if let text {
            if let current = openBufferText(for: url) ?? (try? String(contentsOf: url, encoding: .utf8)) {
                if current == text { return true }
                let edit = AgentTextEdit(location: 0, length: (current as NSString).length, replacement: text)
                guard let textEdits = try? IDEAgentEditTranslator.textEdits([edit], in: current) else { return false }
                failure = await applier.apply(WorkspaceEdit(changes: [url: textEdits])).failures[url]
            } else {
                failure = await applier.apply(WorkspaceEdit(fileCreations: [(url, text)])).failures[url]
            }
        } else {
            failure = await applier.apply(WorkspaceEdit(fileDeletions: [url])).failures[url]
        }
        guard failure == nil else { return false }
        localHistory.record(path: path, text: text, source: .revert)
        return true
    }

    /// Restores a file to how it was after this revision.
    @discardableResult
    func localHistoryRevert(toRevision event: IDELocalHistoryEvent) async -> Bool {
        guard let store = localHistory.store else { return false }
        if event.after == nil { return await localHistoryRestore(path: event.path, to: nil) }
        guard let text = await store.text(of: event) else { presentLocalHistoryUnavailable(); return false }
        return await localHistoryRestore(path: event.path, to: text)
    }

    /// Undoes one change: the file goes back to how it was just before it.
    @discardableResult
    func localHistoryUndo(_ event: IDELocalHistoryEvent) async -> Bool {
        guard let store = localHistory.store else { return false }
        guard event.before != nil else { return await localHistoryRestore(path: event.path, to: nil) }
        guard let text = await store.text(of: event, before: true) else { presentLocalHistoryUnavailable(); return false }
        return await localHistoryRestore(path: event.path, to: text)
    }

    /// Undoes everything one action did, newest change first so a file changed twice ends as it began.
    /// Returns how many files were put back.
    @discardableResult
    func localHistoryUndo(group: IDELocalHistoryPresentation.Group) async -> Int {
        var restored = 0
        for event in group.events where await localHistoryUndo(event) { restored += 1 }
        return restored
    }

    // MARK: - Labels

    /// Names the active file's current text so it can be found, and is kept past the usual age.
    func putLocalHistoryLabel() {
        guard let url = workbench.activePane.selectedDocument?.url, localHistory.relativePath(of: url) != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Put Label"
        alert.informativeText = "Name this version of \(url.lastPathComponent). It stays in Local History after older revisions are removed."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Before the big refactor"
        alert.accessoryView = field
        alert.addButton(withTitle: "Put Label")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let text = openBufferText(for: url) ?? (try? String(contentsOf: url, encoding: .utf8)) else { return }
        localHistory.putLabel(name, for: url, text: text)
    }
}
