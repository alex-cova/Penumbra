import AgentKit
import Foundation
import GitIntelligence

/// What the read-only git tools need, without a window: the project folder, the user's extra
/// protected-file globs, and the open buffers that haven't been saved (git can't see those).
struct IDEAgentGitSource: Sendable {
    var projectRoot: URL
    var secretPatterns: [GlobPattern] = []
    var unsavedBuffers: @Sendable () async -> [String: String] = { [:] }
    var runner: any GitRunning = SystemGitRunner()

    struct Change: Sendable {
        var entry: GitStatusEntry
        /// Relative to the project folder; the repository may be a parent of it.
        var path: String
    }

    struct Snapshot: Sendable {
        var repository: GitRepository
        var branch: String?
        var changes: [Change]
    }

    enum Failure: Error, LocalizedError {
        case notARepository
        case git(String)

        var errorDescription: String? {
            switch self {
            case .notARepository: "This project is not inside a git repository."
            case .git(let message): "git failed: \(message)"
            }
        }
    }

    func snapshot() async throws -> Snapshot {
        guard let repository = await GitRepository.discover(from: projectRoot, runner: runner) else { throw Failure.notARepository }
        let entries: [GitStatusEntry]
        do { entries = try await repository.status() } catch { throw Failure.git(error.localizedDescription) }
        let prefix = projectPrefix(in: repository)
        let changes = entries.compactMap { entry -> Change? in
            guard !entry.isIgnored, entry.path.hasPrefix(prefix) else { return nil }
            return Change(entry: entry, path: String(entry.path.dropFirst(prefix.count)))
        }
        return Snapshot(repository: repository, branch: await repository.currentBranch(), changes: changes)
    }

    /// git lists an untracked folder as one `dir/` entry. The diff tool needs its files, so the
    /// protected-file check (and the diff itself) apply to each of them.
    func expandingUntrackedFolders(_ changes: [Change], in snapshot: Snapshot, limit: Int = 200) async -> [Change] {
        let prefix = projectPrefix(in: snapshot.repository)
        var result: [Change] = []
        for change in changes {
            guard change.entry.isUntracked, change.path.hasSuffix("/") else { result.append(change); continue }
            let listing = try? await runner.run(
                ["--no-optional-locks", "ls-files", "--others", "--exclude-standard", "-z", "--", prefix + change.path],
                in: snapshot.repository.root, stdin: nil, environment: nil)
            let files = (listing?.text ?? "").split(separator: "\0").map(String.init).filter { $0.hasPrefix(prefix) }.prefix(limit)
            for file in files {
                result.append(Change(
                    entry: GitStatusEntry(path: file, originalPath: nil, indexCode: "?", worktreeCode: "?"),
                    path: String(file.dropFirst(prefix.count))))
            }
        }
        return result
    }

    /// "" when the project is the repository root, else "sub/folder/".
    func projectPrefix(in repository: GitRepository) -> String {
        let root = repository.root.resolvingSymlinksInPath().path
        let project = projectRoot.resolvingSymlinksInPath().path
        guard project.hasPrefix(root), project.count > root.count else { return "" }
        return String(project.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
    }

    func isProtected(_ path: String) -> Bool {
        SecretFilePolicy.isLikelySecret(path, extra: secretPatterns)
    }

    /// Absolute paths of the project's unsaved buffers, as project-relative paths.
    func dirtyPaths() async -> Set<String> {
        let root = projectRoot.resolvingSymlinksInPath().path + "/"
        return Set(await unsavedBuffers().keys.compactMap { key -> String? in
            let path = URL(fileURLWithPath: key).resolvingSymlinksInPath().path
            return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : nil
        })
    }
}

struct IDEGitStatusTool: AgentTool {
    static let maxEntries = 200
    let source: IDEAgentGitSource

    var risk: ToolRisk { .read }
    var definition: ToolDefinition {
        ToolDefinition(
            name: "git_status",
            description: """
            Show the current branch and the files git sees as changed, staged or untracked. Use it to \
            see what is already modified before editing, and what a run changed.
            """)
    }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let snapshot: IDEAgentGitSource.Snapshot
        do { snapshot = try await source.snapshot() } catch { throw ToolError(error.localizedDescription) }
        var lines = ["Branch: \(snapshot.branch ?? "(detached or unknown)")"]
        if snapshot.changes.isEmpty {
            lines.append("Working tree clean.")
        } else {
            lines.append("Changes (XY: X = staged, Y = not staged; M modified, A added, D deleted, R renamed, ?? untracked, U conflict):")
            for change in snapshot.changes.prefix(Self.maxEntries) {
                let code = change.entry.isUntracked ? "??" : "\(change.entry.indexCode)\(change.entry.worktreeCode)"
                lines.append("\(code) \(change.path)" + (change.entry.originalPath.map { " (from \($0))" } ?? ""))
            }
            if snapshot.changes.count > Self.maxEntries {
                lines.append("… and \(snapshot.changes.count - Self.maxEntries) more.")
            }
        }
        let dirty = await source.dirtyPaths()
        if !dirty.isEmpty {
            lines.append("Unsaved in the editor, so not reflected above: " + dirty.sorted().prefix(10).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}

struct IDEGitLogTool: AgentTool {
    static let defaultLimit = 20
    static let maxLimit = 50
    let source: IDEAgentGitSource

    var risk: ToolRisk { .read }
    var definition: ToolDefinition {
        ToolDefinition(
            name: "git_log",
            description: """
            Recent commits on the current branch: short hash, author, date and subject. Use it to \
            match the repository's message style before committing. Capped at 50 commits.
            """,
            parameters: [
                ToolParameter("path", .string, "Only commits touching this project-relative file.", optional: true),
                ToolParameter("limit", .integer, "How many commits. Default 20, at most 50.", optional: true),
            ])
    }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let limit = min(max((try arguments.optionalInt("limit")) ?? Self.defaultLimit, 1), Self.maxLimit)
        let path = try arguments.optionalString("path")
        let snapshot: IDEAgentGitSource.Snapshot
        do { snapshot = try await source.snapshot() } catch { throw ToolError(error.localizedDescription) }
        let prefix = source.projectPrefix(in: snapshot.repository)
        let commits: [GitCommit]
        do {
            commits = try await snapshot.repository.log(
                scope: .head, path: path.map { prefix + $0 }, limit: limit)
        } catch {
            throw ToolError(error.localizedDescription)
        }
        var lines = ["Branch: \(snapshot.branch ?? "(detached or unknown)")"]
        if commits.isEmpty {
            lines.append(path == nil ? "No commits." : "No commits touch \(path!).")
        } else {
            for commit in commits {
                lines.append("\(commit.shortHash) \(commit.author) \(Self.day(commit.date)) \(commit.subject)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct IDEGitCommitTool: AgentTool {
    let source: IDEAgentGitSource

    var risk: ToolRisk { .command }
    var definition: ToolDefinition {
        ToolDefinition(
            name: "git_commit",
            description: """
            Commit project-relative files with a message: stages `paths` and commits them, in-process \
            so the command sandbox does not matter. Every file is named explicitly; there is no \
            commit-everything. Hooks run and the commit is never amended. Credential files are refused.
            """,
            parameters: [
                ToolParameter("message", .string, "The commit message."),
                ToolParameter("paths", .array(of: .string), "Project-relative files to commit. At least one."),
                ToolParameter("signoff", .boolean, "Add a Signed-off-by trailer. Default follows the repo's config.", optional: true),
            ])
    }

    func permissionSubject(for arguments: ToolArguments) -> PermissionSubject {
        guard let paths = try? arguments.optionalStringArray("paths") else { return .none }
        return .paths(paths)
    }

    func approvalRequest(for arguments: ToolArguments, context: ToolContext) async -> ApprovalRequest? {
        guard let message = (try? arguments.optionalString("message")) ?? nil, !message.isEmpty,
              let paths = (try? arguments.optionalStringArray("paths")) ?? nil, !paths.isEmpty
        else { return nil }
        var notes = ["Message: \(message)"]
        let dirty = await source.dirtyPaths()
        let unsaved = paths.filter { dirty.contains($0) }
        if !unsaved.isEmpty {
            notes.append("Unsaved in the editor, so the commit sees the version on disk: " + unsaved.sorted().joined(separator: ", "))
        }
        return ApprovalRequest(
            title: "Commit \(paths.count == 1 ? "1 file" : "\(paths.count) files")",
            command: "git commit -m \"\(message.split(separator: "\n").first ?? "")\" -- \(paths.joined(separator: " "))",
            workingDirectory: source.projectRoot.path,
            reason: try? arguments.optionalString("reason"),
            notes: notes,
            suggestedRule: "git_commit")
    }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let message = (try arguments.optionalString("message"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !message.isEmpty else { throw ToolError("The commit message is empty.") }
        let paths = (try arguments.optionalStringArray("paths")) ?? []
        guard !paths.isEmpty else { throw ToolError("No files were named: `paths` must list every file to commit.") }
        let blocked = paths.filter { source.isProtected($0) }
        guard blocked.isEmpty else {
            throw ToolError("Not committed: \(blocked.sorted().joined(separator: ", ")) looks like it holds credentials.")
        }
        let snapshot: IDEAgentGitSource.Snapshot
        do { snapshot = try await source.snapshot() } catch { throw ToolError(error.localizedDescription) }
        let prefix = source.projectPrefix(in: snapshot.repository)
        let repoPaths = paths.map { prefix + $0 }
        let tracked = await snapshot.repository.pathsInHead(repoPaths)
        let untracked = repoPaths.filter { !tracked.contains($0) }
        let signoff: Bool
        if let asked = try arguments.optionalBool("signoff") {
            signoff = asked
        } else {
            let primary = await snapshot.repository.config("commit.signoff")
            let fallback = await snapshot.repository.config("format.signOff")
            signoff = (primary ?? fallback)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
        }
        do {
            let repository = snapshot.repository
            let output = try await GitMutationLane.shared.perform(gitDirectory: repository.gitDirectory) {
                try await repository.commitFiles(
                    message: message, paths: repoPaths, untrackedPaths: untracked, signoff: signoff)
            }
            return output.isEmpty ? "Committed \(paths.count == 1 ? "1 file" : "\(paths.count) files")." : output
        } catch {
            throw ToolError(error.localizedDescription)
        }
    }
}

struct IDEGitBranchTool: AgentTool {
    static let actions = ["create", "switch"]
    let source: IDEAgentGitSource

    var risk: ToolRisk { .command }
    var definition: ToolDefinition {
        ToolDefinition(
            name: "git_branch",
            description: """
            Create a branch and switch to it (`create`), or switch to an existing branch (`switch`). \
            Only those two: no deleting, no renaming, no force switching.
            """,
            parameters: [
                ToolParameter("action", .enumeration(Self.actions), "What to do."),
                ToolParameter("name", .string, "The branch name."),
            ])
    }

    func approvalRequest(for arguments: ToolArguments, context: ToolContext) async -> ApprovalRequest? {
        guard let action = (try? arguments.optionalString("action")) ?? nil,
              Self.actions.contains(action),
              let name = (try? arguments.optionalString("name")) ?? nil, !name.isEmpty
        else { return nil }
        let command = action == "create" ? "git switch -c \(name)" : "git switch \(name)"
        return ApprovalRequest(
            title: action == "create" ? "Create branch \(name)" : "Switch to \(name)",
            command: command, workingDirectory: source.projectRoot.path,
            reason: try? arguments.optionalString("reason"),
            suggestedRule: "git_branch")
    }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let action = try arguments.optionalString("action") ?? ""
        guard Self.actions.contains(action) else {
            throw ToolError("Unknown action \"\(action)\": use create or switch.")
        }
        let name = (try arguments.optionalString("name"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { throw ToolError("The branch name is empty.") }
        let snapshot: IDEAgentGitSource.Snapshot
        do { snapshot = try await source.snapshot() } catch { throw ToolError(error.localizedDescription) }
        do {
            let repository = snapshot.repository
            let output = try await GitMutationLane.shared.perform(gitDirectory: repository.gitDirectory) {
                action == "create"
                    ? try await repository.createBranch(name)
                    : try await repository.switchBranch(name)
            }
            return output.isEmpty ? (action == "create" ? "Created and switched to \(name)." : "Switched to \(name).") : output
        } catch {
            throw ToolError(error.localizedDescription)
        }
    }
}

struct IDEGitDiffTool: AgentTool {
    static let maxFileCharacters = 12_000
    static let maxTotalCharacters = 60_000
    let source: IDEAgentGitSource

    var risk: ToolRisk { .read }
    var definition: ToolDefinition {
        ToolDefinition(
            name: "git_diff",
            description: """
            Show what changed as unified diffs: every changed file (working tree against HEAD, untracked \
            files as new), or only `path`. With `staged` only what is staged. Large diffs are cut; pass a \
            `path` to see one file whole. Credential files are never shown.
            """,
            parameters: [
                ToolParameter("path", .string, "Only this project-relative file.", optional: true),
                ToolParameter("staged", .boolean, "Show only the staged changes. Default false.", optional: true),
            ])
    }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let path = try arguments.optionalString("path")
        let staged = try arguments.optionalBool("staged") ?? false
        if let path, source.isProtected(path) {
            throw ToolError("\(path) looks like it holds credentials, so its diff is not shown.")
        }
        let snapshot: IDEAgentGitSource.Snapshot
        do { snapshot = try await source.snapshot() } catch { throw ToolError(error.localizedDescription) }

        var changes = await source.expandingUntrackedFolders(snapshot.changes, in: snapshot)
        if let path {
            changes = changes.filter { $0.path == path || $0.path.hasPrefix(path.hasSuffix("/") ? path : path + "/") }
            if changes.isEmpty { return "No changes in \(path)." }
        }
        if staged { changes = changes.filter { !$0.entry.isUntracked && $0.entry.indexCode != " " } }
        let hidden = changes.filter { source.isProtected($0.path) }.map(\.path)
        changes = changes.filter { !source.isProtected($0.path) }
        if changes.isEmpty && hidden.isEmpty { return staged ? "Nothing is staged." : "No changes." }

        let prefix = source.projectPrefix(in: snapshot.repository)
        var output: [String] = []
        var total = 0
        var omitted = 0
        for change in changes {
            if Task.isCancelled { throw CancellationError() }
            if total >= Self.maxTotalCharacters { omitted += 1; continue }
            let repoPath = prefix + change.path
            var diff: String
            do {
                diff = staged
                    ? try await snapshot.repository.stagedDiff(path: repoPath)
                    : try await snapshot.repository.workingTreeDiff(path: repoPath, isUntracked: change.entry.isUntracked)
            } catch {
                output.append("[\(change.path): could not be diffed: \(error.localizedDescription)]")
                continue
            }
            if diff.isEmpty { continue }
            diff = await OutputTruncation.headAndTailSaving(diff, maxCharacters: Self.maxFileCharacters, context: context)
            total += diff.count
            output.append(diff.hasSuffix("\n") ? String(diff.dropLast()) : diff)
        }
        if omitted > 0 { output.append("[\(omitted) more changed \(omitted == 1 ? "file" : "files") not shown: ask for one with `path`.]") }
        if !hidden.isEmpty { output.append("[Not shown, credential files: \(hidden.joined(separator: ", "))]") }
        let dirty = await source.dirtyPaths().intersection(snapshot.changes.map(\.path))
        if !dirty.isEmpty {
            output.append("[Unsaved edits in the editor are not part of this diff: \(dirty.sorted().joined(separator: ", "))]")
        }
        return output.isEmpty ? "No changes." : output.joined(separator: "\n")
    }
}
