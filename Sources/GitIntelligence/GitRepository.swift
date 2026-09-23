import Foundation

public enum GitLogScope: Sendable, Hashable {
    case all
    case head
    case branch(String)
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

    public func status() async throws -> [GitStatusEntry] {
        let out = try await readOnly(["status", "--porcelain=v1", "-z", "--untracked-files=normal"])
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

    public func log(scope: GitLogScope = .all, grep: String? = nil, skip: Int = 0, limit: Int = 500) async throws -> [GitCommit] {
        var args = ["log", "--date-order", "--format=" + GitLogParser.format, "--skip=\(skip)", "-n", "\(limit)"]
        if let grep, !grep.isEmpty { args += ["--grep=\(grep)", "-i"] }
        switch scope {
        case .all: args += ["--all", "--decorate=short"]
        case .head: args += ["HEAD", "--decorate=short"]
        case .branch(let name): args += [name, "--decorate=short"]
        }
        args.append("--")
        let out = try await readOnly(args)
        return GitLogParser.parse(out.text, remotes: await remotes())
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

    /// Commits only `paths` (plus any `untrackedPaths`, which are added first), whatever else is staged.
    public func commit(message: String, paths: [String], untrackedPaths: [String], amend: Bool) async throws -> String {
        if !untrackedPaths.isEmpty {
            _ = try await runner.run(["add", "--"] + untrackedPaths, in: root, stdin: nil, environment: nil)
        }
        var args = ["commit", "--only"]
        if amend { args.append("--amend") }
        args += ["-m", message, "--"] + paths
        let out = try await runner.run(args, in: root, stdin: nil, environment: nil)
        return out.text
    }

    public func push() async throws -> String {
        let hasUpstream = (try? await runner.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: root, stdin: nil, environment: nil)) != nil
        let args = hasUpstream ? ["push"] : ["push", "-u", "origin", "HEAD"]
        let out = try await runner.run(args, in: root, stdin: nil, environment: Self.nonInteractive)
        // git reports push progress on stderr.
        return out.stderr.isEmpty ? out.text : out.stderr
    }
}
