import AgentKit
import Foundation
import GitIntelligence

/// Lets the agent session see what a command did to the project (`WorkspaceSnapshotter`), so Revert
/// Run and Rewind cover it like an edit.
///
/// A snapshot is a git tree object built from a private copy of the repository's index
/// (`GIT_INDEX_FILE`): `git add -A` into that copy, then `git write-tree`. The user's index and
/// working tree are never touched, `.gitignore` decides what is followed (so build output is not),
/// and the copy is kept for the life of the chat so the next capture only hashes what changed. The
/// blobs it writes are unreachable objects that `git gc` collects.
///
/// Fails open everywhere: not a repository, git missing, a slow repository or any error means
/// `nil`, and the run goes on with only its edits recorded. Not a hot path: it runs around an
/// approved command, never from typing.
actor IDEAgentGitSnapshotter: WorkspaceSnapshotter {
    /// A file bigger than this is named but not kept, as a hash would not bring it back.
    static let maxTextBytes = 1_000_000
    /// More changed files than this are not followed (a build that writes unignored output).
    static let maxChanges = 200
    /// A capture slower than this turns the feature off for the chat (a very large repository).
    static let slowCapture: Duration = .seconds(4)

    private struct Layout {
        var prefix: String
        var index: URL
        var directory: URL
    }

    private let projectRoot: URL
    private let runner: any GitRunning
    private var layout: Layout?
    private var unavailable = false

    init(projectRoot: URL, runner: any GitRunning = SystemGitRunner()) {
        self.projectRoot = projectRoot
        self.runner = runner
    }

    deinit {
        if let directory = layout?.directory { try? FileManager.default.removeItem(at: directory) }
    }

    func capture() async -> SnapshotToken? {
        guard !unavailable else { return nil }
        let started = ContinuousClock.now
        let layout: Layout
        do {
            layout = try await prepare()
        } catch {
            // Not a repository (or no git): every command would only pay for the same two failed calls.
            if !Task.isCancelled { unavailable = true }
            return nil
        }
        do {
            let environment = ["GIT_INDEX_FILE": layout.index.path]
            _ = try await git(["add", "-A", "--ignore-errors", "--", "."], environment)
            let tree = try await git(["write-tree"], environment).text.trimmingCharacters(in: .whitespacesAndNewlines)
            if ContinuousClock.now - started > Self.slowCapture { unavailable = true }
            return tree.isEmpty ? nil : SnapshotToken(id: tree)
        } catch {
            return nil
        }
    }

    func diff(from before: SnapshotToken, to after: SnapshotToken) async -> SnapshotDiff? {
        guard layout != nil else { return nil }
        guard let output = try? await git(
            ["diff-tree", "-r", "--relative", "--name-status", "--no-renames", "-z", before.id, after.id], [:])
        else { return nil }
        let fields = output.text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var changes: [SnapshotChange] = []
        var omitted = 0
        var index = 0
        while index + 1 < fields.count {
            let status = fields[index], path = fields[index + 1]
            index += 2
            let kind: SnapshotChange.Kind
            switch status.first {
            case "A": kind = .added
            case "D": kind = .deleted
            case "M", "T": kind = .modified
            default: continue
            }
            if changes.count < Self.maxChanges { changes.append(SnapshotChange(path: path, kind: kind)) } else { omitted += 1 }
        }
        return SnapshotDiff(changes: changes, omitted: omitted)
    }

    func text(of path: String, at snapshot: SnapshotToken) async -> SnapshotText {
        guard let layout else { return .unavailable }
        let spec = "\(snapshot.id):\(layout.prefix)\(path)"
        guard let sizeOutput = try? await git(["cat-file", "-s", spec], [:]) else { return .absent }
        guard let size = Int(sizeOutput.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return .unavailable }
        guard size <= Self.maxTextBytes else { return .unavailable }
        guard let blob = try? await git(["cat-file", "blob", spec], [:]) else { return .unavailable }
        if blob.stdout.contains(0) { return .unavailable }
        guard let text = String(data: blob.stdout, encoding: .utf8) else { return .unavailable }
        return .text(text)
    }

    // MARK: - Setup

    private func prepare() async throws -> Layout {
        if let layout { return layout }
        let prefix = try await git(["rev-parse", "--show-prefix"], [:]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let gitDirectory = try await git(["rev-parse", "--absolute-git-dir"], [:]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gitDirectory.isEmpty else { throw GitError.notARepository }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-agent-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let index = directory.appendingPathComponent("index")
        let source = URL(fileURLWithPath: gitDirectory).appendingPathComponent("index")
        // No index yet (a repository with nothing staged): `git add -A` builds one from scratch.
        if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.copyItem(at: source, to: index) }
        let made = Layout(prefix: prefix, index: index, directory: directory)
        layout = made
        return made
    }

    private func git(_ arguments: [String], _ environment: [String: String]) async throws -> GitOutput {
        // Line-ending conversion would make a blob differ from the file it came from.
        try await runner.run(
            ["-c", "core.autocrlf=false", "-c", "core.safecrlf=false"] + arguments,
            in: projectRoot, stdin: nil, environment: environment.isEmpty ? nil : environment)
    }
}
