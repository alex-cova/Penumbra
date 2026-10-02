import AppKit
import GitIntelligence
import Penumbra

/// Diff tabs: opening them from the Changes list, History, the Git menu and the editor's context
/// menu, and what their sessions need from the workspace (file contents, git, saving).
extension IDEWorkspace {
    // MARK: - Opening

    /// Opens `request` in a diff tab, or selects the tab already showing it. `siblings` are the
    /// files Previous/Next File step through.
    func openDiff(_ request: IDEDiffRequest, siblings: [IDEDiffRequest] = []) {
        for pane in workbench.panes {
            for document in pane.documents where document.contentKind == .diff {
                if diffSessions[document.id]?.request.id == request.id {
                    selectTab(document.id, in: pane.id)
                    return
                }
            }
        }
        let document = WorkbenchDocument(displayName: request.title)
        document.contentKind = .diff
        diffSessions[document.id] = makeDiffSession(request, siblings: siblings, documentID: document.id)
        presentDiffDocument(document)
    }

    /// A row of the Changes list: index ↔ working tree when unstaged, HEAD ↔ index when staged.
    /// Previous/Next File walk the rows of the same section.
    func openChangeDiff(path: String, staged: Bool) {
        let section = gitStatus.changes.filter { staged ? $0.staged != nil : $0.unstaged != nil }
        let requests = section.map { change in
            IDEDiffRequest.change(
                path: change.path,
                relativePath: change.relativePath,
                staged: staged,
                isNew: staged ? change.staged == .added : change.unstaged == .untracked
            )
        }
        guard let request = requests.first(where: { $0.filePath == path }) else { return }
        openDiff(request, siblings: requests)
    }

    /// One file of a commit against its parent, with the commit's other files as siblings.
    func openCommitDiff(hash: String, shortHash: String, file: GitChangedFile, files: [GitChangedFile]) {
        guard let root = gitStatus.repositoryRootPath else { return }
        func request(_ file: GitChangedFile) -> IDEDiffRequest {
            IDEDiffRequest.commitFile(hash: hash, shortHash: shortHash, path: file.path, oldPath: file.oldPath, repositoryRoot: root)
        }
        openDiff(request(file), siblings: files.map(request))
    }

    /// The active file against HEAD, a branch or a tag.
    func openWorkingTreeDiff(against revision: GitRevision, title: String) {
        guard let url = activeFileForDiff, let relative = gitStatus.repositoryRelativePath(for: url.path) else {
            showGitNotice("No Diff", "The active file is not in a git repository.")
            return
        }
        openDiff(.workingTree(path: url.path, relativePath: relative, against: revision, revisionTitle: title))
    }

    /// Compare with Clipboard: the clipboard on the left, the active file (or buffer) on the right.
    func compareActiveFileWithClipboard() {
        guard let clipboard = NSPasteboard.general.string(forType: .string) else {
            showGitNotice("Clipboard Is Empty", "Copy some text to compare it with the file.")
            return
        }
        let pane = workbench.activePane
        guard let document = pane.selectedDocument, document.contentKind == .text else { return }
        let path = document.url?.standardizedFileURL.path
        let text = path == nil ? host(for: pane.id).textView.text : nil
        openDiff(.clipboard(clipboard, path: path, text: text, name: document.displayName))
    }

    /// Editor context-menu items: Compare with Clipboard, and for a file in the repository its
    /// diff with HEAD.
    func diffContextMenuItems(url: URL?) -> [NSMenuItem] {
        var items: [NSMenuItem] = [.separator()]
        if let url, gitStatus.repositoryRelativePath(for: url.standardizedFileURL.path) != nil {
            items.append(IDEClosureMenuItem(title: "Show Diff with HEAD") { [weak self] in
                self?.openWorkingTreeDiff(against: .head, title: "HEAD")
            })
        }
        items.append(IDEClosureMenuItem(title: "Compare with Clipboard") { [weak self] in
            self?.compareActiveFileWithClipboard()
        })
        return items
    }

    private var activeFileForDiff: URL? {
        guard let document = workbench.activePane.selectedDocument, document.contentKind == .text else { return nil }
        return document.url?.standardizedFileURL
    }

    // MARK: - Sessions

    private func makeDiffSession(_ request: IDEDiffRequest, siblings: [IDEDiffRequest], documentID: UUID) -> IDEDiffSession {
        let session = IDEDiffSession(request: request, siblings: siblings)
        session.loadContent = { [weak self] source in
            guard let self else { return .failed("The window was closed.") }
            if case .workingTree(let path) = source, let live = self.unsavedEditorText(atPath: path) {
                return .text(live)
            }
            return await self.gitStatus.diffContent(source)
        }
        session.readOnlyReasonProvider = { [weak self] path in
            self?.unsavedEditorText(atPath: path) == nil ? nil : "Unsaved changes in the editor tab: save them to edit here"
        }
        session.applyIndexPatch = { [weak self] patch, reverse in
            await self?.gitStatus.applyHunk(patch, reverse: reverse) ?? "The window was closed."
        }
        session.onSaved = { [weak self] _ in
            // Clean editor tabs of the file pick up the new text; git sees the change.
            self?.gitStatus.onWorkingTreeChanged?()
            self?.gitStatus.refresh()
        }
        session.onRequestChanged = { [weak self, weak session] in
            guard let self, let session else { return }
            self.workbench.allDocuments().first { $0.id == documentID }?.displayName = session.request.title
            self.refreshTabPresentation()
        }
        return session
    }

    /// The live text of an open editor holding unsaved changes to `path`, else nil (the disk is current).
    private func unsavedEditorText(atPath path: String) -> String? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard workbench.allDocuments().contains(where: {
            $0.contentKind == .text && $0.isDirty && $0.url?.standardizedFileURL.path == standardized
        }) else { return nil }
        return openBufferText(for: URL(fileURLWithPath: standardized))
    }

    /// After git or the disk changed (a save, a stage, a pull), every diff tab reloads; one whose
    /// texts did not change keeps its scroll position and caret.
    func reloadDiffSessions() {
        for session in diffSessions.values where !session.isRightDirty {
            session.reload()
        }
    }

    func closeDiffSession(_ documentID: UUID, in pane: EditorPane) {
        guard let session = diffSessions.removeValue(forKey: documentID) else { return }
        hostCache.peek(pane.id)?.diffViewer.detach(session)
        session.save()
        session.cancel()
    }

    func closeAllDiffSessions() {
        for session in diffSessions.values {
            session.save()
            session.cancel()
        }
        diffSessions.removeAll()
    }

    /// Jump to Source: the file at a 0-based line.
    func openDiffSource(path: String, line: Int) {
        let url = URL(fileURLWithPath: path)
        let text = openBufferText(for: url) ?? (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = IDEDiffText(text)
        let location = lines.lines[min(max(line, 0), lines.lineCount - 1)].location
        Task { await openDocument(from: url, selecting: NSRange(location: location, length: 0)) }
    }
}
