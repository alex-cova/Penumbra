import Foundation

extension IDEWorkspace {
    /// Stages the Changes selection, or the active file when the list has no selection.
    func stageSelectedChanges() {
        let paths = IDEGitIndexPaths.toStage(
            selected: orderedSelectedChangePaths,
            changes: gitStatus.changes,
            activeFile: activeFileInRepository()?.path
        )
        guard !paths.isEmpty else {
            gitStatus.fail("Nothing to stage.")
            return
        }
        gitStatus.stage(paths: paths)
    }

    /// Unstages the Changes selection, or the active file when the list has no selection.
    func unstageSelectedChanges() {
        let paths = IDEGitIndexPaths.toUnstage(
            selected: orderedSelectedChangePaths,
            changes: gitStatus.changes,
            activeFile: activeFileInRepository()?.path
        )
        guard !paths.isEmpty else {
            gitStatus.fail("Nothing to unstage.")
            return
        }
        gitStatus.unstage(paths: paths)
    }

    /// The selected row's diff in a tab. The row's section chooses staged or unstaged.
    /// A conflict opens the merge tool.
    func showSelectedChangeDiff() {
        guard let row = gitStatus.selectedChange,
              let change = gitStatus.changes.first(where: { $0.path == row.path }) else {
            gitStatus.fail("Select a change.")
            return
        }
        if row.section == .conflict || change.staged == .conflicted || change.unstaged == .conflicted {
            openMergeTool(forPath: row.path)
            return
        }
        openChangeDiff(path: row.path, staged: row.section == .staged)
    }

    /// Shows Changes and moves the keyboard to the commit message, including when the tab is already visible.
    func focusCommitMessage() {
        showAndFocusSidebarTab(.changes)
    }

    /// Focuses the commit field, then commits when the button would. A refusal uses the button's wording.
    func commitStagedChanges() {
        focusCommitMessage()
        let staged = gitStatus.changes.filter { $0.staged != nil && $0.staged != .conflicted }.count
        if let reason = IDEGitCommitRefusal.reason(
            isBusy: gitStatus.isBusy,
            stagedCount: staged,
            isAmend: gitStatus.commitOptions.amend,
            message: gitStatus.commitMessage
        ) {
            gitStatus.fail(reason)
            return
        }
        gitStatus.commit()
    }

    /// Opens the merge tool on the next conflict after the open file, or the first conflict.
    func openNextConflict() {
        let paths = gitStatus.conflictedChanges.map(\.path)
        guard let step = IDEGitConflictNavigation.next(paths: paths, currentPath: activeFileInRepository()?.path) else {
            gitStatus.fail("No conflicts")
            return
        }
        switch step {
        case .open(let path):
            gitStatus.selectChange(path)
            openMergeTool(forPath: path)
        case .stayed:
            gitStatus.succeed("No further conflicts")
        }
    }

    /// Selected change paths in list order. `selectedChangePaths` is a set.
    private var orderedSelectedChangePaths: [String] {
        let selected = gitStatus.selectedChangePaths
        return gitStatus.changes.map(\.path).filter { selected.contains($0) }
    }
}
