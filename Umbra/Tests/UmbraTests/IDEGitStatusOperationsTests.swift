import AppKit
import Foundation
import GitIntelligence
import Penumbra
import XCTest
@testable import Umbra

/// Merge, rebase and conflict resolution through the model and the merge tab, with real git.
@MainActor
final class IDEGitStatusOperationsTests: XCTestCase {
    private var directory: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-model-ops-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Tester"],
                     ["config", "user.email", "t@example.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
    }

    override func tearDown() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = true
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func git(_ args: String...) async throws {
        _ = try await runner.run(args, in: directory)
    }

    private func commit(_ name: String, _ text: String, _ message: String) async throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try await git("add", name)
        try await git("commit", "-q", "-m", message)
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

    private func makeConflict() async throws {
        try await commit("a.txt", "one\nbase\nthree\n", "base")
        try await git("switch", "-q", "-c", "feature")
        try await commit("a.txt", "one\nfeature\nthree\n", "feature change")
        try await git("switch", "-q", "main")
        try await commit("a.txt", "one\nmain\nthree\n", "main change")
    }

    private func makeModel() async throws -> IDEGitStatusModel {
        let model = IDEGitStatusModel()
        model.setRoot(directory)
        try await waitUntil("the repository") { model.isRepository && model.currentBranch != nil }
        return model
    }

    // MARK: - Presentation

    func testOperationPresentationNamesTheOperation() {
        let merge = IDEGitOperationPresentation(
            operation: GitOperationState(kind: .merge, heads: [String(repeating: "a", count: 40)], message: "Merge branch 'feature' into main"),
            currentBranch: "main")
        XCTAssertEqual(merge.title, "Merging feature into main")
        XCTAssertEqual(merge.leftTitle, "Yours (main)")
        XCTAssertEqual(merge.rightTitle, "Theirs (feature)")
        XCTAssertFalse(merge.canSkip)

        let rebase = IDEGitOperationPresentation(
            operation: GitOperationState(kind: .rebase, step: 2, total: 5, onto: String(repeating: "b", count: 40), branch: "topic"),
            currentBranch: nil)
        XCTAssertEqual(rebase.title, "Rebasing topic onto bbbbbbb")
        XCTAssertEqual(rebase.progress, "2 of 5")
        XCTAssertTrue(rebase.canSkip)
        XCTAssertEqual(IDEGitOperationPresentation.mergedBranch(from: "Merge remote-tracking branch 'origin/x'"), "origin/x")
    }

    // MARK: - Model

    func testMergeConflictShowsAsAnOperationWithAConflictedFile() async throws {
        try await makeConflict()
        let model = try await makeModel()

        model.merge("feature")

        try await waitUntil("the merge to stop") { model.operation?.kind == .merge && !model.conflictedChanges.isEmpty }
        XCTAssertEqual(model.conflictedChanges.map(\.relativePath), ["a.txt"])
        XCTAssertFalse(model.actionFailed, "a stop is not a failure: \(model.actionStatus)")
        XCTAssertTrue(model.actionStatus.contains("conflicts"), model.actionStatus)
        XCTAssertEqual(model.operationPresentation?.title, "Merging feature into main")
    }

    func testContinueIsRefusedUntilTheConflictsAreResolved() async throws {
        try await makeConflict()
        let model = try await makeModel()
        model.merge("feature")
        try await waitUntil("the stop") { !model.conflictedChanges.isEmpty }

        model.continueOperation(message: nil)

        XCTAssertTrue(model.actionFailed)
        XCTAssertTrue(model.actionStatus.contains("Resolve"), model.actionStatus)
        XCTAssertEqual(model.operation?.kind, .merge)
    }

    func testTakingASideThenContinuingFinishesTheMerge() async throws {
        try await makeConflict()
        let model = try await makeModel()
        model.merge("feature")
        try await waitUntil("the stop") { !model.conflictedChanges.isEmpty }

        model.resolve(paths: [directory.appendingPathComponent("a.txt").path], taking: .theirs)
        try await waitUntil("the conflict to clear") { model.conflictedChanges.isEmpty && !model.isBusy }
        model.requestContinue()

        guard case .textPrompt(let prompt)? = model.sheets.current else { return XCTFail("a merge asks for its message") }
        XCTAssertTrue(prompt.initial.hasPrefix("Merge branch 'feature'"), prompt.initial)
        model.sheets.finish(model.sheets.current!.id)
        prompt.action("Merge feature")
        try await waitUntil("the merge to finish") { model.operation == nil && !model.isBusy }
        XCTAssertEqual(try read("a.txt"), "one\nfeature\nthree\n")
        try await waitUntil("the log") { model.commits.first?.subject == "Merge feature" }
    }

    func testAbortAsksAndThenRestoresTheBranch() async throws {
        try await makeConflict()
        let model = try await makeModel()
        model.merge("feature")
        try await waitUntil("the stop") { model.operation != nil }

        model.requestAbort()
        guard case .confirm(let confirmation)? = model.sheets.current else { return XCTFail("abort asks first") }
        XCTAssertTrue(confirmation.isDestructive)
        XCTAssertNotNil(model.operation, "nothing happens before the user confirms")
        confirmation.action()

        try await waitUntil("the abort") { model.operation == nil && !model.isBusy }
        XCTAssertEqual(try read("a.txt"), "one\nmain\nthree\n")
    }

    func testRebaseStopsThenSkipFinishes() async throws {
        try await makeConflict()
        try await git("switch", "-q", "feature")
        let model = try await makeModel()

        model.rebase(onto: "main")
        try await waitUntil("the rebase to stop") { model.operation?.kind == .rebase && !model.conflictedChanges.isEmpty }
        XCTAssertEqual(model.operation?.step, 1)
        XCTAssertTrue(model.operationPresentation?.canSkip == true)

        model.skipOperation()
        try await waitUntil("the rebase to end") { model.operation == nil && !model.isBusy }
        let log = try await runner.run(["log", "--format=%s"], in: directory)
        XCTAssertEqual(log.text.split(separator: "\n").map(String.init), ["main change", "base"])
    }

    func testBothAddedFilesCountAsAConflict() async throws {
        try await commit("seed.txt", "s\n", "seed")
        try await git("switch", "-q", "-c", "feature")
        try await commit("new.txt", "feature\n", "add on feature")
        try await git("switch", "-q", "main")
        try await commit("new.txt", "main\n", "add on main")
        let model = try await makeModel()

        model.merge("feature")

        try await waitUntil("the conflict") { model.operation?.kind == .merge }
        XCTAssertEqual(model.conflictedChanges.map(\.relativePath), ["new.txt"])
    }

    func testMergeWithLocalChangesInTheWayOffersToStash() async throws {
        try await commit("a.txt", "base\n", "base")
        try await git("switch", "-q", "-c", "feature")
        try await commit("a.txt", "feature\n", "feature change")
        try await git("switch", "-q", "main")
        try await commit("other.txt", "o\n", "main work")
        try "dirty\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let model = try await makeModel()

        model.merge("feature")

        try await waitUntil("the offer") { model.sheets.current != nil }
        guard case .confirm(let confirmation)? = model.sheets.current else { return XCTFail("expected a confirmation") }
        XCTAssertEqual(confirmation.confirmTitle, "Stash and Continue")
        XCTAssertNil(model.operation, "git refused before starting")
    }

    // MARK: - Merge session

    private func fakeSession(base: String, left: String, right: String, file: URL) -> IDEMergeSession {
        let session = IDEMergeSession(request: IDEMergeRequest(
            path: file.path, relativePath: "a.txt", leftTitle: "Yours", rightTitle: "Theirs", tabTitle: "a.txt (Merge)"))
        session.loadContent = { revision in
            switch revision {
            case .stage(1): return .text(base)
            case .stage(2): return .text(left)
            case .stage(3): return .text(right)
            default: return .failed("unexpected")
            }
        }
        return session
    }

    func testTheSessionStartsFromTheBaseWithNonConflictingChangesApplied() async throws {
        let file = directory.appendingPathComponent("a.txt")
        let session = fakeSession(
            base: "1\n2\n3\n4\n5\n", left: "1\nL\n3\n4\n5\n", right: "1\n2\n3\nX\n5\n", file: file)
        session.load()
        // Each side still differs from the result where the *other* side's change was taken.
        try await waitUntil("the session") { session.state == .ready && session.leftChunks.count == 1 && session.rightChunks.count == 1 }

        XCTAssertEqual(session.result.string, "1\nL\n3\nX\n5\n")
        XCTAssertEqual(session.originalConflictCount, 0)
        XCTAssertEqual(session.unresolvedCount, 0)
        XCTAssertEqual(session.leftChunks[0].right, 3 ..< 4, "the right side's change, seen from the left")
        XCTAssertEqual(session.rightChunks[0].left, 1 ..< 2, "the left side's change, seen from the right")
    }

    func testAConflictStaysOpenUntilTheResultTakesASideOrIsEdited() async throws {
        let file = directory.appendingPathComponent("a.txt")
        let session = fakeSession(base: "a\nb\nc\n", left: "a\nL\nc\n", right: "a\nR\nc\n", file: file)
        session.load()
        try await waitUntil("the chunks") { session.state == .ready && session.leftChunks.count == 1 && session.rightChunks.count == 1 }

        XCTAssertEqual(session.originalConflictCount, 1)
        XCTAssertEqual(session.result.string, "a\nb\nc\n", "a conflict starts as the base")
        XCTAssertEqual(session.unresolvedCount, 1)
        XCTAssertTrue(session.isConflicting(leftChunkAt: 0))
        XCTAssertTrue(session.isConflicting(rightChunkAt: 0))

        // Taking the left side: the left chunk disappears and nothing overlaps any more.
        let replacement = try XCTUnwrap(session.replacement(forLeftChunkAt: 0))
        XCTAssertEqual(replacement.text, "L\n")
        session.currentResultText = { "a\nL\nc\n" }
        session.resultTextDidChange()
        try await waitUntil("the left chunk to go") { session.leftChunks.isEmpty }
        XCTAssertEqual(session.unresolvedCount, 0)
        XCTAssertEqual(session.rightChunks.count, 1, "the right side still differs, as a choice not taken")
    }

    func testApplyHandsTheResultToTheHostAndReportsASuccess() async throws {
        let file = directory.appendingPathComponent("a.txt")
        let session = fakeSession(base: "a\n", left: "a\n", right: "b\n", file: file)
        var written: String?
        var applied = false
        session.applyResult = { text in
            written = text
            return nil
        }
        session.onApplied = { applied = true }
        session.load()
        try await waitUntil("the session") { session.state == .ready }

        session.apply()
        try await waitUntil("the apply") { applied }

        XCTAssertEqual(written, "b\n")
    }

    func testAFailedApplyKeepsTheTabAndShowsTheError() async throws {
        let file = directory.appendingPathComponent("a.txt")
        let session = fakeSession(base: "a\n", left: "a\n", right: "b\n", file: file)
        session.applyResult = { _ in "fatal: nope" }
        var applied = false
        session.onApplied = { applied = true }
        session.load()
        try await waitUntil("the session") { session.state == .ready }

        session.apply()
        try await waitUntil("the error") { session.applyError != nil }

        XCTAssertEqual(session.applyError, "fatal: nope")
        XCTAssertFalse(applied)
    }

    func testLineMappingThroughChunks() {
        // Source lines 2..<4 are target lines 2..<3: lines after it shift up by one.
        let chunks: [(Range<Int>, Range<Int>)] = [(2 ..< 4, 2 ..< 3)]
        XCTAssertEqual(IDEMergeViewerView.map(1, through: chunks), 1)
        XCTAssertEqual(IDEMergeViewerView.map(2, through: chunks), 2)
        XCTAssertEqual(IDEMergeViewerView.map(4, through: chunks), 3)
        XCTAssertEqual(IDEMergeViewerView.map(10, through: chunks), 9)
    }

    // MARK: - Tab

    func testOpeningTheMergeToolShowsATabThatAppliesAndStagesTheFile() async throws {
        try await makeConflict()
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        workspace.gitStatus.setRoot(directory)
        try await waitUntil("the repository") { workspace.gitStatus.isRepository }
        workspace.gitStatus.merge("feature")
        try await waitUntil("the stop") { !workspace.gitStatus.conflictedChanges.isEmpty }
        let path = directory.appendingPathComponent("a.txt").path

        workspace.openMergeTool(forPath: path)
        workspace.openMergeTool(forPath: path)

        let documents = workspace.workbench.allDocuments().filter { $0.contentKind == .diff }
        XCTAssertEqual(documents.count, 1, "the same file reuses its tab")
        let document = try XCTUnwrap(documents.first)
        XCTAssertEqual(document.displayName, "a.txt (Merge)")
        let session = try XCTUnwrap(workspace.mergeSessions[document.id])
        try await waitUntil("the session") { session.state == .ready }
        XCTAssertEqual(session.request.leftTitle, "Yours (main)")
        XCTAssertEqual(session.request.rightTitle, "Theirs (feature)")
        XCTAssertEqual(session.originalConflictCount, 1)

        session.currentResultText = { "one\nboth\nthree\n" }
        session.apply()
        try await waitUntil("the tab to close") { workspace.mergeSessions.isEmpty }

        XCTAssertEqual(try read("a.txt"), "one\nboth\nthree\n")
        try await waitUntil("the file to be resolved") { workspace.gitStatus.conflictedChanges.isEmpty }
        XCTAssertEqual(workspace.gitStatus.operation?.kind, .merge, "the merge still waits for Continue")
    }
}
