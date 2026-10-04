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
            diff = OutputTruncation.headAndTail(diff, maxCharacters: Self.maxFileCharacters)
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
