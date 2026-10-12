import Foundation
import GitIntelligence
import XCTest
@testable import Umbra

@MainActor
final class IDEGitStatusStashTests: XCTestCase {
    private var directory: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-model-stash-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Tester"],
                     ["config", "user.email", "t@example.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
        try write("a.txt", "base\n")
        _ = try await runner.run(["add", "a.txt"], in: directory)
        _ = try await runner.run(["commit", "-q", "-m", "base"], in: directory)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func makeModel() async throws -> IDEGitStatusModel {
        let model = IDEGitStatusModel()
        model.setRoot(directory)
        try await waitUntil("the repository") { model.isRepository && model.currentBranch == "main" }
        return model
    }

    func testStashChangesRequiresChangesAndOpensTheSheet() async throws {
        let model = try await makeModel()
        model.requestStashChanges()
        XCTAssertNil(model.sheets.current, "a clean tree has nothing to stash")
        XCTAssertEqual(model.actionStatus, "No local changes to stash.")

        try write("a.txt", "changed\n")
        try write("new.txt", "n\n")
        model.refresh()
        try await waitUntil("the changes") { model.changes.count == 2 }
        model.requestStashChanges()

        guard case .stash(let request)? = model.sheets.current else { return XCTFail("expected the stash sheet") }
        XCTAssertEqual(request.branch, "main")
        XCTAssertTrue(request.hasUntracked)
    }

    func testStashAndUnstashRoundTrip() async throws {
        let model = try await makeModel()
        try write("a.txt", "changed\n")
        try write("new.txt", "untracked\n")
        model.refresh()
        try await waitUntil("the changes") { model.changes.count == 2 }

        model.stashChanges(message: "my work", includeUntracked: true, keepIndex: false)
        try await waitUntil("the stash") { model.stashes.count == 1 && model.changes.isEmpty }
        XCTAssertEqual(model.stashes[0].title, "my work")
        XCTAssertEqual(try read("a.txt"), "base\n")

        model.selectStash(model.stashes[0].hash)
        try await waitUntil("the stash files") { model.stashFiles.count == 2 }
        XCTAssertEqual(Set(model.stashFiles.map(\.file.path)), ["a.txt", "new.txt"])

        var reloaded = false
        model.onWorkingTreeChanged = { reloaded = true }
        model.applyStash(model.stashes[0], drop: true)
        try await waitUntil("the pop") { reloaded && model.stashes.isEmpty }
        XCTAssertEqual(try read("a.txt"), "changed\n")
        XCTAssertEqual(try read("new.txt"), "untracked\n")
    }

    func testDroppingAsksFirst() async throws {
        let model = try await makeModel()
        try write("a.txt", "changed\n")
        model.refresh()
        try await waitUntil("the change") { !model.changes.isEmpty }
        model.stashChanges(message: "x", includeUntracked: true, keepIndex: false)
        try await waitUntil("the stash") { model.stashes.count == 1 }

        model.requestDropStash(model.stashes[0])

        guard case .confirm(let confirmation)? = model.sheets.current else { return XCTFail("expected a confirmation") }
        XCTAssertTrue(confirmation.isDestructive)
        XCTAssertEqual(model.stashes.count, 1, "nothing is dropped before the user confirms")
        confirmation.action()
        try await waitUntil("the drop") { model.stashes.isEmpty }
    }

    func testAConflictingApplyReportsAndKeepsTheStash() async throws {
        let model = try await makeModel()
        try write("a.txt", "stashed\n")
        model.refresh()
        try await waitUntil("the change") { !model.changes.isEmpty }
        model.stashChanges(message: "wip", includeUntracked: true, keepIndex: false)
        try await waitUntil("the stash") { model.stashes.count == 1 }
        try write("a.txt", "committed\n")
        _ = try await runner.run(["commit", "-q", "-am", "diverge"], in: directory)
        model.refresh()

        model.applyStash(model.stashes[0])
        try await waitUntil("the failure") { model.actionFailed }

        XCTAssertEqual(model.stashes.count, 1)
        try await waitUntil("the conflict") { model.changes.contains { $0.staged == .conflicted || $0.unstaged == .conflicted } }
    }

    func testAnUntrackedStashFileComesFromTheThirdParent() async throws {
        let model = try await makeModel()
        try write("new.txt", "from the stash\n")
        model.refresh()
        try await waitUntil("the file") { !model.changes.isEmpty }
        model.stashChanges(message: "u", includeUntracked: true, keepIndex: false)
        try await waitUntil("the stash") { model.stashes.count == 1 }
        let stash = model.stashes[0]
        model.selectStash(stash.hash)
        try await waitUntil("the files") { !model.stashFiles.isEmpty }
        let change = try XCTUnwrap(model.stashFiles.first)

        let request = IDEDiffRequest.stashFile(
            hash: stash.hash, label: stash.ref, path: change.file.path, oldPath: nil,
            isUntracked: change.isUntracked, repositoryRoot: directory.path)
        let left = await model.diffContent(request.left.source)
        let right = await model.diffContent(request.right.source)

        XCTAssertEqual(left, .text(""))
        XCTAssertEqual(right, .text("from the stash\n"))
        XCTAssertTrue(request.title.contains(stash.ref))
    }
}
