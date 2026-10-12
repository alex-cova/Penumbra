import Foundation
import GitIntelligence
import Penumbra

/// Merge, rebase and the commands that resolve, continue, skip and abort one in progress.
extension IDEGitStatusModel {
    var operation: GitOperationState? { repositoryState.operation }

    var operationPresentation: IDEGitOperationPresentation? {
        operation.map { IDEGitOperationPresentation(operation: $0, currentBranch: currentBranch ?? repositoryState.branchName) }
    }

    /// Files with unresolved conflicts, from the last status.
    var conflictedChanges: [IDEGitChange] {
        changes.filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
    }

    // MARK: - Start

    func merge(_ branch: String, noFastForward: Bool = false) {
        guard !refuseUnsaved(before: "merging") else { return }
        runIntegration("Merge", failureHint: { [weak self] message in
            self?.offerStashAndRepeat(message: message, what: "merge \(branch)") {
                self?.mergeKeepingChanges(branch, noFastForward: noFastForward)
            }
        }) { repo in
            try await repo.merge(branch, noFastForward: noFastForward)
        }
    }

    private func mergeKeepingChanges(_ branch: String, noFastForward: Bool) {
        runGitAction({ repo in
            let (report, outcome) = try await repo.preservingLocalChanges {
                try await repo.merge(branch, noFastForward: noFastForward).report
            }
            switch outcome {
            case .completed: return report
            case .restoredWithConflicts: return "Merged \(branch); your local changes conflict (see Changes)"
            case .keptInStash: return "Merged \(branch); your local changes are kept in the stash"
            }
        }, onSuccess: { [weak self] in
            self?.onWorkingTreeChanged?()
            self?.loadStashes()
        })
    }

    /// Rebases the current branch onto `upstream`, saving uncommitted changes around it (`--autostash`).
    func rebase(onto upstream: String) {
        guard !refuseUnsaved(before: "rebasing") else { return }
        runIntegration("Rebase", failureHint: nil) { repo in
            try await repo.rebase(onto: upstream)
        }
    }

    // MARK: - Finish

    /// Continue: a merge asks for its message first, the others go on with git's.
    func requestContinue() {
        guard let operation else { return }
        guard operation.kind == .merge else {
            continueOperation(message: nil)
            return
        }
        sheets.present(.textPrompt(IDEGitTextPrompt(
            title: "Commit Merge",
            message: "The message for the merge commit.",
            placeholder: "Merge message",
            initial: operation.message?.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "",
            confirmTitle: "Commit",
            action: { [weak self] message in self?.continueOperation(message: message) }
        )))
    }

    func continueOperation(message: String?) {
        guard let kind = operation?.kind else { return }
        guard conflictedChanges.isEmpty else {
            fail("Resolve the \(conflictedChanges.count) conflicted \(conflictedChanges.count == 1 ? "file" : "files") first.")
            return
        }
        runIntegration("Continue", failureHint: nil) { repo in
            try await repo.continueOperation(kind, message: message)
        }
    }

    func skipOperation() {
        guard let kind = operation?.kind else { return }
        runIntegration("Skip", failureHint: nil) { repo in
            try await repo.skipOperation(kind)
        }
    }

    func requestAbort() {
        guard let presentation = operationPresentation, let kind = operation?.kind else { return }
        sheets.present(.confirm(IDEGitConfirmation(
            title: "Abort?",
            message: "\(presentation.title) will be abandoned and the branch goes back to how it was. Conflict resolutions made so far are lost.",
            confirmTitle: "Abort",
            isDestructive: true,
            action: { [weak self] in
                self?.runGitAction({ repo in
                    _ = try await repo.abortOperation(kind)
                    return "\(presentation.badge) aborted"
                }, onSuccess: { self?.onWorkingTreeChanged?() }, onFailure: { _ in self?.onWorkingTreeChanged?() })
            }
        )))
    }

    // MARK: - Conflicts

    /// Resolves `paths` (absolute) to one side and stages them, without opening them.
    func resolve(paths: [String], taking side: GitConflictSide) {
        let relative = paths.compactMap { repositoryRelativePath(for: $0) }
        guard !relative.isEmpty else { return }
        runGitAction({ repo in
            try await repo.resolve(paths: relative, taking: side)
            let name = side == .ours ? "yours" : "theirs"
            return relative.count == 1 ? "Took \(name) for \(relative[0])" : "Took \(name) for \(relative.count) files"
        }, onSuccess: { [weak self] in self?.onWorkingTreeChanged?() })
    }

    /// The merge tool's Apply: writes `contents` and stages the file. Returns git's complaint, or nil.
    func resolveConflict(relativePath: String, contents: Data) async -> String? {
        guard let rootURL else { return "This folder is not a git repository." }
        do {
            let repo = try await IDEGitSupport.repository(for: rootURL, existing: repository)
            try await repo.resolve(path: relativePath, with: contents)
            noteRefsChanged()
            refresh()
            onWorkingTreeChanged?()
            return nil
        } catch {
            return IDEGitSupport.describe(error)
        }
    }

    // MARK: - Plumbing

    /// Runs a merge, rebase, continue or skip. A stop (conflicts) is reported, not failed, and the
    /// banner takes over from the refresh that follows.
    private func runIntegration(
        _ name: String,
        failureHint: (@MainActor (String) -> Void)?,
        _ operation: @escaping @Sendable (GitRepository) async throws -> GitIntegrationResult
    ) {
        runGitAction({ repo in
            let result = try await operation(repo)
            switch result {
            case .completed(let report):
                let line = IDEGitSupport.statusLine(report)
                return line.isEmpty ? "\(name) finished" : line
            case .stopped:
                let count = (try? await repo.conflictedFiles().count) ?? 0
                return count > 0
                    ? "\(name) stopped: \(count) \(count == 1 ? "file has" : "files have") conflicts"
                    : "\(name) stopped: continue or abort from the banner"
            }
        }, onSuccess: { [weak self] in
            self?.onWorkingTreeChanged?()
        }, onFailure: { [weak self] message in
            self?.onWorkingTreeChanged?()
            failureHint?(message)
        })
    }

    /// Git refused because local changes are in the way: offer to stash, repeat, and unstash.
    private func offerStashAndRepeat(message: String, what: String, repeating action: @escaping @MainActor () -> Void) {
        guard let files = GitSwitchConflictParser.parse(message) else { return }
        sheets.present(.confirm(IDEGitConfirmation(
            title: "Local Changes Would Be Overwritten",
            message: "Changes to \(files.prefix(3).joined(separator: ", "))\(files.count > 3 ? " and \(files.count - 3) more" : "") are in the way. Stash them, \(what), and put them back?",
            confirmTitle: "Stash and Continue",
            action: action
        )))
    }
}

extension IDEWorkspace {
    /// Opens the three-way merge for a conflicted file (absolute path), or selects its tab.
    func openMergeTool(forPath path: String) {
        guard gitStatus.isRepository, let relative = gitStatus.repositoryRelativePath(for: path) else { return }
        for pane in workbench.panes {
            for document in pane.documents where document.contentKind == .diff {
                if mergeSessions[document.id]?.request.path == path {
                    selectTab(document.id, in: pane.id)
                    return
                }
            }
        }
        let presentation = gitStatus.operationPresentation
        let name = (path as NSString).lastPathComponent
        let request = IDEMergeRequest(
            path: path,
            relativePath: relative,
            leftTitle: presentation?.leftTitle ?? "Yours",
            rightTitle: presentation?.rightTitle ?? "Theirs",
            tabTitle: "\(name) (Merge)"
        )
        let session = IDEMergeSession(request: request)
        let document = WorkbenchDocument(displayName: request.tabTitle)
        document.contentKind = .diff
        session.loadContent = { [weak self] revision in
            guard let self else { return .failed("The window was closed.") }
            return await self.gitStatus.diffContent(.revision(revision, relativePath: relative))
        }
        session.applyResult = { [weak self] text in
            guard let self else { return "The window was closed." }
            return await self.gitStatus.resolveConflict(relativePath: relative, contents: Data(text.utf8))
        }
        session.onApplied = { [weak self, weak document] in
            guard let self, let document else { return }
            self.closeMergeTab(documentID: document.id)
        }
        mergeSessions[document.id] = session
        presentDiffDocument(document)
    }

    private func closeMergeTab(documentID: UUID) {
        for pane in workbench.panes where pane.documents.contains(where: { $0.id == documentID }) {
            closeTab(documentID, in: pane.id)
            return
        }
    }
}
