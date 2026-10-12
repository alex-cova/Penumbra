import Foundation

/// Creating a repository: init and clone, with the helpers a clone dialog needs.
extension GitRepository {
    /// `repo` for `https://host/owner/repo.git`, `git@host:owner/repo.git`, `/path/to/repo/`, … : the
    /// folder name `git clone` would pick.
    public static func repositoryName(fromURL url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        // `host:owner/repo` has a colon where a path has a slash.
        let last = text.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        return last.trimmingCharacters(in: .whitespaces)
    }

    private static func validatedURL(_ url: String) throws -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else {
            throw GitError.invalidRequest("Enter the address of a repository.")
        }
        return trimmed
    }

    /// The environment for a command that has no repository yet.
    private static func environment(_ network: GitNetworkEnvironment, runner: any GitRunning, directory: URL) async -> [String: String] {
        var environment = network.variables
        guard network.failsInsteadOfPrompting, environment["GIT_SSH_COMMAND"] == nil else { return environment }
        var base = ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] ?? ""
        if base.isEmpty, let out = try? await runner.run(["config", "--global", "--get", "core.sshCommand"], in: directory) {
            base = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        environment["GIT_SSH_COMMAND"] = (base.isEmpty ? "ssh" : base) + " -o BatchMode=yes"
        return environment
    }

    /// Whether `url` answers as a git repository (`git ls-remote`), without cloning it.
    public static func checkRemote(
        url: String, network: GitNetworkEnvironment = .batchMode, runner: any GitRunning = SystemGitRunner()
    ) async throws {
        let address = try validatedURL(url)
        let directory = FileManager.default.temporaryDirectory
        let env = await environment(network, runner: runner, directory: directory)
        _ = try await runner.run(
            ["ls-remote", "--exit-code", "--heads", "--", address], in: directory, stdin: nil,
            environment: env, onProgress: nil)
    }

    /// Clones `url` into `destination` (which must not exist, or be empty). Progress lines reach
    /// `onProgress`. Cancelling the calling task stops git; the caller removes what it left behind.
    public static func clone(
        url: String, into destination: URL, recurseSubmodules: Bool = false,
        network: GitNetworkEnvironment = .batchMode, runner: any GitRunning = SystemGitRunner(),
        onProgress: GitProgressHandler? = nil
    ) async throws -> GitRepository {
        let address = try validatedURL(url)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
            guard isDirectory.boolValue, contents.isEmpty else {
                throw GitError.invalidRequest("\(destination.lastPathComponent) already exists and is not empty.")
            }
        }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var args = ["clone", "--progress"]
        if recurseSubmodules { args.append("--recurse-submodules") }
        args += ["--", address, destination.path]
        let env = await environment(network, runner: runner, directory: parent)
        _ = try await runner.run(args, in: parent, stdin: nil, environment: env, onProgress: onProgress)
        return GitRepository(root: destination.standardizedFileURL, runner: runner, network: network)
    }

    /// `git init` in `directory` with `initialBranch` as the first branch.
    public static func initialize(
        at directory: URL, initialBranch: String = "main", runner: any GitRunning = SystemGitRunner()
    ) async throws -> GitRepository {
        guard !initialBranch.isEmpty, !initialBranch.hasPrefix("-") else { throw GitError.invalidBranchName }
        _ = try await runner.run(["init", "-q", "-b", initialBranch], in: directory)
        return GitRepository(root: directory.standardizedFileURL, runner: runner)
    }
}

/// Lines for `.gitignore` and `.git/info/exclude`.
public enum GitIgnoreWriter {
    /// The pattern that ignores `relativePath` (relative to the ignore file's directory) and only
    /// it: anchored with a leading `/`, a folder with a trailing `/`, git's special characters escaped.
    public static func pattern(forRelativePath path: String, isDirectory: Bool) -> String {
        var escaped = ""
        for character in path {
            if "\\*?[]".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        if escaped.hasPrefix("#") || escaped.hasPrefix("!") { escaped = "\\" + escaped }
        // Trailing spaces are dropped by git unless each one is escaped.
        let trailingSpaces = escaped.reversed().prefix(while: { $0 == " " }).count
        if trailingSpaces > 0 {
            escaped = String(escaped.dropLast(trailingSpaces)) + String(repeating: "\\ ", count: trailingSpaces)
        }
        let trailing = isDirectory && !escaped.hasSuffix("/") ? "/" : ""
        return "/" + escaped + trailing
    }

    /// `existing` with `pattern` on a line of its own, or nil when that line is already there.
    public static func appending(_ pattern: String, to existing: String) -> String? {
        let lines = existing.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(pattern) { return nil }
        var text = existing
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        return text + pattern + "\n"
    }
}
