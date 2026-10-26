import AgentKit
import Foundation
import XCTest
@testable import Umbra

final class IDEAgentSnapshotTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    /// `XCTUnwrap` takes an autoclosure, which cannot await.
    private func need<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        guard let value else {
            XCTFail("expected a value", file: file, line: line)
            throw CancellationError()
        }
        return value
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-snap-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ text: String, _ path: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func repository(files: [String: String]) throws -> URL {
        let root = try makeDirectory()
        try git(["init", "-q"], in: root)
        for (path, text) in files { try write(text, path, in: root) }
        try git(["add", "-A"], in: root)
        try git(["commit", "-q", "-m", "initial"], in: root)
        return root
    }

    func testAChangedAddedAndDeletedFileAreReportedWithTheirTexts() async throws {
        let root = try repository(files: ["A.txt": "one\n", "B.txt": "two\n", "C.txt": "keep\n", ".gitignore": "build/\n"])
        let snapshotter = IDEAgentGitSnapshotter(projectRoot: root)
        let before = try need(await snapshotter.capture())

        try write("one!\n", "A.txt", in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("B.txt"))
        try write("new\n", "src/N.txt", in: root)
        try write("junk\n", "build/out.txt", in: root)
        let after = try need(await snapshotter.capture())

        let diff = try need(await snapshotter.diff(from: before, to: after))
        XCTAssertEqual(Set(diff.changes), [
            SnapshotChange(path: "A.txt", kind: .modified),
            SnapshotChange(path: "B.txt", kind: .deleted),
            SnapshotChange(path: "src/N.txt", kind: .added),
        ], "an ignored folder is not followed")
        let was = await snapshotter.text(of: "A.txt", at: before)
        let now = await snapshotter.text(of: "A.txt", at: after)
        let gone = await snapshotter.text(of: "B.txt", at: after)
        XCTAssertEqual(was, .text("one\n"))
        XCTAssertEqual(now, .text("one!\n"))
        XCTAssertEqual(gone, .absent)
    }

    func testTheUsersIndexAndStatusAreUntouched() async throws {
        let root = try repository(files: ["A.txt": "one\n"])
        try write("staged\n", "A.txt", in: root)
        try git(["add", "A.txt"], in: root)
        try write("untracked\n", "U.txt", in: root)
        let indexURL = root.appendingPathComponent(".git/index")
        let indexBefore = try Data(contentsOf: indexURL)
        let statusBefore = try git(["status", "--porcelain"], in: root)

        let snapshotter = IDEAgentGitSnapshotter(projectRoot: root)
        _ = await snapshotter.capture()
        try write("more\n", "U.txt", in: root)
        _ = await snapshotter.capture()

        XCTAssertEqual(try Data(contentsOf: indexURL), indexBefore)
        XCTAssertEqual(try git(["status", "--porcelain"], in: root), statusBefore)
    }

    func testAProjectInsideASubfolderUsesPathsRelativeToIt() async throws {
        let repo = try repository(files: ["app/Main.txt": "a\n", "other/X.txt": "x\n"])
        let project = repo.appendingPathComponent("app")
        let snapshotter = IDEAgentGitSnapshotter(projectRoot: project)
        let before = try need(await snapshotter.capture())
        try write("a2\n", "app/Main.txt", in: repo)
        try write("x2\n", "other/X.txt", in: repo)
        let after = try need(await snapshotter.capture())
        let diff = try need(await snapshotter.diff(from: before, to: after))
        XCTAssertEqual(diff.changes, [SnapshotChange(path: "Main.txt", kind: .modified)])
        let text = await snapshotter.text(of: "Main.txt", at: before)
        XCTAssertEqual(text, .text("a\n"))
    }

    func testBinaryAndLargeFilesAreUnavailableAndTooManyChangesAreCounted() async throws {
        let root = try repository(files: ["A.txt": "one\n"])
        let snapshotter = IDEAgentGitSnapshotter(projectRoot: root)
        let before = try need(await snapshotter.capture())
        try Data([0x89, 0x50, 0x00, 0x01]).write(to: root.appendingPathComponent("image.bin"))
        try write(String(repeating: "x", count: IDEAgentGitSnapshotter.maxTextBytes + 1), "huge.txt", in: root)
        for index in 0..<(IDEAgentGitSnapshotter.maxChanges + 5) { try write("\(index)\n", "many/f\(index).txt", in: root) }
        let after = try need(await snapshotter.capture())
        let binary = await snapshotter.text(of: "image.bin", at: after)
        let huge = await snapshotter.text(of: "huge.txt", at: after)
        XCTAssertEqual(binary, .unavailable)
        XCTAssertEqual(huge, .unavailable)
        let diff = try need(await snapshotter.diff(from: before, to: after))
        XCTAssertEqual(diff.changes.count, IDEAgentGitSnapshotter.maxChanges)
        XCTAssertEqual(diff.omitted, 7)
    }

    func testAFolderThatIsNotARepositoryGivesNothing() async throws {
        let root = try makeDirectory()
        try write("x\n", "A.txt", in: root)
        let snapshotter = IDEAgentGitSnapshotter(projectRoot: root)
        let token = await snapshotter.capture()
        XCTAssertNil(token)
    }

    /// The whole path through a session: an approved command rewrites, deletes and creates files in a
    /// real repository, and Revert Run puts them back.
    func testRevertingARunUndoesWhatACommandDidInARealRepository() async throws {
        let root = try repository(files: ["A.txt": "one\n", "B.txt": "two\n"])
        let action: @Sendable () throws -> Void = {
            try Data("one!\n".utf8).write(to: root.appendingPathComponent("A.txt"))
            try FileManager.default.removeItem(at: root.appendingPathComponent("B.txt"))
            try Data("new\n".utf8).write(to: root.appendingPathComponent("N.txt"))
        }
        let client = MockLLMClient(turns: [
            .toolCalls((id: "c1", name: "run_command", arguments: #"{"command":"x"}"#)), .text("done"),
        ])
        let session = AgentSession(
            client: client, tools: [ShellLikeTool(action: action)], workspace: DiskAgentWorkspace(root: root),
            configuration: AgentConfiguration(
                model: "m", approval: .approveAll, snapshotter: IDEAgentGitSnapshotter(projectRoot: root)))
        var run: RunID?
        for await event in await session.send("go") { if case .runStarted(let id) = event { run = id } }

        let id = try need(run)
        let changed = await session.checkpoints.changes(in: id).map(\.path)
        XCTAssertEqual(Set(changed), ["A.txt", "B.txt", "N.txt"])
        let report = try await session.revertRun(id)
        XCTAssertTrue(report.isComplete, "\(report)")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("A.txt"), encoding: .utf8), "one\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("B.txt"), encoding: .utf8), "two\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("N.txt").path))
    }
}

/// A command-risk tool that changes the project the way a shell command would.
private struct ShellLikeTool: AgentTool {
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
