import Foundation

public struct GitStash: Sendable, Hashable, Identifiable {
    /// The stash commit. Indices shift as stashes come and go; the hash does not.
    public let hash: String
    /// Position in the list at the time it was read: `stash@{index}`.
    public let index: Int
    public let date: Date
    /// git's own subject: `On main: my message` or `WIP on main: 1a2b3c4 subject`.
    public let subject: String

    public var id: String { hash }
    public var ref: String { "stash@{\(index)}" }

    /// The branch the stash was made on (`main`), nil when the subject has an unexpected shape.
    public var branch: String? {
        for prefix in ["WIP on ", "On ", "index on "] where subject.hasPrefix(prefix) {
            let rest = subject.dropFirst(prefix.count)
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            return String(rest[..<colon])
        }
        return nil
    }

    /// What to show as the stash's name: the user's message, or the commit subject git recorded.
    public var title: String {
        guard let colon = subject.firstIndex(of: ":") else { return subject }
        let message = subject[subject.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return message.isEmpty ? subject : message
    }

    public init(hash: String, index: Int, date: Date, subject: String) {
        self.hash = hash
        self.index = index
        self.date = date
        self.subject = subject
    }
}

/// One file a stash holds. Untracked files live on the stash's third parent.
public struct GitStashChange: Sendable, Hashable, Identifiable {
    public let file: GitChangedFile
    public let isUntracked: Bool

    public var id: String { (isUntracked ? "u:" : "t:") + file.path }

    public init(file: GitChangedFile, isUntracked: Bool) {
        self.file = file
        self.isUntracked = isUntracked
    }
}

/// `git stash list --format=<GitStashParser.format>`, one line each.
public enum GitStashParser {
    public static let format = "%H%x1f%ct%x1f%gs"

    public static func parse(_ output: String) -> [GitStash] {
        var stashes: [GitStash] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, fields[0].count >= 40 else { continue }
            stashes.append(GitStash(
                hash: fields[0],
                index: stashes.count,
                date: Date(timeIntervalSince1970: TimeInterval(fields[1]) ?? 0),
                subject: fields[2]
            ))
        }
        return stashes
    }
}

/// The stash: saving, listing, applying and dropping, and what a stash holds.
extension GitRepository {
    public func stashes() async throws -> [GitStash] {
        let out = try await readOnly(["stash", "list", "--format=" + GitStashParser.format])
        return GitStashParser.parse(out.text)
    }

    /// Saves tracked changes and, with `includeUntracked`, new files; with `keepIndex` what is staged
    /// stays in the working tree. `paths` limits it to those files. Returns true when a stash was
    /// created (git says "No local changes to save" and creates none for a clean tree).
    @discardableResult
    public func stashPush(
        message: String, includeUntracked: Bool = true, keepIndex: Bool = false, paths: [String] = []
    ) async throws -> Bool {
        let before = await stashTop()
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        if keepIndex { args.append("--keep-index") }
        args += ["-m", message]
        if !paths.isEmpty { args += ["--"] + paths }
        _ = try await mutate(args)
        let after = await stashTop()
        return after != nil && after != before
    }

    /// Applies the newest stash and drops it. On a conflict git keeps the stash and throws.
    public func stashPop() async throws -> String {
        report(try await mutate(["stash", "pop"]))
    }

    /// Applies `stash` and keeps it. With `reinstateIndex` what was staged is staged again.
    public func stashApply(_ stash: GitStash, reinstateIndex: Bool = false) async throws -> String {
        let ref = try await currentRef(of: stash)
        return report(try await mutate(["stash", "apply"] + (reinstateIndex ? ["--index"] : []) + [ref]))
    }

    /// Applies `stash` and drops it; a conflict keeps it.
    public func stashPop(_ stash: GitStash, reinstateIndex: Bool = false) async throws -> String {
        let ref = try await currentRef(of: stash)
        return report(try await mutate(["stash", "pop"] + (reinstateIndex ? ["--index"] : []) + [ref]))
    }

    public func stashDrop(_ stash: GitStash) async throws -> String {
        let ref = try await currentRef(of: stash)
        return report(try await mutate(["stash", "drop", ref]))
    }

    public func stashClear() async throws {
        _ = try await mutate(["stash", "clear"])
    }

    /// A new branch at the commit the stash was made on, with the stash applied and dropped.
    public func stashBranch(_ name: String, from stash: GitStash) async throws -> String {
        let branch = try validatedBranchName(name)
        let ref = try await currentRef(of: stash)
        return report(try await mutate(["stash", "branch", branch, ref]))
    }

    /// The files `stash` changes against the commit it was made on, plus the untracked files it saved.
    public func stashChanges(_ stash: GitStash) async throws -> [GitStashChange] {
        let tracked = try await readOnly(["diff", "--name-status", "-z", "-M", stash.hash + "^1", stash.hash, "--"])
        var changes = GitNameStatusParser.parse(tracked.text).map { GitStashChange(file: $0, isUntracked: false) }
        // `stash push --include-untracked` keeps new files on a third parent commit.
        if (try? await readOnly(["rev-parse", "-q", "--verify", stash.hash + "^3"])) != nil {
            let untracked = try await readOnly(["ls-tree", "-r", "--name-only", "-z", stash.hash + "^3"])
            for path in untracked.text.split(separator: "\0", omittingEmptySubsequences: true) {
                changes.append(GitStashChange(
                    file: GitChangedFile(status: "A", path: String(path), oldPath: nil), isUntracked: true))
            }
        }
        return changes
    }

    /// The commit the newest stash points at, nil when there is none.
    func stashTop() async -> String? {
        guard let out = try? await readOnly(["rev-parse", "-q", "--verify", "refs/stash"]) else { return nil }
        let hash = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? nil : hash
    }

    /// `stash@{n}` for `stash`'s commit as the list stands now: another stash may have been added or
    /// dropped since the caller read the list, which would move every index.
    private func currentRef(of stash: GitStash) async throws -> String {
        let current = try await stashes()
        guard let found = current.first(where: { $0.hash == stash.hash }) else {
            throw GitError.invalidRequest("That stash no longer exists.")
        }
        return found.ref
    }

    /// Runs `operation` with the working tree's changes set aside and put back afterwards:
    /// IntelliJ's "smart" checkout and update. When the operation fails the changes are restored
    /// before the error is rethrown, so a refused checkout leaves the tree as it was.
    public func preservingLocalChanges(
        message: String = "Umbra: local changes saved for a smart operation",
        _ operation: @Sendable () async throws -> String
    ) async throws -> (report: String, outcome: GitPreserveOutcome) {
        let saved = try await stashPush(message: message, includeUntracked: true)
        guard saved else {
            return (try await operation(), .completed)
        }
        let result: String
        do {
            result = try await operation()
        } catch {
            _ = try? await stashPop()
            throw error
        }
        do {
            _ = try await stashPop()
            return (result, .completed)
        } catch {
            // A pop that conflicts applied what it could and kept the stash; one that could not
            // start (a locked index…) changed nothing.
            let conflicted = (try? await status())?.contains(where: \.isConflicted) ?? false
            return (result, conflicted ? .restoredWithConflicts : .keptInStash)
        }
    }
}
