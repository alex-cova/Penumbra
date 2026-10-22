import Foundation
import Testing
@testable import AgentKit

/// Compares the project directory itself, so the tests need no git. Tokens name an in-memory copy.
private final class DirectorySnapshotter: WorkspaceSnapshotter, @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()
    private var snapshots: [String: [String: Data]] = [:]
    var failCapture = false
    /// What `text(of:)` answers for the "after" side instead of the real content, like a git filter would.
    var alteredText: String?
    var maxTextBytes = 1_000_000

    init(root: URL) { self.root = root }

    func capture() async -> SnapshotToken? {
        if failCapture { return nil }
        var files: [String: Data] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey]
        // /var is a link to /private/var and the walker may spell the root either way, so the
        // relative path is whatever follows the (unique) root folder's name.
        let marker = "/" + root.lastPathComponent + "/"
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true,
                  let range = url.path.range(of: marker) else { continue }
            let relative = String(url.path[range.upperBound...])
            files[relative] = try? Data(contentsOf: url)
        }
        let id = UUID().uuidString
        lock.withLock { snapshots[id] = files }
        return SnapshotToken(id: id)
    }

    func diff(from before: SnapshotToken, to after: SnapshotToken) async -> SnapshotDiff? {
        let (a, b) = lock.withLock { (snapshots[before.id] ?? [:], snapshots[after.id] ?? [:]) }
        var changes: [SnapshotChange] = []
        for path in Set(a.keys).union(b.keys).sorted() {
            switch (a[path], b[path]) {
            case (nil, _?): changes.append(SnapshotChange(path: path, kind: .added))
            case (_?, nil): changes.append(SnapshotChange(path: path, kind: .deleted))
            case (let x?, let y?) where x != y: changes.append(SnapshotChange(path: path, kind: .modified))
            default: break
            }
        }
        return SnapshotDiff(changes: changes)
    }

    func text(of path: String, at snapshot: SnapshotToken) async -> SnapshotText {
        guard let data = lock.withLock({ snapshots[snapshot.id]?[path] }) else { return .absent }
        guard data.count <= maxTextBytes, let text = String(data: data, encoding: .utf8) else { return .unavailable }
        return .text(alteredText ?? text)
    }
}

/// A command-risk tool that changes the project the way a shell command would.
private struct ShellLike: AgentTool {
    let action: @Sendable () throws -> Void
    var risk: ToolRisk { .command }
    var definition: ToolDefinition {
        ToolDefinition(name: "run_command", description: "run", parameters: [ToolParameter("command", .string, "cmd")])
    }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        try action()
        return "done"
    }
}

private func runCommand(
    project: TempProject, snapshotter: (any WorkspaceSnapshotter)?, action: @escaping @Sendable () throws -> Void
) async -> (session: AgentSession, run: RunID?, output: String) {
    let client = MockLLMClient(turns: [
        .toolCalls((id: "c1", name: "run_command", arguments: #"{"command":"x"}"#)), .text("ok"),
    ])
    let session = AgentSession(
        client: client, tools: [ShellLike(action: action)], workspace: project.workspace,
        configuration: AgentConfiguration(model: "m", approval: .approveAll, snapshotter: snapshotter))
    var run: RunID?
    var output = ""
    for await event in await session.send("go") {
        if case .runStarted(let id) = event { run = id }
        if case .toolCallFinished(_, _, let result) = event { output = result.text }
    }
    return (session, run, output)
}

private func disk(_ project: TempProject, _ path: String) -> String? {
    try? String(contentsOf: project.root.appendingPathComponent(path), encoding: .utf8)
}

@Suite struct CommandSnapshotTests {
    @Test func aCommandsChangesAreRecordedAndRevertRestoresThem() async throws {
        let project = try TempProject(files: ["A.txt": "one\n", "B.txt": "two\n", "C.txt": "keep\n"])
        let root = project.root
        let snapshotter = DirectorySnapshotter(root: root)
        let (session, run, _) = await runCommand(project: project, snapshotter: snapshotter) {
            try Data("one!\n".utf8).write(to: root.appendingPathComponent("A.txt"))
            try FileManager.default.removeItem(at: root.appendingPathComponent("B.txt"))
            try Data("new\n".utf8).write(to: root.appendingPathComponent("N.txt"))
        }
        let id = try #require(run)
        let changes = await session.checkpoints.changes(in: id)
        #expect(Set(changes.map(\.path)) == ["A.txt", "B.txt", "N.txt"])
        #expect(changes.first { $0.path == "B.txt" }?.isDeletion == true)
        #expect(changes.first { $0.path == "N.txt" }?.isCreation == true)

        let report = try await session.revertRun(id)
        #expect(report.isComplete)
        #expect(disk(project, "A.txt") == "one\n")
        #expect(disk(project, "B.txt") == "two\n", "a file the command removed comes back")
        #expect(disk(project, "N.txt") == nil)
        #expect(disk(project, "C.txt") == "keep\n")
        // Reverting again changes nothing and does not complain.
        #expect(try await session.revertRun(id).isComplete)
        #expect(disk(project, "B.txt") == "two\n")
    }

    @Test func aFileTheUserChangedAfterTheCommandIsAConflictNotOverwritten() async throws {
        let project = try TempProject(files: ["A.txt": "one\n", "B.txt": "two\n"])
        let root = project.root
        let (session, run, _) = await runCommand(project: project, snapshotter: DirectorySnapshotter(root: root)) {
            try Data("one!\n".utf8).write(to: root.appendingPathComponent("A.txt"))
            try FileManager.default.removeItem(at: root.appendingPathComponent("B.txt"))
        }
        try project.write("A.txt", "the user typed\n")
        try project.write("B.txt", "the user made a new B\n")
        let report = try await session.revertRun(try #require(run))
        #expect(Set(report.conflicts.map(\.path)) == ["A.txt", "B.txt"])
        #expect(disk(project, "A.txt") == "the user typed\n")
        #expect(disk(project, "B.txt") == "the user made a new B\n")
    }

    @Test func aFileAnEditAlreadyRecordedKeepsItsOriginalAndFollowsTheCommand() async throws {
        let project = try TempProject(files: ["A.txt": "orig\n"])
        let root = project.root
        let log = CheckpointLog()
        let snapshotter = DirectorySnapshotter(root: root)
        let run = await log.beginRun(label: "x")
        let scope = CheckpointScope(log: log, run: run)
        await scope.willChange(path: "A.txt", original: "orig\n")
        try project.write("A.txt", "edited\n")
        await scope.didChange(path: "A.txt", written: "edited\n")

        let before = try #require(await snapshotter.capture())
        try project.write("A.txt", "edited by sed\n")
        let after = try #require(await snapshotter.capture())
        _ = await CommandChangeTracker.record(
            snapshotter: snapshotter, before: before, after: after, scope: scope,
            workspace: project.workspace, secretPatterns: [])

        let report = await log.revert(run, using: project.workspace)
        #expect(report.isComplete)
        #expect(disk(project, "A.txt") == "orig\n")
    }

    @Test func binaryOrOversizeFilesAreNamedNotRecorded() async throws {
        let project = try TempProject(files: ["big.txt": "small\n"])
        let root = project.root
        let snapshotter = DirectorySnapshotter(root: root)
        snapshotter.maxTextBytes = 10
        let (session, run, output) = await runCommand(project: project, snapshotter: snapshotter) {
            try Data("this is far longer than ten bytes\n".utf8).write(to: root.appendingPathComponent("big.txt"))
            try Data([0xFF, 0xFE, 0x00]).write(to: root.appendingPathComponent("blob.bin"))
        }
        #expect(await session.checkpoints.changes(in: try #require(run)).isEmpty)
        #expect(output.contains("could not be recorded"))
        #expect(output.contains("big.txt"))
        #expect(output.contains("blob.bin"))
    }

    @Test func textTheFileDoesNotHoldIsNamedNotRecorded() async throws {
        let project = try TempProject(files: ["A.txt": "one\n"])
        let root = project.root
        let snapshotter = DirectorySnapshotter(root: root)
        snapshotter.alteredText = "converted by a filter\n"
        let (session, run, output) = await runCommand(project: project, snapshotter: snapshotter) {
            try Data("two\n".utf8).write(to: root.appendingPathComponent("A.txt"))
        }
        #expect(await session.checkpoints.changes(in: try #require(run)).isEmpty)
        #expect(output.contains("A.txt"))
    }

    @Test func secretAndProtectedFilesAreLeftOut() async throws {
        let project = try TempProject(files: ["ok.txt": "a\n"])
        let root = project.root
        let (session, run, _) = await runCommand(project: project, snapshotter: DirectorySnapshotter(root: root)) {
            try Data("TOKEN=1\n".utf8).write(to: root.appendingPathComponent(".env"))
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".gradle"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: root.appendingPathComponent(".gradle/cache.txt"))
            try Data("b\n".utf8).write(to: root.appendingPathComponent("ok.txt"))
        }
        let paths = await session.checkpoints.changes(in: try #require(run)).map(\.path)
        #expect(paths == ["ok.txt"])
    }

    @Test func aSnapshotThatFailsLeavesTheRunAlone() async throws {
        let project = try TempProject(files: ["A.txt": "one\n"])
        let root = project.root
        let snapshotter = DirectorySnapshotter(root: root)
        snapshotter.failCapture = true
        let (session, run, output) = await runCommand(project: project, snapshotter: snapshotter) {
            try Data("two\n".utf8).write(to: root.appendingPathComponent("A.txt"))
        }
        #expect(output == "done")
        #expect(await session.checkpoints.changes(in: try #require(run)).isEmpty)
    }

    @Test func withoutASnapshotterNothingChanges() async throws {
        let project = try TempProject(files: ["A.txt": "one\n"])
        let root = project.root
        let (session, run, output) = await runCommand(project: project, snapshotter: nil) {
            try Data("two\n".utf8).write(to: root.appendingPathComponent("A.txt"))
        }
        #expect(output == "done")
        #expect(await session.checkpoints.changes(in: try #require(run)).isEmpty)
    }

    @Test func aDeletionSurvivesARelaunchThroughTheSnapshotAndBlobStore() async throws {
        final class Blobs: CheckpointBlobStore, @unchecked Sendable {
            let lock = NSLock(); var store: [String: String] = [:]
            func put(_ text: String, run: RunID, path: String) { lock.withLock { store["\(run)/\(path)"] = text } }
            func get(run: RunID, path: String) -> String? { lock.withLock { store["\(run)/\(path)"] } }
        }
        let project = try TempProject(files: ["B.txt": "two\n"])
        let blobs = Blobs()
        let log = CheckpointLog(blobs: blobs)
        let run = await log.beginRun(label: "x")
        await log.willChange(run: run, path: "B.txt", original: "two\n")
        await log.didDelete(run: run, path: "B.txt")
        try FileManager.default.removeItem(at: project.root.appendingPathComponent("B.txt"))

        let restored = CheckpointLog(blobs: blobs)
        let json = try JSONEncoder().encode(await log.snapshot())
        await restored.restore(try JSONDecoder().decode([RunSnapshot].self, from: json))
        let report = await restored.revert(run, using: project.workspace)
        #expect(report.isComplete)
        #expect(disk(project, "B.txt") == "two\n")
    }
}
