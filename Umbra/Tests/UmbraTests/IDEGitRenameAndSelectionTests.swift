import Foundation
import GitIntelligence
import XCTest
@testable import Umbra

/// Rename comparisons and Changes selection against a real temporary repository.
/// Paths come from porcelain `originalPath`. Nothing here pairs a deleted path with a new file by text.
@MainActor
final class IDEGitRenameAndSelectionTests: XCTestCase {
    private var directory: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-rename-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Tester"],
                     ["config", "user.email", "t@example.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Eighty similar lines, so a one-line edit stays a rename and a full rewrite does not.
    private func lines(_ marker: String) -> String {
        (1 ... 80).map { "line \($0) \(marker)\n" }.joined()
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: file(name), atomically: true, encoding: .utf8)
    }

    private func commit(_ name: String, _ text: String, _ message: String) async throws {
        try write(name, text)
        _ = try await runner.run(["add", name], in: directory)
        _ = try await runner.run(["commit", "-q", "-m", message], in: directory)
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 10,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func makeModel() async throws -> IDEGitStatusModel {
        let model = IDEGitStatusModel()
        model.setRoot(directory)
        try await waitUntil("the repository to load") { model.isRepository }
        return model
    }

    private func change(_ model: IDEGitStatusModel, _ relative: String) -> IDEGitChange? {
        model.changes.first { $0.relativePath == relative }
    }

    private func text(_ content: IDEDiffContent, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case .text(let value) = content else {
            XCTFail("expected text, got \(content)", file: file, line: line)
            return ""
        }
        return value
    }

    func testAStagedRenameComparesHeadOfTheOldPathWithTheIndexOfTheNewPath() async throws {
        try await commit("old.txt", lines("base"), "base")
        _ = try await runner.run(["mv", "old.txt", "new.txt"], in: directory)
        try write("new.txt", lines("base").replacingOccurrences(of: "line 3 base", with: "line 3 edited"))
        _ = try await runner.run(["add", "new.txt"], in: directory)

        let model = try await makeModel()
        try await waitUntil("the staged rename") { change(model, "new.txt")?.indexCode == "R" }
        let renamed = try XCTUnwrap(change(model, "new.txt"))
        XCTAssertEqual(renamed.originalPath, "old.txt")
        XCTAssertNil(renamed.unstaged)

        let request = IDEGitChangeDiff.request(for: renamed, staged: true)
        XCTAssertEqual(request.left.source, .revision(.head, relativePath: "old.txt"))
        XCTAssertEqual(request.right.source, .revision(.index, relativePath: "new.txt"))
        XCTAssertEqual(request.repositoryRelativePath, "new.txt")
        XCTAssertTrue(request.comparesDistinctPaths)

        let left = text(await model.diffContent(request.left.source))
        let right = text(await model.diffContent(request.right.source))
        let headAtNew = text(await model.diffContent(.revision(.head, relativePath: "new.txt")))
        XCTAssertTrue(left.contains("line 3 base"), left)
        XCTAssertFalse(left.contains("line 3 edited"))
        XCTAssertTrue(right.contains("line 3 edited"), right)
        XCTAssertEqual(headAtNew, "", "HEAD has no file at the new path")
    }

    func testAStagedRenamePlusAWorktreeEditUsesTheNewPathOnlyForTheUnstagedSide() async throws {
        try await commit("old.txt", lines("base"), "base")
        _ = try await runner.run(["mv", "old.txt", "new.txt"], in: directory)
        try write("new.txt", lines("base").replacingOccurrences(of: "line 3 base", with: "line 3 edited"))
        _ = try await runner.run(["add", "new.txt"], in: directory)
        try write("new.txt", lines("base").replacingOccurrences(of: "line 3 base", with: "line 3 worktree"))

        let model = try await makeModel()
        try await waitUntil("the mixed rename") {
            change(model, "new.txt")?.indexCode == "R" && change(model, "new.txt")?.worktreeCode == "M"
        }
        let renamed = try XCTUnwrap(change(model, "new.txt"))
        XCTAssertEqual(renamed.originalPath, "old.txt")

        let staged = IDEGitChangeDiff.request(for: renamed, staged: true)
        XCTAssertEqual(staged.left.source, .revision(.head, relativePath: "old.txt"))
        XCTAssertEqual(staged.right.source, .revision(.index, relativePath: "new.txt"))
        let unstaged = IDEGitChangeDiff.request(for: renamed, staged: false)
        XCTAssertEqual(unstaged.left.source, .revision(.index, relativePath: "new.txt"))
        XCTAssertEqual(unstaged.right.source, .workingTree(path: renamed.path))
        XCTAssertFalse(unstaged.comparesDistinctPaths)

        let stagedLeft = text(await model.diffContent(staged.left.source))
        let stagedRight = text(await model.diffContent(staged.right.source))
        let unstagedLeft = text(await model.diffContent(unstaged.left.source))
        let unstagedRight = text(await model.diffContent(unstaged.right.source))
        let indexAtOld = text(await model.diffContent(.revision(.index, relativePath: "old.txt")))
        XCTAssertTrue(stagedLeft.contains("line 3 base"), stagedLeft)
        XCTAssertTrue(stagedRight.contains("line 3 edited"), stagedRight)
        XCTAssertTrue(unstagedLeft.contains("line 3 edited"), unstagedLeft)
        XCTAssertTrue(unstagedRight.contains("line 3 worktree"), unstagedRight)
        XCTAssertEqual(indexAtOld, "")
    }

    func testAnUnstagedRenameReadsTheIndexAtTheOldPath() async throws {
        try await commit("old.txt", lines("base"), "base")
        try FileManager.default.moveItem(at: file("old.txt"), to: file("moved.txt"))
        _ = try await runner.run(["add", "-N", "moved.txt"], in: directory)

        let model = try await makeModel()
        try await waitUntil("the unstaged rename") { change(model, "moved.txt")?.worktreeCode == "R" }
        let renamed = try XCTUnwrap(change(model, "moved.txt"))
        XCTAssertEqual(renamed.originalPath, "old.txt")
        XCTAssertEqual(renamed.indexCode, " ")
        XCTAssertNil(renamed.staged)

        let request = IDEGitChangeDiff.request(for: renamed, staged: false)
        XCTAssertEqual(request.left.source, .revision(.index, relativePath: "old.txt"))
        XCTAssertEqual(request.right.source, .workingTree(path: renamed.path))
        XCTAssertEqual(request.repositoryRelativePath, "old.txt")
        XCTAssertEqual(request.revisionPaths, ["old.txt", "moved.txt"])
        XCTAssertTrue(request.comparesDistinctPaths)

        let left = text(await model.diffContent(request.left.source))
        let emptyNewBlob = text(await model.diffContent(.revision(.index, relativePath: "moved.txt")))
        XCTAssertTrue(left.contains("line 1 base"), left)
        XCTAssertEqual(emptyNewBlob, "", "the intent-to-add blob at the new path is empty")
    }

    func testAStagedEditThenAnUnstagedRenameKeepsBothEntries() async throws {
        try await commit("old.txt", lines("base"), "base")
        try write("old.txt", lines("base") + "staged line\n")
        _ = try await runner.run(["add", "old.txt"], in: directory)
        try FileManager.default.moveItem(at: file("old.txt"), to: file("later.txt"))
        try write("later.txt", lines("base") + "staged line\nworktree line\n")
        _ = try await runner.run(["add", "-N", "later.txt"], in: directory)

        let model = try await makeModel()
        try await waitUntil("both entries") {
            change(model, "later.txt")?.worktreeCode == "R" && change(model, "old.txt")?.indexCode == "M"
        }
        let later = try XCTUnwrap(change(model, "later.txt"))
        let old = try XCTUnwrap(change(model, "old.txt"))
        XCTAssertEqual(later.originalPath, "old.txt")
        XCTAssertNil(old.originalPath)

        let rename = IDEGitChangeDiff.request(for: later, staged: false)
        XCTAssertEqual(rename.left.source, .revision(.index, relativePath: "old.txt"))
        let stagedEdit = IDEGitChangeDiff.request(for: old, staged: true)
        XCTAssertEqual(stagedEdit.left.source, .revision(.head, relativePath: "old.txt"))
        XCTAssertEqual(stagedEdit.right.source, .revision(.index, relativePath: "old.txt"))

        let renameLeft = text(await model.diffContent(rename.left.source))
        let renameRight = text(await model.diffContent(rename.right.source))
        let emptyLater = text(await model.diffContent(.revision(.index, relativePath: "later.txt")))
        XCTAssertTrue(renameLeft.contains("staged line"), renameLeft)
        XCTAssertFalse(renameLeft.contains("worktree line"))
        XCTAssertTrue(renameRight.contains("worktree line"), renameRight)
        XCTAssertEqual(emptyLater, "")
    }

    func testARewriteBelowTheRenameThresholdIsNotGivenASourcePath() async throws {
        try await commit("old.txt", lines("base"), "base")
        try write("decoy.txt", lines("decoy"))
        _ = try await runner.run(["add", "decoy.txt"], in: directory)
        _ = try await runner.run(["commit", "-q", "-m", "decoy"], in: directory)
        _ = try await runner.run(["mv", "old.txt", "rewritten.txt"], in: directory)
        try write("rewritten.txt", (1 ... 80).map { "zzz \($0)\n" }.joined())
        _ = try await runner.run(["add", "rewritten.txt"], in: directory)

        let model = try await makeModel()
        try await waitUntil("the rewrite to leave the rename detector") {
            change(model, "rewritten.txt")?.indexCode == "A" && change(model, "old.txt")?.indexCode == "D"
        }
        let added = try XCTUnwrap(change(model, "rewritten.txt"))
        let deleted = try XCTUnwrap(change(model, "old.txt"))
        XCTAssertNil(added.originalPath)
        XCTAssertNil(deleted.originalPath)
        XCTAssertNil(IDEGitChangeDiff.sourcePath(for: added, staged: true))
        XCTAssertNil(IDEGitChangeDiff.sourcePath(for: deleted, staged: true))

        let addedRequest = IDEGitChangeDiff.request(for: added, staged: true)
        XCTAssertEqual(addedRequest.left.source, .text(""))
        XCTAssertEqual(addedRequest.right.source, .revision(.index, relativePath: "rewritten.txt"))
        XCTAssertFalse(addedRequest.comparesDistinctPaths)
        let deletedRequest = IDEGitChangeDiff.request(for: deleted, staged: true)
        XCTAssertEqual(deletedRequest.left.source, .revision(.head, relativePath: "old.txt"))
        XCTAssertNotEqual(deletedRequest.right.source, .revision(.index, relativePath: "rewritten.txt"))
    }

    func testCommittingAnUnstagedRenameStillReloadsATabKeyedByTheOldPath() async throws {
        try await commit("old.txt", lines("base"), "base")
        try FileManager.default.moveItem(at: file("old.txt"), to: file("moved.txt"))
        _ = try await runner.run(["add", "-N", "moved.txt"], in: directory)
        let model = try await makeModel()
        try await waitUntil("the rename") { change(model, "moved.txt")?.originalPath == "old.txt" }

        _ = try await runner.run(["add", "moved.txt"], in: directory)
        _ = try await runner.run(["commit", "-q", "-m", "rename"], in: directory)
        var sawOld = false
        var sawMoved = false
        model.onRefreshed = {
            guard self.change(model, "moved.txt") == nil else { return }
            if model.refreshedRelativePaths.contains("old.txt") { sawOld = true }
            if model.refreshedRelativePaths.contains("moved.txt") { sawMoved = true }
        }
        model.refresh()
        try await waitUntil("the old path to invalidate the open comparison") {
            sawOld && sawMoved
        }
    }

    func testSelectionKeepsBothSectionsAndFollowsAStagedFile() async throws {
        try await commit("a.txt", lines("a"), "add a")
        try await commit("b.txt", lines("b"), "add b")
        try write("a.txt", lines("a").replacingOccurrences(of: "line 2 a", with: "line 2 staged"))
        _ = try await runner.run(["add", "a.txt"], in: directory)
        try write("a.txt", lines("a").replacingOccurrences(of: "line 2 a", with: "line 2 unstaged"))
        try write("b.txt", lines("b").replacingOccurrences(of: "line 2 b", with: "line 2 dirty"))
        try write("c.txt", "fresh\n")

        let model = try await makeModel()
        try await waitUntil("the three files") {
            let a = change(model, "a.txt")
            return a?.staged != nil && a?.unstaged != nil
                && change(model, "b.txt")?.unstaged != nil
                && change(model, "c.txt")?.unstaged == .untracked
        }
        let a = try XCTUnwrap(change(model, "a.txt"))
        let b = try XCTUnwrap(change(model, "b.txt"))
        let c = try XCTUnwrap(change(model, "c.txt"))
        let stagedA = IDEGitListedChange(section: .staged, path: a.path)
        let unstagedA = IDEGitListedChange(section: .unstaged, path: a.path)
        let unstagedB = IDEGitListedChange(section: .unstaged, path: b.path)
        let listed = IDEGitChangeRows.listed(in: model.changes)

        model.selectChange(row: unstagedA)
        model.toggleChangeSelection(row: stagedA)
        XCTAssertEqual(model.selectedChanges, [stagedA, unstagedA])
        XCTAssertEqual(model.selectedChangePaths, [a.path])
        XCTAssertEqual(model.selectedChange, stagedA)

        let unstagedRows = listed.filter { $0.section == .unstaged }
        model.selectChange(row: unstagedA)
        model.extendChangeSelection(to: unstagedB, in: unstagedRows)
        XCTAssertEqual(model.selectedChanges, [unstagedA, unstagedB])
        XCTAssertFalse(model.selectedChanges.contains(stagedA))

        model.selectChange(row: stagedA)
        model.extendChangeSelection(to: unstagedB, in: listed)
        XCTAssertTrue(model.selectedChanges.contains(unstagedA), "⇧-arrow across the list includes both copies")
        model.toggleChangeSelection(row: stagedA)
        XCTAssertFalse(model.selectedChanges.contains(stagedA))
        XCTAssertTrue(model.selectedChanges.contains(unstagedA))

        let stagedPreview = IDEGitChangeDiff.preview(of: a.path, section: .staged, in: model.changes)
        let unstagedPreview = IDEGitChangeDiff.preview(of: a.path, section: .unstaged, in: model.changes)
        XCTAssertEqual(stagedPreview?.request.indexAction, .unstage)
        XCTAssertEqual(unstagedPreview?.request.indexAction, .stage)
        XCTAssertNotEqual(stagedPreview?.request.id, unstagedPreview?.request.id)
        XCTAssertNil(IDEGitChangeDiff.preview(of: a.path, section: .conflict, in: model.changes))

        model.selectChange(row: unstagedA)
        var refreshes = 0
        model.onRefreshed = { refreshes += 1 }
        model.refresh()
        try await waitUntil("the refresh") { refreshes > 0 && change(model, "a.txt")?.unstaged != nil }
        XCTAssertEqual(model.selectedChange, unstagedA)

        let unstagedC = IDEGitListedChange(section: .unstaged, path: c.path)
        model.selectChange(row: unstagedC)
        model.stage(path: c.path)
        try await waitUntil("c.txt to be staged") {
            change(model, "c.txt")?.staged == .added && change(model, "c.txt")?.unstaged == nil
        }
        XCTAssertEqual(model.selectedChange, IDEGitListedChange(section: .staged, path: c.path))
        XCTAssertEqual(model.selectedChangePaths, [c.path])

        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-rename-other-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        _ = try await runner.run(["init", "-q", "-b", "main"], in: other)
        model.setRoot(other)
        XCTAssertNil(model.selectedChange)
        XCTAssertTrue(model.selectedChanges.isEmpty)
    }
}
