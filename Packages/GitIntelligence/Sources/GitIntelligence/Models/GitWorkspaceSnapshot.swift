import Foundation

/// Identity of one working tree.
///
/// `workTree` is the checkout `discover` resolved. `gitDirectory` is the directory that holds
/// `HEAD`, the index, and operation files. A linked worktree's git directory is
/// `<main>/.git/worktrees/<name>`, not the shared `.git`, so two worktrees that share object
/// storage do not share an id.
///
/// Ownership. The window that opened the work tree owns the snapshot (`IDEGitStatusModel`).
/// Mutations for one git directory share `GitMutationLane.shared` for the whole process, so two
/// windows on the same work tree cannot stage and commit at once. Two worktrees do not share that
/// lane. Closing a window cancels that window's tasks only. A mutation another window already
/// started runs to completion. The lane entry stays for the next caller.
public struct GitRepositoryID: Sendable, Hashable, Codable {
    public var workTree: URL
    public var gitDirectory: URL

    public init(workTree: URL, gitDirectory: URL) {
        self.workTree = workTree.standardizedFileURL
        self.gitDirectory = gitDirectory.standardizedFileURL
    }

    /// The mutation lane and watcher use this path. Worktrees of one clone differ here.
    public var laneKey: String { gitDirectory.resolvingSymlinksInPath().standardizedFileURL.path }
}

/// Ahead/behind for the current branch, without the commit lists the push rows load separately.
public struct GitUpstream: Sendable, Equatable {
    public var name: String
    public var ahead: Int
    public var behind: Int
    /// `%(upstream:track)` reported `[gone]`.
    public var gone: Bool

    public init(name: String, ahead: Int, behind: Int, gone: Bool) {
        self.name = name
        self.ahead = ahead
        self.behind = behind
        self.gone = gone
    }
}

/// One successful read of branch, status, and repository state.
///
/// `generation` is the refresh epoch captured when the load started. An apply from an older
/// generation is ignored. `entries` keep `originalPath` for renames. Ignored paths are not part of
/// the hot snapshot; a later pass may add them to the model's file statuses without replacing
/// these entries.
public struct GitWorkspaceSnapshot: Sendable, Equatable {
    public var id: GitRepositoryID
    public var generation: UInt64
    public var state: GitRepositoryState
    public var branchName: String?
    public var entries: [GitStatusEntry]
    public var upstream: GitUpstream?
    public var fetchedAt: Date

    public init(
        id: GitRepositoryID, generation: UInt64, state: GitRepositoryState, branchName: String?,
        entries: [GitStatusEntry], upstream: GitUpstream?, fetchedAt: Date
    ) {
        self.id = id
        self.generation = generation
        self.state = state
        self.branchName = branchName
        self.entries = entries
        self.upstream = upstream
        self.fetchedAt = fetchedAt
    }
}

/// What the panel publishes for the latest status attempt.
///
/// A cancelled load does not move this value. `.failed` keeps `last` and is not "this folder is
/// not a repository." `.unavailable` is that case: discover found no work tree.
public enum GitRefreshState: Sendable, Equatable {
    /// No folder is open, or the folder is not a work tree.
    case unavailable
    /// A load is in flight and no snapshot has succeeded yet.
    case loading(last: GitWorkspaceSnapshot?)
    /// A snapshot is showing. A newer load is in flight, or a mutation has invalidated it.
    case stale(last: GitWorkspaceSnapshot)
    /// The last load succeeded.
    case idle(GitWorkspaceSnapshot)
    /// The last load failed. `last` is still what the panel shows.
    case failed(last: GitWorkspaceSnapshot?, message: String)

    public var snapshot: GitWorkspaceSnapshot? {
        switch self {
        case .unavailable: nil
        case .loading(let last), .failed(let last, _): last
        case .stale(let last): last
        case .idle(let snapshot): snapshot
        }
    }

    public var failureMessage: String? {
        if case .failed(_, let message) = self { return message }
        return nil
    }
}

/// One hunk to apply to the index. Built from a diff the user saw, not from an unsaved editor buffer.
public struct GitHunkApply: Sendable, Equatable {
    public var relativePath: String
    /// Blob id of `:path` when the patch was built. Nil when the index has no blob (an untracked add).
    public var baseBlobID: String?
    public var patch: String
    /// False stages into the index. True removes the hunk from the index.
    public var reverse: Bool

    public init(relativePath: String, baseBlobID: String?, patch: String, reverse: Bool) {
        self.relativePath = relativePath
        self.baseBlobID = baseBlobID
        self.patch = patch
        self.reverse = reverse
    }
}

/// `git commit` of the current index. No path list.
public struct GitIndexCommit: Sendable, Equatable {
    public var message: String
    public var amend: Bool
    public var signoff: Bool
    public var skipHooks: Bool

    public init(message: String, amend: Bool = false, signoff: Bool = false, skipHooks: Bool = false) {
        self.message = message
        self.amend = amend
        self.signoff = signoff
        self.skipHooks = skipHooks
    }
}
