import AppKit
import Penumbra

/// Why a document is being saved. The reason decides what the save may do: only a user's own
/// save may ask a question, and a save made on the way out must be quick and leave the text alone.
enum IDESaveReason: Equatable {
    /// ⌘S (or Save from a menu): the user asked for this one document.
    case explicit
    /// Save All.
    case saveAll
    /// The agent's command runner saving a buffer it just edited around.
    case agent
    /// Typing paused for the idle time (Settings ▸ Saving).
    case autosaveIdle
    /// Umbra stopped being the active app, or the terminal took focus.
    case autosaveFocusLoss
    /// Ahead of a run, build, test or debug launch, so the program sees what is on screen.
    case beforeRun
    /// Ahead of a git operation that reads or rewrites the working tree.
    case beforeGit
    /// A tab is closing.
    case closingTab
    /// A window or folder is closing.
    case closingWindow
    /// The app is quitting.
    case quitting

    /// May ask a question: the overwrite conflict prompt.
    var isInteractive: Bool {
        switch self {
        case .explicit, .saveAll: true
        case .agent, .autosaveIdle, .autosaveFocusLoss, .beforeRun, .beforeGit, .closingTab, .closingWindow, .quitting: false
        }
    }

    /// May show a save panel for an untitled buffer. Save All lists them instead of opening a
    /// panel per buffer.
    var showsSavePanel: Bool { self == .explicit }

    /// Runs the actions on save (optimize imports, …). The agent's own edits are left as written,
    /// and a save on the way out must be quick and leave the text alone.
    var runsSaveActions: Bool {
        switch self {
        case .explicit, .saveAll, .autosaveIdle, .autosaveFocusLoss, .beforeRun, .beforeGit, .closingTab: true
        case .agent, .closingWindow, .quitting: false
        }
    }

    /// A save the user asked for by name, as opposed to one made on their behalf.
    var isUserSave: Bool { self == .explicit || self == .saveAll }
}

enum IDESaveOutcome: Equatable {
    case saved
    /// There was nothing to write.
    case clean
    /// An untitled buffer, which only an explicit save can name.
    case skippedUntitled
    /// The file changed on disk and the save was not allowed to ask; the banner is up.
    case conflict
    case failed(String)
}

/// What a Save All did, by display name.
struct IDESaveAllReport: Equatable {
    var saved = 0
    var untitled: [String] = []
    var conflicts: [String] = []
    var failures: [String] = []

    /// Everything that is still unsaved because the save could not or may not write it.
    var remaining: [String] { untitled + conflicts + failures }
    var isComplete: Bool { remaining.isEmpty }
}

extension IDEWorkspace {
    /// The pane showing `document` in a loaded editor, active pane first. A document that only sits
    /// in a background tab has no live editor: its text is `pendingState`.
    func livePane(for document: WorkbenchDocument) -> (pane: EditorPane, host: IDEEditorPaneHost)? {
        let panes = workbench.panes
        let ordered = panes.filter { $0.id == workbench.activePaneID } + panes.filter { $0.id != workbench.activePaneID }
        for pane in ordered {
            if let host = hostCache.peek(pane.id), host.loadedDocumentID == document.id {
                return (pane, host)
            }
        }
        return nil
    }

    /// Saves one document. Every save goes through here: ⌘S, Save All, the agent's buffers.
    ///
    /// A document in a background tab is written from its captured state, without the actions on
    /// save, which need a live editor.
    @discardableResult
    func saveDocument(_ document: WorkbenchDocument, reason: IDESaveReason) async -> IDESaveOutcome {
        switch document.contentKind {
        case .diff:
            guard reason.isUserSave, let session = diffSessions[document.id], session.isRightDirty else { return .clean }
            session.save()
            return .saved
        case .binary:
            guard document.isDirty || reason == .explicit else { return .clean }
            return await saveHex(document, interactive: reason.isInteractive)
        case .text:
            break
        case .image, .diagram, .profile:
            return .clean
        }
        // An explicit save writes a clean buffer too (it records history and runs the actions);
        // the others only have something to do for a buffer with changes.
        guard document.isDirty || reason == .explicit else { return .clean }

        var destination = document.url
        if destination == nil {
            guard reason.showsSavePanel else { return .skippedUntitled }
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = document.displayName
            guard panel.runModal() == .OK, let url = panel.url else { return .clean }
            destination = url
        }
        guard let destination else { return .clean }
        return await write(document, to: destination, reason: reason)
    }

    /// Writes `document` to `destination`: its own file, or a new one for Save As.
    func write(_ document: WorkbenchDocument, to destination: URL, reason: IDESaveReason) async -> IDESaveOutcome {
        let live = livePane(for: document)
        if destination == document.url, !(await confirmOverwriteIfDiskChanged(document, interactive: reason.isInteractive)) {
            return reason.isInteractive ? .clean : .conflict
        }
        if reason.runsSaveActions, let live, document.contentKind == .text {
            await runActionsOnSave(for: document, at: destination, host: live.host)
        }
        // `document.save` rewrites the language from the file name; an unattended save must not
        // undo a syntax the user picked by hand.
        let urlBefore = document.url
        let languageBefore = document.languageIdentifier
        do {
            _ = try await document.save(from: live?.host.textView, to: destination)
        } catch {
            if reason.isInteractive { presentError(error) }
            return .failed(error.localizedDescription)
        }
        if !reason.isUserSave, urlBefore == destination, document.languageIdentifier != languageBefore {
            document.languageIdentifier = languageBefore
        }
        finishSave(of: document, at: destination, live: live, languageIsStable: !reason.isUserSave && urlBefore == destination)
        if reason.isUserSave { scheduleBuildAfterSave() }
        return .saved
    }

    /// What follows every write: history, recents, git, blame, the language services.
    private func finishSave(
        of document: WorkbenchDocument,
        at url: URL,
        live: (pane: EditorPane, host: IDEEditorPaneHost)?,
        languageIsStable: Bool
    ) {
        localHistory.recordSaved(url)
        if let live {
            if !languageIsStable {
                applyLanguageInferredFromURL(url, document: document, in: live.pane)
            }
            refreshBlame(in: live.pane, force: true)
        }
        recordRecentFile(url)
        gitStatus.refresh()
        refreshPresentation()
        noteDocumentSaved(url)
    }

    /// Saves every document with unsaved changes, once each even when several panes show it.
    func saveAll(reason: IDESaveReason = .saveAll) async -> IDESaveAllReport {
        var report = IDESaveAllReport()
        for document in workbench.allDocuments() where document.isDirty {
            // The document may have been closed or saved while an earlier one was being written.
            guard document.isDirty else { continue }
            switch await saveDocument(document, reason: reason) {
            case .saved: report.saved += 1
            case .clean: break
            case .skippedUntitled: report.untitled.append(document.displayName)
            case .conflict: report.conflicts.append(document.displayName)
            case .failed: report.failures.append(document.displayName)
            }
        }
        return report
    }

    /// File ▸ Save All. Says what it could not save, since a silent partial save looks like success.
    ///
    /// `namingActive` is for a keymap that puts Save on ⌘S as Save All (IntelliJ's): the active
    /// buffer, when untitled, gets the save panel first, so ⌘S still names a new file.
    func saveAllDocuments(namingActive: Bool = false) async {
        if namingActive, let document = workbench.activePane.selectedDocument, document.url == nil {
            await saveDocument(document, reason: .explicit)
        }
        let report = await saveAll(reason: .saveAll)
        guard !report.isComplete else { return }
        var lines: [String] = []
        if !report.untitled.isEmpty { lines.append("Not named yet: \(report.untitled.joined(separator: ", "))") }
        if !report.conflicts.isEmpty { lines.append("Changed on disk: \(report.conflicts.joined(separator: ", "))") }
        if !report.failures.isEmpty { lines.append("Could not be written: \(report.failures.joined(separator: ", "))") }
        let saved = report.saved == 0 ? "Nothing was saved" : "Saved \(report.saved) file\(report.saved == 1 ? "" : "s")"
        notifications.post(saved, detail: lines.joined(separator: "\n"), severity: .warning)
    }

    // MARK: Autosave

    /// Whether a save made on its own may go ahead now: not while an input method holds
    /// uncommitted text, a snippet is being filled in, or a sheet or alert is in front.
    var canAutosaveNow: Bool {
        if let window {
            if window.attachedSheet != nil { return false }
            if NSApp.modalWindow != nil { return false }
        }
        for pane in workbench.panes {
            guard let host = hostCache.peek(pane.id) else { continue }
            if host.textView.isComposingText || host.textView.hasActiveSnippetSession { return false }
        }
        return true
    }

    /// Saves every unsaved file for the idle and focus-loss triggers. It never asks: a file that
    /// changed on disk raises its banner, an untitled buffer waits for a name, and a write that
    /// fails is reported once until it succeeds.
    func autosaveAll(reason: IDESaveReason) async {
        guard hasUnsavedDocuments else { return }
        let report = await saveAll(reason: reason)
        let fresh = report.failures.filter { !autosaveReportedFailures.contains($0) }
        autosaveReportedFailures = Set(report.failures)
        guard !fresh.isEmpty else { return }
        notifications.post(
            "Couldn't save \(fresh.joined(separator: ", "))",
            detail: "Autosave could not write the file. Use Save to see why.",
            severity: .warning
        )
    }

    /// Umbra lost the focus, or the terminal took it.
    func autosaveBecauseFocusMoved() {
        guard preferences.saveOnFocusLoss, hasUnsavedDocuments else { return }
        Task { @MainActor [self] in
            await autosaveAll(reason: .autosaveFocusLoss)
        }
    }

    // MARK: Before something reads the files

    /// Whether any open buffer has unsaved changes.
    var hasUnsavedDocuments: Bool {
        workbench.allDocuments().contains(where: \.isDirty)
    }

    /// Saves every unsaved buffer ahead of a run, build, test or debug launch, so the program sees
    /// what is on screen. It never stops the launch: a file that cannot be written (changed on disk,
    /// read-only) is named in a notification and the launch goes on with what is on disk.
    func saveAllBeforeRun() async {
        guard hasUnsavedDocuments else { return }
        let report = await saveAll(reason: .beforeRun)
        guard !report.remaining.filter({ !report.untitled.contains($0) }).isEmpty else { return }
        notifications.post(
            "Ran without saving some files",
            detail: (report.conflicts + report.failures).joined(separator: ", "),
            severity: .warning
        )
    }

    /// Runs `action` once the unsaved buffers are on disk: at once when there is nothing to save,
    /// so a launch with no edits keeps its timing.
    func afterSavingUnsaved(_ action: @escaping @MainActor () -> Void) {
        guard hasUnsavedDocuments else {
            action()
            return
        }
        Task { @MainActor in
            await saveAllBeforeRun()
            action()
        }
    }

    // MARK: Unsaved markers

    /// Brings the Explorer's dots and the window's edited state in step with the open buffers.
    /// Runs when a document's dirty flag flips and on every presentation refresh, never per
    /// keystroke.
    func updateUnsavedMarkers() {
        let dirty = workbench.allDocuments().filter(\.isDirty)
        let paths = Set(dirty.compactMap { $0.url?.standardizedFileURL.path })
        if paths != unsavedPaths { unsavedPaths = paths }
        let edited = !dirty.isEmpty && preferences.markModifiedTabs
        if let window, window.isDocumentEdited != edited { window.isDocumentEdited = edited }
    }

    // MARK: Reload

    /// File ▸ Reload from Disk: the active tab, asking first when it has unsaved edits.
    func reloadActiveFromDisk() {
        let pane = workbench.activePane
        guard let document = pane.selectedDocument else { return }
        reloadTabFromDisk(document.id, in: pane.id)
    }

    /// File ▸ Reload All from Disk: every open file that differs from what its buffer was loaded
    /// from. A clean tab reloads whatever the External Changes policy is; one with unsaved edits
    /// gets the banner instead, since reloading would drop them.
    func reloadAllFromDisk() async {
        var reloaded = 0
        for document in workbench.allDocuments() where document.contentKind == .text {
            guard let url = document.url else { continue }
            let path = url.standardizedFileURL.path
            // A deleted file is the banner's business (Close Tab · Keep Editing).
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard await diskSync.diskChangedSinceLoad(path: path, honoringKeepMine: document.isDirty) else { continue }
            if document.isDirty {
                diskSync.noteConflict(path: path)
            } else if (try? await reloadDocumentFromDisk(document)) != nil {
                reloaded += 1
            }
        }
        if reloaded > 0 {
            notifications.post("Reloaded \(reloaded) file\(reloaded == 1 ? "" : "s") from disk", severity: .info)
        }
    }
}
