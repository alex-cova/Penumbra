import Foundation

/// What a merge or rebase did: it finished, or it stopped and needs the user (conflicts, or an
/// `edit` step). A stopped operation is not an error: resolve, then continue or abort it.
public enum GitIntegrationResult: Sendable, Equatable {
    case completed(String)
    case stopped(String)

    public var report: String {
        switch self {
        case .completed(let text), .stopped(let text): text
        }
    }

    public var isStopped: Bool {
        if case .stopped = self { return true }
        return false
    }
}

/// Which side wins when a conflicted file is resolved without opening it.
public enum GitConflictSide: Sendable, Equatable {
    /// Stage 2: the branch being merged into, or the commit a rebase replays onto.
    case ours
    /// Stage 3: the branch being merged, or the commit being replayed.
    case theirs
}

/// What an unresolved path has in the index: a side is missing when that side deleted the file.
public struct GitConflictStages: Sendable, Equatable {
    public let hasBase: Bool
    public let hasOurs: Bool
    public let hasTheirs: Bool

    public init(hasBase: Bool, hasOurs: Bool, hasTheirs: Bool) {
        self.hasBase = hasBase
        self.hasOurs = hasOurs
        self.hasTheirs = hasTheirs
    }
}

/// Merge, rebase and the commands that finish, skip or abandon an operation in progress.
extension GitRepository {
    private static let noEditor = ["GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true"]

    public func merge(
        _ branch: String, noFastForward: Bool = false, squash: Bool = false, message: String? = nil
    ) async throws -> GitIntegrationResult {
        let name = try validatedBranchName(branch)
        var args = ["merge", "--no-edit"]
        if noFastForward { args.append("--no-ff") }
        if squash { args.append("--squash") }
        if let message, !message.isEmpty { args += ["-m", message] }
        args += ["--", name]
        return try await integrate(args)
    }

    /// Replays the current branch's commits on top of `upstream`.
    public func rebase(onto upstream: String) async throws -> GitIntegrationResult {
        let name = try validatedBranchName(upstream)
        return try await integrate(["rebase", name])
    }

    /// Runs a command that may stop in the middle: when it fails and an operation is in progress,
    /// that is a stop, not a failure.
    func integrate(_ args: [String], environment: [String: String]? = nil) async throws -> GitIntegrationResult {
        do {
            let text = report(try await mutate(args, extraEnvironment: environment ?? Self.noEditor))
            // An interactive rebase stopping at an `edit` step exits 0 and leaves its state behind.
            return state().operation == nil ? .completed(text) : .stopped(text)
        } catch let error as GitError {
            if state().operation != nil {
                return .stopped(error.errorDescription ?? "")
            }
            throw error
        }
    }

    /// Finishes the operation after its conflicts are resolved. A merge is committed (with `message`
    /// when given, else the message git prepared); a rebase, cherry-pick or revert goes on to its
    /// next step, which may stop again.
    public func continueOperation(_ kind: GitOperationKind, message: String? = nil) async throws -> GitIntegrationResult {
        switch kind {
        case .merge:
            var args = ["commit"]
            if let message, !message.isEmpty { args += ["-m", message] } else { args.append("--no-edit") }
            return .completed(report(try await mutate(args, extraEnvironment: Self.noEditor)))
        case .rebase: return try await integrate(["rebase", "--continue"])
        case .cherryPick: return try await integrate(["cherry-pick", "--continue"])
        case .revert: return try await integrate(["revert", "--continue"])
        case .applyMailbox: return try await integrate(["am", "--continue"])
        case .bisect: throw GitError.invalidRequest("A bisect is ended with Reset.")
        }
    }

    /// Gives up: the repository goes back to how it was before the operation started.
    public func abortOperation(_ kind: GitOperationKind) async throws -> String {
        let args: [String]
        switch kind {
        case .merge: args = ["merge", "--abort"]
        case .rebase: args = ["rebase", "--abort"]
        case .cherryPick: args = ["cherry-pick", "--abort"]
        case .revert: args = ["revert", "--abort"]
        case .applyMailbox: args = ["am", "--abort"]
        case .bisect: args = ["bisect", "reset"]
        }
        return report(try await mutate(args, extraEnvironment: Self.noEditor))
    }

    /// Drops the commit the operation stopped at and goes on.
    public func skipOperation(_ kind: GitOperationKind) async throws -> GitIntegrationResult {
        switch kind {
        case .rebase: return try await integrate(["rebase", "--skip"])
        case .cherryPick: return try await integrate(["cherry-pick", "--skip"])
        case .revert: return try await integrate(["revert", "--skip"])
        case .applyMailbox: return try await integrate(["am", "--skip"])
        case .merge, .bisect: throw GitError.invalidRequest("This operation cannot be skipped.")
        }
    }

    // MARK: - Conflicts

    /// The paths with unresolved conflicts, relative to the root.
    public func conflictedFiles() async throws -> [String] {
        let out = try await readOnly(["diff", "--name-only", "--diff-filter=U", "-z"])
        return out.text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    public func conflictStages(of path: String) async throws -> GitConflictStages {
        let out = try await readOnly(["--literal-pathspecs", "ls-files", "-u", "-z", "--", path])
        var seen = Set<Int>()
        // `<mode> <object> <stage>\t<path>`, one per stage.
        for record in out.text.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: "\t") else { continue }
            if let stage = record[..<tab].split(separator: " ").last, let number = Int(stage) { seen.insert(number) }
        }
        return GitConflictStages(hasBase: seen.contains(1), hasOurs: seen.contains(2), hasTheirs: seen.contains(3))
    }

    /// Resolves `paths` to one side and stages the result. A side that deleted the file removes it.
    public func resolve(paths: [String], taking side: GitConflictSide) async throws {
        for path in paths {
            let stages = try await conflictStages(of: path)
            let present = side == .ours ? stages.hasOurs : stages.hasTheirs
            if present {
                _ = try await mutate(["--literal-pathspecs", "checkout", side == .ours ? "--ours" : "--theirs", "--", path])
                _ = try await mutate(["--literal-pathspecs", "add", "--", path])
            } else {
                _ = try await mutate(["--literal-pathspecs", "rm", "-f", "--quiet", "--", path])
            }
        }
    }

    /// Stages `paths` as they are on disk (after the user edited them), which marks them resolved.
    public func markResolved(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await mutate(["--literal-pathspecs", "add", "--"] + paths)
    }

    /// Writes `contents` to `path` and stages it: the merge tool's Apply.
    public func resolve(path: String, with contents: Data) async throws {
        let url = root.appendingPathComponent(path)
        try contents.write(to: url, options: .atomic)
        try await markResolved(paths: [path])
    }
}
