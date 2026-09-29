import Foundation
import GitIntelligence
import XCTest
@testable import Umbra

/// File history and revert through `IDEGitStatusModel`, against a real scratch repository.
@MainActor
final class IDEGitStatusModelHistoryTests: XCTestCase {
    private var directory: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-model-\(UUID().uuidString)", isDirectory: true)
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

    private func commit(_ name: String, _ text: String, _ message: String) async throws {
        try text.write(to: file(name), atomically: true, encoding: .utf8)
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

    func testFileHistoryListsOnlyThatFilesCommitsAndShowsItsDiff() async throws {
        try await commit("a.txt", "1\n", "add a")
        try await commit("b.txt", "1\n", "add b")
        try await commit("a.txt", "2\n", "change a")
        let model = try await makeModel()

        model.showFileHistory(path: file("a.txt").path)
        try await waitUntil("a's history") { model.commits.map(\.subject) == ["change a", "add a"] }
        XCTAssertEqual(model.historyFilePath, file("a.txt").path)
        XCTAssertTrue(model.commits.allSatisfy { $0.graph == nil }, "A filtered list has no graph lanes")

        model.selectCommit(model.commits[0].hash)
        try await waitUntil("the file's diff") { model.commitDetailText != nil }
        let diff = try XCTUnwrap(model.commitDetailText)
        XCTAssertTrue(diff.contains("+2"), diff)
        XCTAssertFalse(diff.contains("b.txt"))

        model.clearFileHistory()
        try await waitUntil("the whole history") { model.commits.count == 3 }
        XCTAssertNil(model.historyFilePath)
    }

    func testFileHistoryIgnoresAPathOutsideTheRepository() async throws {
        try await commit("a.txt", "1\n", "add a")
        let model = try await makeModel()

        model.showFileHistory(path: "/somewhere/else/x.txt")

        XCTAssertNil(model.historyFilePath)
    }

    func testRevertRestoresTheFileAndThenRunsTheCompletion() async throws {
        try await commit("a.txt", "original\n", "add a")
        let model = try await makeModel()
        try "changed\n".write(to: file("a.txt"), atomically: true, encoding: .utf8)
        model.refresh()
        try await waitUntil("the change to show") { model.changes.contains { $0.relativePath == "a.txt" } }

        var finished = false
        model.revert(path: file("a.txt").path, then: { finished = true })
        try await waitUntil("the revert") { finished }

        XCTAssertEqual(try String(contentsOf: file("a.txt"), encoding: .utf8), "original\n")
        XCTAssertEqual(model.actionStatus, "Reverted a.txt")
        try await waitUntil("a clean tree") { model.changes.isEmpty }
    }

    func testRevertOfAFileWithNothingCommittedReportsWhyAndKeepsTheFile() async throws {
        try await commit("a.txt", "1\n", "add a")
        let model = try await makeModel()
        try "mine\n".write(to: file("new.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "new.txt"], in: directory)

        var failure: String?
        var completed = false
        model.revert(path: file("new.txt").path, then: { completed = true }, onFailure: { failure = $0 })
        try await waitUntil("the refusal") { failure != nil }

        XCTAssertFalse(completed)
        XCTAssertTrue(try XCTUnwrap(failure).contains("not in the last commit"), failure ?? "")
        XCTAssertEqual(try String(contentsOf: file("new.txt"), encoding: .utf8), "mine\n")
    }

    // MARK: - Several files

    func testRevertOfSeveralFilesReportsTheSkippedOnesAndReloadsOnlyTheRevertedOnes() async throws {
        try await commit("a.txt", "a\n", "add a")
        try await commit("b.txt", "b\n", "add b")
        let model = try await makeModel()
        try "a2\n".write(to: file("a.txt"), atomically: true, encoding: .utf8)
        try "b2\n".write(to: file("b.txt"), atomically: true, encoding: .utf8)
        try "mine\n".write(to: file("new.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "new.txt"], in: directory)
        model.refresh()
        try await waitUntil("the changes") { model.changes.count == 3 }

        var reverted: Set<String>?
        model.revert(paths: [file("a.txt").path, file("b.txt").path, file("new.txt").path], then: { reverted = $0 })
        try await waitUntil("the revert") { reverted != nil }

        XCTAssertEqual(reverted, [file("a.txt").path, file("b.txt").path], "The skipped file is not reloaded from disk")
        XCTAssertEqual(model.actionStatus, "Reverted 2 files; skipped 1 not in the last commit")
        XCTAssertEqual(try String(contentsOf: file("a.txt"), encoding: .utf8), "a\n")
        XCTAssertEqual(try String(contentsOf: file("b.txt"), encoding: .utf8), "b\n")
        XCTAssertEqual(try String(contentsOf: file("new.txt"), encoding: .utf8), "mine\n")
    }

    func testRevertOfOnlyUncommittedFilesFailsWithoutRunningTheCompletion() async throws {
        try await commit("a.txt", "a\n", "add a")
        let model = try await makeModel()
        try "x\n".write(to: file("x.txt"), atomically: true, encoding: .utf8)
        try "y\n".write(to: file("y.txt"), atomically: true, encoding: .utf8)

        var failure: String?
        var completed = false
        model.revert(paths: [file("x.txt").path, file("y.txt").path], then: { _ in completed = true }, onFailure: { failure = $0 })
        try await waitUntil("the refusal") { failure != nil }

        XCTAssertFalse(completed)
        XCTAssertEqual(failure, "None of the 2 files are in the last commit, so there is nothing to revert to.")
    }

    func testSelectionExtendsTogglesAndShrinksWithTheChanges() async throws {
        for name in ["a.txt", "b.txt", "c.txt", "d.txt"] { try await commit(name, "1\n", "add \(name)") }
        let model = try await makeModel()
        for name in ["a.txt", "b.txt", "c.txt", "d.txt"] { try "2\n".write(to: file(name), atomically: true, encoding: .utf8) }
        model.refresh()
        try await waitUntil("the changes") { model.changes.count == 4 }
        let visible = ["a.txt", "b.txt", "c.txt", "d.txt"].map { file($0).path }

        model.selectChange(visible[0])
        XCTAssertEqual(model.selectedChangePaths, [visible[0]])
        model.extendChangeSelection(to: visible[2], in: visible)
        XCTAssertEqual(model.selectedChangePaths, Set(visible[0...2]))
        XCTAssertEqual(model.selectedChangePath, visible[2], "The clicked row drives the diff")
        model.toggleChangeSelection(visible[3])
        XCTAssertEqual(model.selectedChangePaths, Set(visible))
        model.toggleChangeSelection(visible[3])
        model.toggleChangeSelection(visible[1])
        XCTAssertEqual(model.selectedChangePaths, [visible[0], visible[2]])
        model.selectChange(visible[1])
        XCTAssertEqual(model.selectedChangePaths, [visible[1]], "A plain click replaces the selection")

        model.extendChangeSelection(to: visible[3], in: visible)
        XCTAssertEqual(model.selectedChangePaths, Set(visible[1...3]))
        _ = try await runner.run(["checkout", "--", "c.txt", "d.txt"], in: directory)
        model.refresh()
        try await waitUntil("the selection to shrink") { model.selectedChangePaths == [visible[1]] }
    }
}

