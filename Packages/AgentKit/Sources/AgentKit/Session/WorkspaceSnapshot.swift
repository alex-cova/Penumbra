import Foundation

/// A point in the project's files that the host can compare with another. Opaque to AgentKit.
public struct SnapshotToken: Sendable, Hashable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct SnapshotChange: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case added, modified, deleted }
    /// Project-relative, like every path the tools use.
    public let path: String
    public let kind: Kind

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

/// What differs between two snapshots. `omitted` counts changes the host left out because there were
/// too many to follow; they are not recorded and cannot be reverted.
public struct SnapshotDiff: Sendable, Hashable {
    public var changes: [SnapshotChange]
    public var omitted: Int

    public init(changes: [SnapshotChange], omitted: Int = 0) {
        self.changes = changes
        self.omitted = omitted
    }
}

/// A file's text at a snapshot.
public enum SnapshotText: Sendable, Hashable {
    case text(String)
    /// Not UTF-8 text, or too large to keep: the change is named but cannot be reverted.
    case unavailable
    /// The file does not exist at that snapshot.
    case absent
}

/// Lets the session see what a command did to the project's files. A command can run anything, so
/// the tools cannot say which files it touched; the host compares the files before and after
/// instead (Umbra: git tree objects through a private index, so the user's index and working tree
/// are untouched). AgentKit reads nothing from the disk here and runs no process: the host does.
///
/// Every method fails open. `nil` / `nil` diff means "could not tell", and the run goes on with the
/// command's changes unrecorded.
public protocol WorkspaceSnapshotter: Sendable {
    func capture() async -> SnapshotToken?
    func diff(from before: SnapshotToken, to after: SnapshotToken) async -> SnapshotDiff?
    func text(of path: String, at snapshot: SnapshotToken) async -> SnapshotText
}

/// Records what a command changed into the run's checkpoints so Revert Run and Rewind cover it.
enum CommandChangeTracker {
    /// Longest time one snapshot may take. A hung `git` must not hold the run.
    static let captureTimeout: TimeInterval = 5

    struct Outcome: Sendable {
        var recorded = 0
        /// Changed files that could not be recorded (binary, too large, too many, unreadable).
        var unrecorded: [String] = []
        var omitted = 0

        var note: String? {
            guard !unrecorded.isEmpty || omitted > 0 else { return nil }
            var parts: [String] = []
            if !unrecorded.isEmpty {
                let shown = unrecorded.prefix(5).joined(separator: ", ")
                let more = unrecorded.count > 5 ? " and \(unrecorded.count - 5) more" : ""
                parts.append("\(unrecorded.count) changed file\(unrecorded.count == 1 ? "" : "s") could not be recorded (binary or too large): \(shown)\(more)")
            }
            if omitted > 0 { parts.append("\(omitted) more changed files were not followed") }
            return "[Note from the editor, not from the user] This command changed files Revert Run cannot restore: "
                + parts.joined(separator: "; ") + "."
        }
    }

    /// Captures outside the caller's cancellation: Stop kills the command, but the files it already
    /// changed are still worth recording.
    static func capture(_ snapshotter: any WorkspaceSnapshotter) async -> SnapshotToken? {
        await Deadline.run(captureTimeout) { await snapshotter.capture() } ?? nil
    }

    static func record(
        snapshotter: any WorkspaceSnapshotter, before: SnapshotToken, after: SnapshotToken,
        scope: CheckpointScope, workspace: any AgentWorkspace, secretPatterns: [GlobPattern]
    ) async -> Outcome {
        var outcome = Outcome()
        guard before != after,
              let diff = await Deadline.run(captureTimeout, { await snapshotter.diff(from: before, to: after) }) ?? nil
        else { return outcome }
        outcome.omitted = diff.omitted
        for change in diff.changes {
            // What the agent may not write, or a credential file, is neither recorded nor offered back.
            if (try? workspace.checkWritable(path: change.path)) == nil { continue }
            if SecretFilePolicy.isLikelySecret(change.path, extra: secretPatterns) { continue }
            switch change.kind {
            case .added:
                guard case .text(let now) = await snapshotter.text(of: change.path, at: after),
                      await matchesDisk(now, path: change.path, workspace) else {
                    outcome.unrecorded.append(change.path)
                    continue
                }
                await scope.willChange(path: change.path, original: nil)
                await scope.didChange(path: change.path, written: now)
            case .modified:
                guard case .text(let was) = await snapshotter.text(of: change.path, at: before),
                      case .text(let now) = await snapshotter.text(of: change.path, at: after),
                      await matchesDisk(now, path: change.path, workspace)
                else {
                    outcome.unrecorded.append(change.path)
                    continue
                }
                await scope.willChange(path: change.path, original: was)
                await scope.didChange(path: change.path, written: now)
            case .deleted:
                guard case .text(let was) = await snapshotter.text(of: change.path, at: before) else {
                    outcome.unrecorded.append(change.path)
                    continue
                }
                await scope.willChange(path: change.path, original: was)
                await scope.didDelete(path: change.path)
            }
            outcome.recorded += 1
        }
        return outcome
    }

    /// A snapshot can differ from the file it came from (a line-ending or content filter, or the file
    /// changed again afterwards). Revert compares the file with what was written, so recording text
    /// the file does not hold would only produce a conflict later; name the file instead.
    private static func matchesDisk(_ text: String, path: String, _ workspace: any AgentWorkspace) async -> Bool {
        (try? await workspace.readText(path: path)) == text
    }
}
