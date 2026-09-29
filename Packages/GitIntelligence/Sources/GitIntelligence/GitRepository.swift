import Foundation

public enum GitLogScope: Sendable, Hashable {
    case all
    case head
    case branch(String)
}

/// What ``GitRepository/revert(paths:)`` did: `skipped` paths have no committed version and were left alone.
public struct GitRevertResult: Sendable, Equatable {
    public let reverted: [String]
    public let skipped: [String]

    public init(reverted: [String], skipped: [String]) {
        self.reverted = reverted
        self.skipped = skipped
    }
}

/// Thin, stateless wrapper over the git CLI for one working tree. Every method is one or two git
/// invocations; nothing runs unless the host calls it.
public struct GitRepository: Sendable {
    public let root: URL
    private let runner: any GitRunning

    /// Fails fast instead of waiting on a prompt nobody can answer.
    private static let nonInteractive = [
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_SSH_COMMAND": "ssh -o BatchMode=yes"
    ]

    public init(root: URL, runner: any GitRunning = SystemGitRunner()) {
        self.root = root
        self.runner = runner
    }

    /// The repository containing `directory`, or nil when it is not inside a work tree.
    public static func discover(from directory: URL, runner: any GitRunning = SystemGitRunner()) async -> GitRepository? {
        guard let output = try? await runner.run(["rev-parse", "--show-toplevel"], in: directory),
              case let path = output.text.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        return GitRepository(root: URL(fileURLWithPath: path).standardizedFileURL, runner: runner)
    }

    private func readOnly(_ args: [String], stdin: Data? = nil) async throws -> GitOutput {
        try await runner.run(["--no-optional-locks"] + args, in: root, stdin: stdin, environment: nil)
    }

    // MARK: - Queries

    public func currentBranch() async -> String? {
        if let out = try? await readOnly(["symbolic-ref", "--short", "-q", "HEAD"]) {
            let name = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        if let out = try? await readOnly(["rev-parse", "--short", "HEAD"]) {
            let sha = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return sha }
        }
        return nil
    }

    /// The current branch against its upstream, from the remote-tracking ref as last fetched (nothing
    /// touches the network). Nil when the branch has no upstream.
    public func syncStatus(commitLimit: Int = 50) async -> GitSyncStatus? {
        guard let upstreamOut = try? await readOnly(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]),
              case let upstream = upstreamOut.text.trimmingCharacters(in: .whitespacesAndNewlines),
              !upstream.isEmpty,
              let countsOut = try? await readOnly(["rev-list", "--left-right", "--count", "HEAD...@{u}"])
        else { return nil }
        let counts = countsOut.text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard counts.count == 2 else { return nil }
        let (ahead, behind) = (counts[0], counts[1])
        var outgoing: [GitCommit] = []
        var incoming: [GitCommit] = []
        if ahead > 0 || behind > 0 {
            let remotes = await remotes()
            func commits(_ range: String) async -> [GitCommit] {
                let args = ["log", "--date-order", "--format=" + GitLogParser.format, "-n", "\(commitLimit)", range, "--"]
                guard let out = try? await readOnly(args) else { return [] }
                return GitLogParser.parse(out.text, remotes: remotes)
            }
            if ahead > 0 { outgoing = await commits("@{u}..HEAD") }
            if behind > 0 { incoming = await commits("HEAD..@{u}") }
        }
        return GitSyncStatus(upstream: upstream, ahead: ahead, behind: behind, outgoing: outgoing, incoming: incoming)
    }

    /// Porcelain status. `includingIgnored` adds `--ignored`, which the default omits.
    public func status(includingIgnored: Bool = false) async throws -> [GitStatusEntry] {
        var args = ["status", "--porcelain=v1", "-z", "--untracked-files=normal"]
        if includingIgnored { args.append("--ignored") }
        let out = try await readOnly(args)
        return GitStatusParser.parse(out.text)
    }

    public func remotes() async -> Set<String> {
        guard let out = try? await readOnly(["remote"]) else { return [] }
        return Set(out.text.split(separator: "\n").map { String($0) })
    }

    public func branches() async throws -> [GitRef] {
        let out = try await readOnly(["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"])
        var refs: [GitRef] = []
        for line in out.text.split(separator: "\n") {
            if line.hasPrefix("refs/heads/") {
                refs.append(GitRef(name: String(line.dropFirst("refs/heads/".count)), kind: .localBranch))
            } else if line.hasPrefix("refs/remotes/") {
                let name = String(line.dropFirst("refs/remotes/".count))
                if name.hasSuffix("/HEAD") { continue }
                refs.append(GitRef(name: name, kind: .remoteBranch))
            }
        }
        return refs
    }

    /// - Parameter path: a file to follow through renames, relative to the repository root. The
    ///   log then holds only the commits that touched it, so its graph lanes would dangle.
    public func log(scope: GitLogScope = .all, grep: String? = nil, author: String? = nil, path: String? = nil, skip: Int = 0, limit: Int = 500) async throws -> [GitCommit] {
        var args = ["log", "--date-order", "--format=" + GitLogParser.format, "--skip=\(skip)", "-n", "\(limit)"]
        if path != nil { args.append("--follow") }
        if let grep, !grep.isEmpty { args += ["--grep=\(grep)", "-i"] }
        if let author, !author.isEmpty { args.append("--author=\(author)") }
        switch scope {
        case .all: args += ["--all", "--decorate=short"]
        case .head: args += ["HEAD", "--decorate=short"]
        case .branch(let name): args += [name, "--decorate=short"]
        }
        args.append("--")
        if let path { args.append(path) }
        let out = try await readOnly(args)
        return GitLogParser.parse(out.text, remotes: await remotes())
    }

    /// Whether `relativePath` is in the last commit, i.e. has a committed version to go back to.
    public func existsInHead(relativePath: String) async -> Bool {
        (try? await readOnly(["cat-file", "-e", "HEAD:" + relativePath])) != nil
    }

    /// The members of `relativePaths` that are files in `HEAD`, from one `ls-tree` per chunk rather
    /// than one process per path. Paths are literal: `*` and `?` in a file name match themselves.
    public func pathsInHead(_ relativePaths: [String]) async -> Set<String> {
        let wanted = Set(relativePaths)
        var found = Set<String>()
        for chunk in Self.chunks(Array(wanted)) {
            let args = ["--literal-pathspecs", "ls-tree", "-r", "-z", "--name-only", "HEAD", "--"] + chunk
            guard let out = try? await readOnly(args) else { continue }
            for name in out.text.split(separator: "\0") where wanted.contains(String(name)) {
                found.insert(String(name))
            }
        }
        return found
    }

    /// Long path lists go to git in pieces so a "revert everything" cannot hit the argument limit.
    private static let pathsPerInvocation = 200

    private static func chunks(_ paths: [String]) -> [[String]] {
        stride(from: 0, to: paths.count, by: pathsPerInvocation).map {
            Array(paths[$0..<min($0 + pathsPerInvocation, paths.count)])
        }
    }

    public func commit(hash: String) async throws -> (commit: GitCommit, body: String)? {
        let args = ["show", "-s", "--format=" + GitLogParser.format + "%B", hash]
        let out = try await readOnly(args)
        let text = out.text
        guard let separator = text.firstIndex(of: "\u{1e}") else { return nil }
        let head = String(text[...separator])
        let body = String(text[text.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let commit = GitLogParser.parse(head, remotes: await remotes()).first else { return nil }
        return (commit, body)
    }

    public func commitChanges(hash: String) async throws -> [GitChangedFile] {
        let out = try await readOnly(["diff-tree", "--root", "-r", "-M", "--name-status", "-z", "--no-commit-id", hash])
        return GitNameStatusParser.parse(out.text)
    }

    public func commitDiff(hash: String, path: String) async throws -> String {
        try await readOnly(["show", "--format=", "-M", "--first-parent", hash, "--", path]).text
    }

    public func unstagedDiff(path: String) async throws -> String {
        try await readOnly(["diff", "--", path]).text
    }

    public func stagedDiff(path: String) async throws -> String {
        try await readOnly(["diff", "--cached", "--", path]).text
    }

    /// `git show --stat --patch` for the commit detail pane.
    public func show(hash: String) async throws -> String {
        try await readOnly(["show", "--no-color", "--stat", "--patch", hash]).text
    }

    public func authors(limit: Int = 5000) async throws -> [String] {
        let out = try await readOnly(["log", "--all", "-n", "\(limit)", "--format=%an"])
        var seen = Set<String>()
        return out.text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).filter { seen.insert($0).inserted }.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    public func workingTreeDiff(path: String, isUntracked: Bool) async throws -> String {
        guard isUntracked else { return try await readOnly(["diff", "HEAD", "--", path]).text }
        do {
            return try await readOnly(["diff", "--no-index", "--", "/dev/null", path]).text
        } catch GitError.failed(let status, _, let stdout) where status == 1 {
            // `--no-index` exits 1 when the files differ, which is the normal case here.
            return String(decoding: stdout, as: UTF8.self)
        }
    }

    /// Blame of `relativePath`, using `contents` (the live buffer) so unsaved edits read as uncommitted.
    public func blame(relativePath: String, contents: Data) async throws -> [GitBlameLine] {
        let out = try await readOnly(["blame", "--porcelain", "--contents", "-", "--", relativePath], stdin: contents)
        return GitBlameParser.parse(out.text)
    }

    public func lastCommitMessage() async -> String? {
        guard let out = try? await readOnly(["log", "-1", "--format=%B"]) else { return nil }
        let text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Mutations

    public func stage(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runner.run(["add", "--"] + paths, in: root, stdin: nil, environment: nil)
    }

    public func unstage(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runner.run(["restore", "--staged", "--"] + paths, in: root, stdin: nil, environment: nil)
    }

    public func stageAll() async throws {
        _ = try await runner.run(["add", "-A"], in: root, stdin: nil, environment: nil)
    }

    public func unstageAll() async throws {
        _ = try await runner.run(["restore", "--staged", "."], in: root, stdin: nil, environment: nil)
    }

    /// Commits only `paths` (plus any `untrackedPaths`, which are added first), whatever else is staged.
    public func commit(message: String, paths: [String], untrackedPaths: [String], amend: Bool) async throws -> String {
        if !untrackedPaths.isEmpty {
            _ = try await runner.run(["add", "--"] + untrackedPaths, in: root, stdin: nil, environment: nil)
        }
        // `--only` commits just `paths` and is an error without any; with none, commit what is staged.
        var args = ["commit"]
        if !paths.isEmpty { args.append("--only") }
        if amend { args.append("--amend") }
        args += ["-m", message]
        if !paths.isEmpty { args += ["--"] + paths }
        let out = try await runner.run(args, in: root, stdin: nil, environment: nil)
        return out.text
    }

    /// Puts `paths` back to their last committed content, in the index and in the working tree,
    /// discarding both staged and unstaged changes. Every path must exist in `HEAD` (see
    /// ``pathsInHead(_:)``): git refuses a file that was never committed, and this changes nothing
    /// when it does. Use ``revert(paths:)`` to skip such files instead.
    public func revertToHead(paths: [String]) async throws {
        for chunk in Self.chunks(paths) {
            _ = try await runner.run(
                ["--literal-pathspecs", "restore", "--source=HEAD", "--staged", "--worktree", "--"] + chunk,
                in: root, stdin: nil, environment: nil
            )
        }
    }

    /// Reverts the paths that have a committed version and reports the rest as skipped (untracked,
    /// or staged as new): there is nothing for them to go back to.
    public func revert(paths: [String]) async throws -> GitRevertResult {
        let inHead = await pathsInHead(paths)
        var seen = Set<String>()
        let unique = paths.filter { seen.insert($0).inserted }
        let reverted = unique.filter { inHead.contains($0) }
        let skipped = unique.filter { !inHead.contains($0) }
        try await revertToHead(paths: reverted)
        return GitRevertResult(reverted: reverted, skipped: skipped)
    }

    public func push() async throws -> String {
        let hasUpstream = (try? await runner.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: root, stdin: nil, environment: nil)) != nil
        let args = hasUpstream ? ["push"] : ["push", "-u", "origin", "HEAD"]
        let out = try await runner.run(args, in: root, stdin: nil, environment: Self.nonInteractive)
        // git reports push progress on stderr.
        return out.stderr.isEmpty ? out.text : out.stderr
    }

    /// Checks out a local branch. Refuses to discard or overwrite local changes; git's error is returned as-is.
    public func switchBranch(_ name: String) async throws -> String {
        let branch = try validatedBranchName(name)
        let out = try await runner.run(["switch", "--", branch], in: root, stdin: nil, environment: nil)
        return out.stderr.isEmpty ? out.text : out.stderr
    }

    /// Creates `name` at `HEAD` and switches to it. A name that starts with `-` is rejected before git runs.
    public func createBranch(_ name: String) async throws -> String {
        let branch = try validatedBranchName(name)
        let out = try await runner.run(["switch", "-c", branch], in: root, stdin: nil, environment: nil)
        return out.stderr.isEmpty ? out.text : out.stderr
    }

    /// Fast-forward only. A diverged branch fails and leaves the history unmerged.
    public func pull() async throws -> String {
        let out = try await runner.run(["pull", "--ff-only"], in: root, stdin: nil, environment: Self.nonInteractive)
        return out.stderr.isEmpty ? out.text : out.stderr
    }

    private func validatedBranchName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { throw GitError.invalidBranchName }
        return trimmed
    }
}
