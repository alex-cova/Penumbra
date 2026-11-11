import Foundation

/// The comparison the Changes preview and Show Diff open for one row.
///
/// A file with work-tree changes compares the index with the working tree. A file that is only
/// staged compares HEAD with the index. An added or untracked file has an empty left side.
/// A rename or copy reads `originalPath` for the side whose porcelain code is `R` or `C`.
/// The other side keeps the current path. A missing source path is not guessed.
enum IDEGitChangeDiff {
    struct Preview: Equatable, Sendable {
        var request: IDEDiffRequest
        var siblings: [IDEDiffRequest]
        var relativePath: String
    }

    /// Work-tree changes win, so a file that is both staged and unstaged opens its unstaged diff.
    static func prefersStaged(_ change: IDEGitChange) -> Bool {
        change.unstaged == nil
    }

    /// The old path, when this side of the entry is itself a rename or a copy. A staged rename
    /// with a further work-tree edit (`RM`) passes the old path only for the staged comparison.
    static func sourcePath(for change: IDEGitChange, staged: Bool) -> String? {
        let code: Character = staged ? change.indexCode : change.worktreeCode
        guard code == "R" || code == "C" else { return nil }
        guard let original = change.originalPath, !original.isEmpty, original != change.relativePath else { return nil }
        return original
    }

    static func request(for change: IDEGitChange, staged: Bool) -> IDEDiffRequest {
        IDEDiffRequest.change(
            path: change.path,
            relativePath: change.relativePath,
            staged: staged,
            isNew: staged ? change.staged == .added : change.unstaged == .untracked,
            sourcePath: sourcePath(for: change, staged: staged)
        )
    }

    /// The rows Previous/Next File walks. `staged` is HEAD ↔ index; otherwise index ↔ working tree.
    static func requests(in changes: [IDEGitChange], staged: Bool) -> [IDEDiffRequest] {
        changes.compactMap { change in
            let included = staged ? change.staged != nil : change.unstaged != nil
            guard included else { return nil }
            return request(for: change, staged: staged)
        }
    }

    /// The sidebar's request for one row. `section` nil keeps the old path-only rule (unstaged
    /// wins). A section the file no longer occupies returns nil, so a stale row does not show
    /// the other side's diff.
    static func preview(of path: String, section: IDEGitChangeSection? = nil, in changes: [IDEGitChange]) -> Preview? {
        guard let change = changes.first(where: { $0.path == path }) else { return nil }
        let staged: Bool
        if let section {
            switch section {
            case .conflict:
                return nil
            case .staged:
                guard change.staged != nil, change.staged != .conflicted else { return nil }
                staged = true
            case .unstaged:
                guard change.unstaged != nil, change.unstaged != .conflicted else { return nil }
                staged = false
            }
        } else {
            staged = prefersStaged(change)
        }
        let siblings = requests(in: changes, staged: staged)
        guard let request = siblings.first(where: { $0.filePath == path }) else { return nil }
        return Preview(request: request, siblings: siblings, relativePath: change.relativePath)
    }
}
