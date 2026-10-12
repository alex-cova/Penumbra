import AppKit
import Foundation
import GitIntelligence

/// Links to a file, a commit or a branch on the hosting service the repository's remote points at.
extension IDEGitStatusModel {
    /// The remote the current branch pushes to, else `origin`, else the first one.
    func hostingURL() async -> IDEGitHostingURL? {
        guard let rootURL,
              let repo = try? await IDEGitSupport.repository(for: rootURL, existing: repository)
        else { return nil }
        let remotes = await repo.remoteDetails()
        guard !remotes.isEmpty else { return nil }
        let upstreamRemote = branchInfos.first(where: \.isCurrent)?.upstream.flatMap { upstream in
            upstream.firstIndex(of: "/").map { String(upstream[..<$0]) }
        }
        let remote = remotes.first { $0.name == upstreamRemote } ?? remotes.first { $0.name == "origin" } ?? remotes[0]
        return IDEGitHostingURL(remoteURL: remote.fetchURL)
    }

    /// What a file link points at: the branch the current one tracks (so the link follows the
    /// branch), else the commit HEAD is on.
    var webReference: (name: String, isCommit: Bool)? {
        if let current = branchInfos.first(where: \.isCurrent) {
            if let upstream = current.upstream, let slash = upstream.firstIndex(of: "/"), !current.upstreamIsGone {
                return (String(upstream[upstream.index(after: slash)...]), false)
            }
            return (current.hash, true)
        }
        if case .detached(let sha) = repositoryState.head { return (sha, true) }
        return nil
    }
}

extension IDEWorkspace {
    private func deliver(_ url: URL?, copy: Bool, missing: String) {
        guard let url else {
            showGitNotice("No Web Link", missing)
            return
        }
        if copy {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// The file (and, when given, 1-based lines) on the hosting service.
    func openFileOnWeb(_ fileURL: URL, lines: ClosedRange<Int>? = nil, copy: Bool = false) {
        let path = fileURL.standardizedFileURL.path
        guard let relative = gitStatus.repositoryRelativePath(for: path) else { return }
        let status = gitStatus
        Task { [weak self] in
            let hosting = await status.hostingURL()
            guard let self else { return }
            guard let hosting else {
                self.showGitNotice("No Web Link", "The repository has no remote on a hosting service.")
                return
            }
            guard let reference = status.webReference else {
                self.showGitNotice("No Web Link", "There is no commit to link to yet.")
                return
            }
            let url = hosting.fileURL(ref: reference.name, path: relative, isCommit: reference.isCommit, lines: lines)
            self.deliver(url, copy: copy, missing: "The link could not be built.")
        }
    }

    func openCommitOnWeb(_ hash: String, copy: Bool = false) {
        let status = gitStatus
        Task { [weak self] in
            let url = await status.hostingURL()?.commitURL(hash)
            self?.deliver(url, copy: copy, missing: "The repository has no remote on a hosting service.")
        }
    }

    func openBranchOnWeb(_ branch: String, copy: Bool = false) {
        let status = gitStatus
        Task { [weak self] in
            let url = await status.hostingURL()?.branchURL(branch)
            self?.deliver(url, copy: copy, missing: "The repository has no remote on a hosting service.")
        }
    }

    /// The active editor's file with the selected lines (the caret's line when nothing is selected).
    func openActiveFileOnWeb(copy: Bool = false) {
        let pane = workbench.activePane
        guard let document = pane.selectedDocument, document.contentKind == .text, let url = document.url else {
            showGitNotice("No Web Link", "The active file is not in a git repository.")
            return
        }
        let textView = host(for: pane.id).textView
        let range = textView.selectedRange
        let first = textView.textLocation(at: range.location)?.lineNumber ?? 0
        let lastOffset = range.length > 0 ? max(range.location, NSMaxRange(range) - 1) : range.location
        let last = textView.textLocation(at: lastOffset)?.lineNumber ?? first
        openFileOnWeb(url, lines: (first + 1) ... (max(first, last) + 1), copy: copy)
    }
}
