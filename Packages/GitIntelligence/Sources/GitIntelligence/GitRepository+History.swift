import Foundation

/// What `reset` does to the index and the working tree.
public enum GitResetMode: String, Sendable, CaseIterable {
    /// Move the branch only; everything stays staged.
    case soft
    /// Move the branch and unstage; the working tree is kept.
    case mixed
    /// Move the branch and throw away every change.
    case hard
    /// Move the branch, keeping local changes that the move does not touch (refuses otherwise).
    case keep
}

/// One commit of a line range's history with the change it made to those lines.
public struct GitLineHistoryEntry: Sendable, Equatable, Identifiable {
    public let commit: GitCommit
    public let patch: String

    public var id: String { commit.hash }

    public init(commit: GitCommit, patch: String) {
        self.commit = commit
        self.patch = patch
    }
}

/// Cherry-pick, revert, reset, and reading history in more ways than `log`.
extension GitRepository {
    private static func validatedCommits(_ hashes: [String]) throws -> [String] {
        guard !hashes.isEmpty else { throw GitError.invalidRequest("Choose at least one commit.") }
        for hash in hashes where hash.isEmpty || hash.hasPrefix("-") {
            throw GitError.invalidRequest("Enter a valid commit.")
        }
        return hashes
    }

    /// Applies `hashes` (oldest first) on top of HEAD. A merge commit is refused: git would need to
    /// be told which parent is the mainline.
    public func cherryPick(_ hashes: [String], recordOrigin: Bool = false) async throws -> GitIntegrationResult {
        let commits = try Self.validatedCommits(hashes)
        try await refuseMerges(commits, verb: "cherry-picked")
        return try await integrate(["cherry-pick"] + (recordOrigin ? ["-x"] : []) + commits)
    }

    /// Creates a commit undoing each of `hashes` (newest first, as git expects).
    public func revertCommits(_ hashes: [String]) async throws -> GitIntegrationResult {
        let commits = try Self.validatedCommits(hashes)
        try await refuseMerges(commits, verb: "reverted")
        return try await integrate(["revert", "--no-edit"] + commits)
    }

    private func refuseMerges(_ hashes: [String], verb: String) async throws {
        for hash in hashes {
            guard let out = try? await readOnly(["rev-list", "--parents", "-n", "1", hash]) else { continue }
            if out.text.split(separator: " ").count > 2 {
                throw GitError.invalidRequest("A merge commit cannot be \(verb) here.")
            }
        }
    }

    /// Moves the current branch to `revision`. `.hard` discards uncommitted changes: the caller asks.
    public func reset(to revision: String, mode: GitResetMode) async throws -> String {
        guard !revision.isEmpty, !revision.hasPrefix("-") else { throw GitError.invalidRequest("Enter a valid revision.") }
        return report(try await mutate(["reset", "--\(mode.rawValue)", revision, "--"]))
    }

    /// `reset --soft HEAD~`: the last commit's changes go back to staged.
    public func undoLastCommit() async throws {
        guard (try? await readOnly(["rev-parse", "-q", "--verify", "HEAD~1"])) != nil else {
            throw GitError.invalidRequest("The first commit cannot be undone.")
        }
        _ = try await mutate(["reset", "--soft", "HEAD~1", "--"])
    }

    /// Replaces the last commit's message, leaving what is staged out of it.
    public func amendMessage(_ message: String) async throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitError.invalidRequest("The message cannot be empty.")
        }
        _ = try await mutate(["commit", "--amend", "--only", "--no-verify", "-m", message])
    }

    /// The local and remote branches that contain `hash`.
    public func branchesContaining(_ hash: String) async -> [String] {
        guard !hash.hasPrefix("-"),
              let out = try? await readOnly(["branch", "-a", "--contains", hash, "--format=%(refname:short)"])
        else { return [] }
        return out.text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasSuffix("/HEAD") && !$0.hasPrefix("(") }
    }

    /// The remote-tracking branches that already hold `hash`: rewriting it needs a force push.
    public func remoteBranchesContaining(_ hash: String) async -> [String] {
        guard !hash.hasPrefix("-"),
              let out = try? await readOnly(["branch", "-r", "--contains", hash, "--format=%(refname:short)"])
        else { return [] }
        return out.text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasSuffix("/HEAD") }
    }

    /// The commits that changed lines `start...end` (1-based) of `path`, newest first, with the part
    /// of each patch that touches them (`git log -L`).
    public func lineHistory(path: String, start: Int, end: Int, limit: Int = 100) async throws -> [GitLineHistoryEntry] {
        guard start >= 1, end >= start, !path.hasPrefix("-") else { throw GitError.invalidRequest("Select some lines first.") }
        let marker = "\u{1d}"
        let out = try await readOnly([
            "log", "--no-color", "-n", "\(limit)", "-L", "\(start),\(end):\(path)",
            "--format=\(marker)" + GitLogParser.format
        ])
        var entries: [GitLineHistoryEntry] = []
        let remotes = await remotes()
        for chunk in out.text.components(separatedBy: marker).dropFirst() {
            guard let recordEnd = chunk.firstIndex(of: "\u{1e}") else { continue }
            let header = String(chunk[...recordEnd])
            guard let commit = GitLogParser.parse(header, remotes: remotes).first else { continue }
            let patch = String(chunk[chunk.index(after: recordEnd)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(GitLineHistoryEntry(commit: commit, patch: patch))
        }
        return entries
    }

    // MARK: - Interactive rebase

    /// The commits `base..HEAD`, oldest first, as plain picks: where an interactive rebase from
    /// `oldest` starts. Throws when the range holds a merge commit, or `oldest` is the root.
    public func rebasePlan(startingAt oldest: String) async throws -> (base: String, plan: GitRebasePlan) {
        guard !oldest.hasPrefix("-") else { throw GitError.invalidRequest("Enter a valid commit.") }
        guard let parent = try? await readOnly(["rev-parse", "-q", "--verify", oldest + "^"]) else {
            throw GitError.invalidRequest("The first commit of a repository cannot be rebased interactively from here.")
        }
        let base = parent.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let merges = try await readOnly(["rev-list", "--merges", "\(base)..HEAD"])
        if !merges.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GitError.invalidRequest("There is a merge commit in that range: rebase interactively from a commit above it.")
        }
        let out = try await readOnly(["log", "--reverse", "--format=%H%x00%s", "\(base)..HEAD"])
        let steps: [GitRebaseStep] = out.text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { return nil }
            return GitRebaseStep(hash: String(fields[0]), subject: String(fields[1]))
        }
        guard !steps.isEmpty else { throw GitError.invalidRequest("There are no commits to rebase.") }
        return (base, GitRebasePlan(steps: steps))
    }

    /// Runs `plan` onto `base` without opening an editor. Messages for rewords and squashes are
    /// written beside the git directory and applied by `exec` lines, which a stopped rebase still
    /// needs when it continues, so they stay until the next plan runs with nothing in progress.
    public func interactiveRebase(onto base: String, plan: GitRebasePlan) async throws -> GitIntegrationResult {
        if let problem = plan.validationProblem() { throw GitError.invalidRequest(problem) }
        guard state().operation == nil else {
            throw GitError.invalidRequest("Finish or abort the operation in progress first.")
        }
        guard !base.hasPrefix("-") else { throw GitError.invalidRequest("Enter a valid commit.") }
        let merges = try await readOnly(["rev-list", "--merges", "\(base)..HEAD"])
        if !merges.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GitError.invalidRequest("There is a merge commit in that range: rebase interactively from a commit above it.")
        }
        let range = try await readOnly(["rev-list", "\(base)..HEAD"])
        let current = Set(range.text.split(separator: "\n").map(String.init))
        guard current == Set(plan.steps.map(\.hash)) else {
            throw GitError.invalidRequest("The commits changed since the plan was made. Open it again.")
        }
        let folder = gitDirectory.appendingPathComponent("umbra-rebase", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        for index in plan.messageIndices {
            let message = plan.steps[index].message ?? ""
            try (message.hasSuffix("\n") ? message : message + "\n")
                .write(to: folder.appendingPathComponent("message-\(index)"), atomically: true, encoding: .utf8)
        }
        let todo = plan.todoText { folder.appendingPathComponent("message-\($0)").path }
        let todoURL = folder.appendingPathComponent("todo")
        try todo.write(to: todoURL, atomically: true, encoding: .utf8)
        // git runs this through a shell with the todo file's path appended.
        let editor = "cp \(GitRebasePlan.shellQuoted(todoURL.path))"
        return try await integrate(
            ["rebase", "--interactive", "--autostash", base],
            environment: ["GIT_SEQUENCE_EDITOR": editor, "GIT_EDITOR": "true"]
        )
    }
}
