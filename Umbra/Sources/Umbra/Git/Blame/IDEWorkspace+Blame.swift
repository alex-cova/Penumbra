import AppKit
import Foundation
import GitIntelligence

/// What the blame column's actions do in the window (Annotate Revision, Show Diff, Show in Log…).
extension IDEWorkspace {
    func configureBlame() {
        blame.onAction = { [weak self] action in self?.performBlameAction(action) }
        blame.loadMessageBody = { [weak self] hash in await self?.gitStatus.commitMessageBody(hash: hash) }
        blame.onNeedsBlame = { [weak self] in self?.reblameOpenEditors() }
    }

    /// A setting or a hidden revision changed what git must answer: every blamed editor asks again.
    func reblameOpenEditors() {
        for pane in workbench.panes where blame.isEnabled(for: pane.selectedDocument?.url) {
            refreshBlame(in: pane, force: true)
        }
    }

    /// The path of `url` in the working tree: a revision snapshot stands for the file it came from.
    private func workingPath(of url: URL) -> String {
        guard let source = IDEGitRevisionFiles.source(for: url) else { return url.standardizedFileURL.path }
        return (source.repositoryRoot as NSString).appendingPathComponent(source.relativePath)
    }

    func performBlameAction(_ action: IDEBlameAction) {
        switch action {
        case .showDiff(let line, _):
            guard let root = gitStatus.repositoryRootPath, !line.isUncommitted else { return }
            let path = line.originalPath.isEmpty ? nil : line.originalPath
            guard let path else { return }
            let oldPath = line.previous?.path == path ? nil : line.previous?.path
            openDiff(IDEDiffRequest.commitFile(
                hash: line.hash, shortHash: line.shortHash, path: path, oldPath: oldPath, repositoryRoot: root))
        case .showInLog(let line, let file):
            guard !line.isUncommitted else { return }
            gitStatus.revealCommit(line.hash, inHistoryOf: workingPath(of: file))
            showBottomTab(.sourceControl)
        case .copyRevision(let hash):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hash, forType: .string)
        case .openOnWeb(let hash):
            openCommitOnWeb(hash)
        case .annotateRevision(let line, _):
            guard !line.isUncommitted, !line.originalPath.isEmpty else { return }
            openRevisionSnapshot(hash: line.hash, relativePath: line.originalPath, line: line.originalLine)
        case .annotatePreviousRevision(let line, _):
            guard let previous = line.previous else { return }
            openRevisionSnapshot(hash: previous.hash, relativePath: previous.path, line: line.originalLine)
        case .showLineHistory(let file, let line):
            gitStatus.showLineHistory(path: workingPath(of: file), startLine: line, endLine: line)
            showBottomTab(.sourceControl)
        }
    }

    /// Opens `relativePath` as `hash` stored it in a read-only tab with blame on, and puts the caret
    /// on `line` (1-based, clamped to the file).
    func openRevisionSnapshot(hash: String, relativePath: String, line: Int) {
        guard let root = gitStatus.repositoryRootPath else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let data = await self.gitStatus.fileContents(at: .commit(hash), relativePath: relativePath),
                  let url = IDEGitRevisionFiles.write(data, repositoryRoot: root, hash: hash, relativePath: relativePath) else {
                self.showGitNotice(
                    "No Such Revision",
                    "\((relativePath as NSString).lastPathComponent) does not exist in \(hash.prefix(7)).")
                return
            }
            self.blame.enable(url)
            let text = String(decoding: data, as: UTF8.self)
            let lines = IDEDiffText(text)
            let row = min(max(line - 1, 0), max(lines.lineCount - 1, 0))
            let location = lines.lineCount > 0 ? lines.lines[row].location : 0
            await self.openDocument(from: url, selecting: NSRange(location: location, length: 0))
            // The column fills when the tab's editor loads; a tab that was already open needs a nudge.
            self.refreshBlame(in: self.workbench.activePane, force: true)
        }
    }
}
