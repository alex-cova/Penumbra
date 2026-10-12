import Foundation

/// Branches, tags, config and comparing two revisions.
extension GitRepository {
    // MARK: - Branches

    /// Every local and remote-tracking branch, with its upstream and how far it is from it.
    public func branchList() async throws -> [GitBranch] {
        let out = try await readOnly(["for-each-ref", "--format=" + GitBranchParser.format, "refs/heads", "refs/remotes"])
        return GitBranchParser.parse(out.text)
    }

    /// `main`, `master` or whatever `origin/HEAD` points to; nil when there is no obvious one.
    public func defaultBranchName() async -> String? {
        if let out = try? await readOnly(["symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"]) {
            let name = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("origin/") { return String(name.dropFirst("origin/".count)) }
        }
        let locals = ((try? await branchList()) ?? []).filter { $0.kind == .local }.map(\.name)
        for candidate in ["main", "master", "trunk", "develop"] where locals.contains(candidate) { return candidate }
        return nil
    }

    public func renameBranch(_ name: String, to newName: String) async throws -> String {
        let old = try validatedBranchName(name)
        let new = try validatedBranchName(newName)
        return report(try await mutate(["branch", "-m", "--", old, new]))
    }

    /// `force` deletes a branch that is not merged (`-D`); without it git refuses.
    public func deleteBranch(_ name: String, force: Bool = false) async throws -> String {
        let branch = try validatedBranchName(name)
        return report(try await mutate(["branch", force ? "-D" : "-d", "--", branch]))
    }

    /// Deletes `branch` on `remote` (`git push <remote> --delete <branch>`).
    public func deleteRemoteBranch(remote: String, branch: String) async throws -> String {
        let remoteName = try validatedBranchName(remote)
        let branchName = try validatedBranchName(branch)
        return report(try await mutate(["push", remoteName, "--delete", branchName], network: true))
    }

    /// Creates a local branch that tracks `remoteBranch` (`origin/feature`) and switches to it.
    public func checkoutRemoteBranch(_ remoteBranch: String, localName: String? = nil) async throws -> String {
        let remoteRef = try validatedBranchName(remoteBranch)
        guard let slash = remoteRef.firstIndex(of: "/") else {
            throw GitError.invalidRequest("\(remoteRef) is not a remote branch.")
        }
        let local = try validatedBranchName(localName ?? String(remoteRef[remoteRef.index(after: slash)...]))
        return report(try await mutate(["switch", "-c", local, "--track", remoteRef]))
    }

    /// `name` at `startPoint` (HEAD when nil), switched to unless `checkout` is false.
    public func createBranch(_ name: String, startPoint: String?, checkout: Bool = true) async throws -> String {
        let branch = try validatedBranchName(name)
        var args = checkout ? ["switch", "-c", branch] : ["branch", branch]
        if let startPoint {
            guard !startPoint.isEmpty, !startPoint.hasPrefix("-") else { throw GitError.invalidRequest("Enter a valid starting point.") }
            args.append(startPoint)
        }
        return report(try await mutate(args))
    }

    /// Detaches HEAD at a commit, tag or any revision.
    public func checkout(revision: String) async throws -> String {
        guard !revision.isEmpty, !revision.hasPrefix("-") else { throw GitError.invalidRequest("Enter a valid revision.") }
        return report(try await mutate(["switch", "--detach", revision]))
    }

    /// Local branches already merged into `base`, without `base` itself.
    public func mergedBranches(into base: String) async throws -> [String] {
        let ref = try validatedBranchName(base)
        let out = try await readOnly(["branch", "--merged", ref, "--format=%(refname:short)"])
        return out.text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != ref && !$0.hasPrefix("(") }
    }

    // MARK: - Tags

    public func tags() async throws -> [GitTag] {
        let out = try await readOnly(["for-each-ref", "--format=" + GitTagParser.format, "--sort=-creatordate", "refs/tags"])
        return GitTagParser.parse(out.text)
    }

    /// An annotated tag when `message` is given, else a lightweight one. `revision` defaults to HEAD.
    public func createTag(_ name: String, at revision: String? = nil, message: String? = nil) async throws {
        let tag = try validatedBranchName(name)
        var args = ["tag"]
        if let message, !message.isEmpty { args += ["-a", "-m", message] }
        args.append(tag)
        if let revision {
            guard !revision.isEmpty, !revision.hasPrefix("-") else { throw GitError.invalidRequest("Enter a valid revision.") }
            args.append(revision)
        }
        _ = try await mutate(args)
    }

    public func deleteTag(_ name: String) async throws {
        _ = try await mutate(["tag", "-d", try validatedBranchName(name)])
    }

    public func pushTag(_ name: String, remote: String = "origin") async throws -> String {
        let tag = try validatedBranchName(name)
        let remoteName = try validatedBranchName(remote)
        return report(try await mutate(["push", remoteName, "refs/tags/\(tag)"], network: true))
    }

    // MARK: - Config

    /// The effective value of `key` (`user.name`, `pull.rebase`), nil when it is not set.
    public func config(_ key: String) async -> String? {
        guard !key.hasPrefix("-"), let out = try? await readOnly(["config", "--get", key]) else { return nil }
        let value = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Sets `key` for this repository, or for the user when `global` is true.
    public func setConfig(_ key: String, to value: String, global: Bool = false) async throws {
        guard !key.isEmpty, !key.hasPrefix("-") else { throw GitError.invalidRequest("Enter a valid setting name.") }
        _ = try await mutate(["config"] + (global ? ["--global"] : []) + [key, value])
    }

    // MARK: - Compare

    /// The commits only in `left`, only in `right`, and the files that differ between the two tips.
    public func compare(_ left: String, _ right: String, commitLimit: Int = 500) async throws -> GitComparison {
        let leftRef = try validatedBranchName(left)
        let rightRef = try validatedBranchName(right)
        async let onlyLeft = commits(in: "\(rightRef)..\(leftRef)", limit: commitLimit)
        async let onlyRight = commits(in: "\(leftRef)..\(rightRef)", limit: commitLimit)
        let diff = try await readOnly(["diff", "--name-status", "-z", "-M", leftRef, rightRef, "--"])
        return GitComparison(
            left: leftRef, right: rightRef,
            onlyInLeft: try await onlyLeft, onlyInRight: try await onlyRight,
            files: GitNameStatusParser.parse(diff.text)
        )
    }
}
