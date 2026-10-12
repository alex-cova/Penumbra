import Foundation

/// Fetch, pull and push: the commands that talk to another repository. They run with the
/// repository's `network` environment and report progress while they work.
extension GitRepository {
    /// What git printed: progress and notices go to stderr, so that wins when there is any.
    func report(_ output: GitOutput) -> String {
        output.stderr.isEmpty ? output.text : output.stderr
    }

    /// Runs a command that changes the repository, with network credentials when `network` is set.
    func mutate(
        _ args: [String], network usesNetwork: Bool = false, extraEnvironment: [String: String] = [:],
        stdin: Data? = nil, onProgress: GitProgressHandler? = nil
    ) async throws -> GitOutput {
        var environment = usesNetwork ? await networkEnvironment() : [:]
        environment.merge(extraEnvironment) { _, new in new }
        return try await runner.run(
            args, in: root, stdin: stdin, environment: environment.isEmpty ? nil : environment,
            onProgress: onProgress ?? progress
        )
    }

    public func remoteDetails() async -> [GitRemote] {
        guard let out = try? await readOnly(["remote", "-v"]) else { return [] }
        return GitRemoteParser.parse(out.text)
    }

    /// `fetch` of one remote, or of all of them when `remote` is nil. `prune` drops remote-tracking
    /// branches that no longer exist on the remote.
    @discardableResult
    public func fetch(remote: String? = nil, prune: Bool = true, onProgress: GitProgressHandler? = nil) async throws -> String {
        var args = ["fetch", "--progress"]
        if prune { args.append("--prune") }
        if let remote {
            guard !remote.isEmpty, !remote.hasPrefix("-") else { throw GitError.invalidRequest("Enter a valid remote name.") }
            args.append(remote)
        } else {
            args.append("--all")
        }
        return report(try await mutate(args, network: true, onProgress: onProgress))
    }

    /// Updates the current branch from its upstream. `autostash` saves and restores uncommitted
    /// changes around a merge or rebase; a fast-forward needs neither.
    @discardableResult
    public func pull(strategy: GitPullStrategy, autostash: Bool = false, onProgress: GitProgressHandler? = nil) async throws -> String {
        var args = ["pull", "--progress"]
        switch strategy {
        case .fastForwardOnly: args.append("--ff-only")
        case .merge: args += ["--no-rebase", "--no-edit"]
        case .rebase: args.append("--rebase")
        }
        if autostash { args.append("--autostash") }
        // No editor can open for a merge message or a rebase todo: nothing would answer it.
        return report(try await mutate(args, network: true, extraEnvironment: ["GIT_EDITOR": "true"], onProgress: onProgress))
    }

    @discardableResult
    public func push(_ options: GitPushOptions, onProgress: GitProgressHandler? = nil) async throws -> String {
        var args = ["push", "--progress"]
        if options.setUpstream { args.append("--set-upstream") }
        if options.forceWithLease { args.append("--force-with-lease") }
        switch options.tags {
        case .none: break
        case .following: args.append("--follow-tags")
        case .all: args.append("--tags")
        }
        let needsRemote = options.setUpstream || options.targetBranch != nil || options.source != "HEAD"
        if let remote = options.remote ?? (needsRemote ? "origin" : nil) {
            guard !remote.isEmpty, !remote.hasPrefix("-") else { throw GitError.invalidRequest("Enter a valid remote name.") }
            args.append(remote)
            guard !options.source.isEmpty, !options.source.hasPrefix("-") else {
                throw GitError.invalidRequest("Choose what to push.")
            }
            if let target = options.targetBranch {
                let branch = try validatedBranchName(target)
                args.append("\(options.source):refs/heads/\(branch)")
            } else {
                args.append(options.source)
            }
        }
        return report(try await mutate(args, network: true, onProgress: onProgress))
    }

    /// The commits `range` selects (`a..b`), newest first.
    public func commits(in range: String, limit: Int = 500) async throws -> [GitCommit] {
        guard !range.hasPrefix("-") else { throw GitError.invalidRequest("Enter a valid revision range.") }
        let args = ["log", "--date-order", "--format=" + GitLogParser.format, "-n", "\(limit)", range, "--"]
        let out = try await readOnly(args)
        return GitLogParser.parse(out.text, remotes: await remotes())
    }
}
