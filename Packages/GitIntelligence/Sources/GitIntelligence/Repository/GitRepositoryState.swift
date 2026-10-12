import Foundation

/// A multi-step command git has started and not finished.
public enum GitOperationKind: String, Sendable, Equatable {
    case merge
    case rebase
    case cherryPick
    case revert
    case applyMailbox
    case bisect
}

public struct GitOperationState: Sendable, Equatable {
    public var kind: GitOperationKind
    /// The rebase step git stopped at (1-based) and the number of steps, when it says.
    public var step: Int?
    public var total: Int?
    /// The commit a rebase replays onto.
    public var onto: String?
    /// The branch a rebase is rewriting (`feature`), nil for a detached head.
    public var branch: String?
    /// The commits being merged (`MERGE_HEAD`: one, or several for an octopus), or the commit being
    /// cherry-picked or reverted.
    public var heads: [String]
    /// `MERGE_MSG`, the message git prepared for the commit that ends a merge.
    public var message: String?
    public var isInteractive: Bool

    public init(
        kind: GitOperationKind, step: Int? = nil, total: Int? = nil, onto: String? = nil, branch: String? = nil,
        heads: [String] = [], message: String? = nil, isInteractive: Bool = false
    ) {
        self.kind = kind
        self.step = step
        self.total = total
        self.onto = onto
        self.branch = branch
        self.heads = heads
        self.message = message
        self.isInteractive = isInteractive
    }
}

/// Where HEAD points and what operation is in progress, read straight from the `.git` directory
/// without starting a process (IntelliJ reads repository metadata the same way). Cheap enough to
/// call on every refresh.
public struct GitRepositoryState: Sendable, Equatable {
    public enum Head: Sendable, Equatable {
        /// `ref: refs/heads/<name>`. The branch may not have a commit yet.
        case branch(String)
        /// A commit id: HEAD is not on a branch.
        case detached(String)
        /// A symbolic ref outside `refs/heads` (rare).
        case ref(String)
        /// HEAD could not be read.
        case unknown
    }

    public var head: Head
    public var operation: GitOperationState?

    public init(head: Head, operation: GitOperationState? = nil) {
        self.head = head
        self.operation = operation
    }

    public var branchName: String? {
        if case .branch(let name) = head { return name }
        return nil
    }

    public var isDetached: Bool {
        if case .detached = head { return true }
        return false
    }

    /// - Parameter gitDirectory: the directory holding `HEAD` and the operation files. For a
    ///   linked worktree that is `.git/worktrees/<name>`, not the shared `.git`.
    public static func read(gitDirectory: URL, fileManager: FileManager = .default) -> GitRepositoryState {
        func text(_ name: String) -> String? {
            guard let data = fileManager.contents(atPath: gitDirectory.appendingPathComponent(name).path) else { return nil }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: gitDirectory.appendingPathComponent(name).path)
        }
        func lines(_ name: String) -> [String] {
            (text(name) ?? "").split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        func shortBranch(_ name: String?) -> String? {
            guard let name, name.hasPrefix("refs/heads/") else { return nil }
            return String(name.dropFirst("refs/heads/".count))
        }

        func readHead(_ raw: String?) -> Head {
            guard let raw, !raw.isEmpty else { return .unknown }
            if raw.hasPrefix("ref:") {
                let ref = raw.dropFirst(4).trimmingCharacters(in: .whitespaces)
                if let branch = shortBranch(ref) { return .branch(branch) }
                return .ref(ref)
            }
            return .detached(raw)
        }

        func readOperation() -> GitOperationState? {
            // A rebase can leave CHERRY_PICK_HEAD behind while it replays a commit, so it goes first.
            if exists("rebase-merge") {
                return GitOperationState(
                    kind: .rebase,
                    step: Int(text("rebase-merge/msgnum") ?? ""),
                    total: Int(text("rebase-merge/end") ?? ""),
                    onto: text("rebase-merge/onto"),
                    branch: shortBranch(text("rebase-merge/head-name")),
                    message: text("rebase-merge/message"),
                    isInteractive: exists("rebase-merge/interactive")
                )
            }
            if exists("rebase-apply") {
                let kind: GitOperationKind = exists("rebase-apply/applying") ? .applyMailbox : .rebase
                return GitOperationState(
                    kind: kind,
                    step: Int(text("rebase-apply/next") ?? ""),
                    total: Int(text("rebase-apply/last") ?? ""),
                    onto: text("rebase-apply/onto"),
                    branch: shortBranch(text("rebase-apply/head-name"))
                )
            }
            if exists("MERGE_HEAD") {
                return GitOperationState(kind: .merge, heads: lines("MERGE_HEAD"), message: text("MERGE_MSG"))
            }
            if exists("CHERRY_PICK_HEAD") {
                return GitOperationState(kind: .cherryPick, heads: lines("CHERRY_PICK_HEAD"), message: text("MERGE_MSG"))
            }
            if exists("REVERT_HEAD") {
                return GitOperationState(kind: .revert, heads: lines("REVERT_HEAD"), message: text("MERGE_MSG"))
            }
            if exists("BISECT_LOG") {
                return GitOperationState(kind: .bisect)
            }
            return nil
        }

        return GitRepositoryState(head: readHead(text("HEAD")), operation: readOperation())
    }
}
