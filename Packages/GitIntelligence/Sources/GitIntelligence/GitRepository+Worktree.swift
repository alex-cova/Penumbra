import Foundation

/// One line of `git worktree list --porcelain`: where the checkout lives and what it holds.
public struct GitWorktree: Sendable, Hashable, Equatable {
    /// The worktree's root, as git printed it.
    public let path: String
    /// The checked-out commit.
    public let head: String
    /// `main` for `branch refs/heads/main`; nil when detached or bare.
    public let branch: String?
    public let isBare: Bool
    public let isDetached: Bool

    public init(path: String, head: String, branch: String?, isBare: Bool, isDetached: Bool) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.isDetached = isDetached
    }
}

/// Parses `git worktree list --porcelain`: blank-line-separated records of `worktree`, `HEAD`,
/// and one of `branch`, `detached` or `bare`, with optional `locked`/`prunable` lines ignored.
public enum GitWorktreeParser {
    public static func parse(_ text: String) -> [GitWorktree] {
        var worktrees: [GitWorktree] = []
        var path: String?
        var head = ""
        var branch: String?
        var isBare = false
        var isDetached = false
        func flush() {
            guard let path, !path.isEmpty, !head.isEmpty else { return }
            worktrees.append(GitWorktree(
                path: path, head: head, branch: branch, isBare: isBare, isDetached: isDetached))
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.isEmpty {
                flush()
                path = nil; head = ""; branch = nil; isBare = false; isDetached = false
            } else if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            } else if line == "bare" {
                isBare = true
            } else if line == "detached" {
                isDetached = true
            }
        }
        flush()
        return worktrees
    }
}

extension GitRepository {
    /// Every worktree of this repository, including the main one first.
    public func worktreeList() async throws -> [GitWorktree] {
        GitWorktreeParser.parse(try await readOnly(["worktree", "list", "--porcelain"]).text)
    }

    /// Checks out a new worktree at `path`, on a new branch `branch` (at `startPoint`, HEAD when
    /// nil), or on `startPoint` directly when `branch` is nil. `path` must not exist yet.
    public func worktreeAdd(path: String, branch: String? = nil, startPoint: String? = nil) async throws -> String {
        guard !path.isEmpty, !path.hasPrefix("-") else { throw GitError.invalidRequest("Enter a valid worktree path.") }
        var args = ["worktree", "add"]
        if let branch {
            args += ["-b", try validatedBranchName(branch)]
        }
        args.append(path)
        if let startPoint {
            guard !startPoint.isEmpty, !startPoint.hasPrefix("-") else {
                throw GitError.invalidRequest("Enter a valid starting point.")
            }
            args.append(startPoint)
        }
        return report(try await mutate(args))
    }

    /// Removes the worktree at `path`. `force` also removes one with uncommitted changes or
    /// untracked files; agent-facing callers leave it false and report git's error instead.
    public func worktreeRemove(path: String, force: Bool = false) async throws -> String {
        guard !path.isEmpty, !path.hasPrefix("-") else { throw GitError.invalidRequest("Enter a valid worktree path.") }
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(path)
        return report(try await mutate(args))
    }
}
