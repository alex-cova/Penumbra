import Foundation
import GitIntelligence
import XCTest
@testable import Umbra

/// Audit WP3: what the porcelain letters mean in the Changes list, and what Unstage and Discard do
/// with a staged rename.
@MainActor
final class IDEGitStatusCorrectnessTests: XCTestCase {
    private var directory: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-status-fix-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@e.com"],
                     ["config", "commit.gpgsign", "false"], ["config", "core.autocrlf", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func git(_ args: [String]) async throws -> String { try await runner.run(args, in: directory).text }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private func loadedModel(runner: any GitRunning = SystemGitRunner()) async throws -> IDEGitStatusModel {
        let model = IDEGitStatusModel(runner: runner)
        model.setRoot(directory)
        try await waitUntil("the first status") { model.workspaceSnapshot != nil }
        return model
    }

    // MARK: G-02

    func testUntrackedFilesAreNotStaged() async throws {
        try write("new.txt", "n\n")
        let model = try await loadedModel()
        let change = try XCTUnwrap(model.changes.first { $0.relativePath == "new.txt" })
        XCTAssertNil(change.staged)
        XCTAssertEqual(change.unstaged, .untracked)
        XCTAssertEqual(IDEGitChangeRows.listed(in: model.changes).map(\.section), [.unstaged])
    }

    /// Every pair `git help status` documents, with what each side means and where the row is listed.
    func testEveryPorcelainPairMapsToTheRightSides() {
        typealias Row = (xy: String, staged: IDEGitFileStatus?, unstaged: IDEGitFileStatus?, sections: [IDEGitChangeSection])
        let table: [Row] = [
            ("??", nil, .untracked, [.unstaged]),
            (" M", nil, .modified, [.unstaged]),
            ("M ", .modified, nil, [.staged]),
            ("MM", .modified, .modified, [.staged, .unstaged]),
            ("A ", .added, nil, [.staged]),
            (" A", nil, .added, [.unstaged]),
            ("AM", .added, .modified, [.staged, .unstaged]),
            ("T ", .modified, nil, [.staged]),
            (" T", nil, .modified, [.unstaged]),
            ("D ", .modified, nil, [.staged]),
            (" D", nil, .modified, [.unstaged]),
            ("R ", .modified, nil, [.staged]),
            ("RM", .modified, .modified, [.staged, .unstaged]),
            ("C ", .modified, nil, [.staged]),
            ("AA", .conflicted, .conflicted, [.conflict]),
            ("DD", .conflicted, .conflicted, [.conflict]),
            ("AU", .conflicted, .conflicted, [.conflict]),
            ("UA", .conflicted, .conflicted, [.conflict]),
            ("DU", .conflicted, .conflicted, [.conflict]),
            ("UD", .conflicted, .conflicted, [.conflict]),
            ("UU", .conflicted, .conflicted, [.conflict]),
        ]
        for row in table {
            let letters = Array(row.xy)
            let entry = GitStatusEntry(
                path: "f.txt", originalPath: letters[0] == "R" || letters[0] == "C" ? "old.txt" : nil,
                indexCode: letters[0], worktreeCode: letters[1]
            )
            let snapshot = IDEGitStatusModel.parse(entries: [entry], toplevel: "/repo", branch: "main")
            guard let change = snapshot.changes.first else { XCTFail("\(row.xy): no change row"); continue }
            XCTAssertEqual(change.staged, row.staged, "\(row.xy) staged")
            XCTAssertEqual(change.unstaged, row.unstaged, "\(row.xy) unstaged")
            XCTAssertEqual(IDEGitChangeRows.listed(in: snapshot.changes).map(\.section), row.sections, "\(row.xy) sections")
        }
        let ignored = IDEGitStatusModel.parse(
            entries: [GitStatusEntry(path: "x.log", originalPath: nil, indexCode: "!", worktreeCode: "!")],
            toplevel: "/repo", branch: "main"
        )
        XCTAssertTrue(ignored.changes.isEmpty, "an ignored file is not a change")
        XCTAssertEqual(ignored.statuses["/repo/x.log"], .ignored)
    }

    /// G-13: the faster walk must still mark exactly the folders above a change, and the root.
    func testEveryFolderAboveAChangeIsMarkedAndNoOtherIs() {
        func entry(_ path: String) -> GitStatusEntry { GitStatusEntry(path: path, originalPath: nil, indexCode: " ", worktreeCode: "M") }
        let snapshot = IDEGitStatusModel.parse(
            entries: [entry("a/b/c.txt"), entry("a/b/d.txt"), entry("a/e.txt"), entry("x/y/z/w.txt"), entry("top.txt")],
            toplevel: "/repo", branch: "main"
        )
        XCTAssertEqual(snapshot.dirtyDirectories, ["/repo", "/repo/a", "/repo/a/b", "/repo/x", "/repo/x/y", "/repo/x/y/z"])
        XCTAssertEqual(snapshot.statuses["/repo/a/b/c.txt"], .modified)
        let folderOnly = IDEGitStatusModel.parse(
            entries: [GitStatusEntry(path: "build/", originalPath: nil, indexCode: "?", worktreeCode: "?")], toplevel: "/repo", branch: nil
        )
        XCTAssertEqual(folderOnly.statuses["/repo/build"], .untracked)
        XCTAssertEqual(folderOnly.dirtyDirectories, ["/repo"])
    }

    func testCommitWithOnlyUntrackedFilesFailsWithoutRunningGit() async throws {
        try write("new.txt", "n\n")
        let recorder = RecordingRunner()
        let model = try await loadedModel(runner: recorder)
        model.commitMessage = "message"
        recorder.reset()
        model.requestCommit(options: IDEGitCommitOptions())
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.actionStatus, "Nothing staged to commit.")
        XCTAssertTrue(model.actionFailed)
        // Background refresh work may still be finishing; nothing the commit path itself runs may appear.
        let fromTheCommitPath = recorder.commands.filter { command in
            command.contains("commit") || command.contains("--check") || command.contains("--cached")
                || command.contains("user.name") || command.contains("user.email")
        }
        XCTAssertEqual(fromTheCommitPath, [], "no commit command or pre-commit check may run")
    }

    // MARK: G-10

    private func commitRename() async throws {
        try write("old.txt", "a\nb\nc\nd\ne\n")
        _ = try await git(["add", "old.txt"])
        _ = try await git(["commit", "-qm", "base"])
        _ = try await git(["mv", "old.txt", "new.txt"])
    }

    func testUnstagingAStagedRenameUnstagesBothPaths() async throws {
        try await commitRename()
        let model = try await loadedModel()
        let change = try XCTUnwrap(model.changes.first { $0.relativePath == "new.txt" })
        XCTAssertEqual(change.originalPath, "old.txt")
        model.unstage(paths: [change.path])
        try await waitUntil("the unstage") { !model.isBusy && model.changes.allSatisfy { $0.staged == nil } }
        let porcelain = try await git(["status", "--porcelain"])
        XCTAssertEqual(Set(porcelain.split(separator: "\n").map(String.init)), [" D old.txt", "?? new.txt"])
    }

    func testDiscardingAStagedRenameRestoresTheOldFileAndKeepsTheNewOneUntracked() async throws {
        try await commitRename()
        let model = try await loadedModel()
        let change = try XCTUnwrap(model.changes.first { $0.relativePath == "new.txt" })
        var reverted: Set<String> = []
        var failure: String?
        model.revert(paths: [change.path], then: { reverted = $0 }, onFailure: { failure = $0 })
        try await waitUntil("the discard") { !model.isBusy }
        XCTAssertNil(failure)
        let porcelain = try await git(["status", "--porcelain"])
        XCTAssertEqual(porcelain, "?? new.txt\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("old.txt").path), "the old file is back")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("new.txt").path), "the new file stays on disk")
        XCTAssertTrue(reverted.contains(directory.appendingPathComponent("old.txt").path), "editors showing the old path reload")
    }

    func testTheDiscardConfirmationSaysTheRenamedFileStaysOnDisk() {
        let prompt = IDEGitDiscardPrompt.changes(
            revertable: ["new.txt"], skipped: [], unsavedEditors: 0, keptAsUntracked: ["new.txt"]
        )
        XCTAssertTrue(prompt.detail.contains("new.txt stays on disk as an untracked file"), prompt.detail)
        let plain = IDEGitDiscardPrompt.changes(revertable: ["a.txt"], skipped: [], unsavedEditors: 0)
        XCTAssertFalse(plain.detail.contains("untracked"))
    }
}

private final class RecordingRunner: GitRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let base = SystemGitRunner()

    var commands: [[String]] { lock.withLock { recorded } }
    func reset() { lock.withLock { recorded = [] } }

    func run(_ arguments: [String], in directory: URL, stdin: Data?, environment: [String: String]?, onProgress: GitProgressHandler?) async throws -> GitOutput {
        lock.withLock { recorded.append(arguments) }
        return try await base.run(arguments, in: directory, stdin: stdin, environment: environment, onProgress: onProgress)
    }
}
