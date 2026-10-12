import Foundation
import GitIntelligence
import XCTest
@testable import Umbra

/// The Log's commit actions, filters and line history through `IDEGitStatusModel`, with real git.
@MainActor
final class IDEGitStatusHistoryActionsTests: XCTestCase {
    private var directory: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-model-hist-\(UUID().uuidString)", isDirectory: true)
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

    private func git(_ args: String...) async throws {
        _ = try await runner.run(args, in: directory)
    }

    private func commit(_ name: String, _ text: String, _ message: String) async throws {
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(name).deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try await git("add", name)
        try await git("commit", "-q", "-m", message)
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func makeModel(expecting commits: Int) async throws -> IDEGitStatusModel {
        let model = IDEGitStatusModel()
        model.setRoot(directory)
        try await waitUntil("the log") { model.isRepository && model.commits.count == commits }
        return model
    }

    private func subjects(_ model: IDEGitStatusModel) -> [String] { model.commits.map(\.subject) }

    private func settled(_ model: IDEGitStatusModel) async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
        try await waitUntil("the action") { !model.isBusy }
    }

    // MARK: - Selection

    func testActionsApplyToTheSelectionOldestFirst() async throws {
        try await commit("a.txt", "1\n", "one")
        try await commit("a.txt", "2\n", "two")
        try await commit("a.txt", "3\n", "three")
        let model = try await makeModel(expecting: 3)

        model.selectCommit(model.commits[0].hash)
        model.toggleCommitSelection(model.commits[2].hash)

        XCTAssertEqual(model.commitsForAction(on: model.commits[0].hash).map(\.subject), ["one", "three"])
        XCTAssertEqual(model.commitsForAction(on: model.commits[1].hash).map(\.subject), ["two"],
                       "a row outside the selection acts alone")
        model.selectCommit(model.commits[0].hash)
        model.extendCommitSelection(to: model.commits[2].hash)
        XCTAssertEqual(model.selectedCommitHashes.count, 3)
    }

    func testSelectingACommitListsTheBranchesThatContainIt() async throws {
        try await commit("a.txt", "1\n", "one")
        try await git("branch", "other")
        try await commit("a.txt", "2\n", "two")
        let model = try await makeModel(expecting: 2)

        model.selectCommit(model.commits[1].hash)

        try await waitUntil("the branches") { Set(model.commitBranches) == ["main", "other"] }
    }

    // MARK: - Actions

    func testCherryPickAndRevert() async throws {
        try await commit("base.txt", "b\n", "base")
        try await git("switch", "-q", "-c", "feature")
        try await commit("f.txt", "f\n", "feature work")
        try await git("switch", "-q", "main")
        // The log lists every branch, so the feature commit is in it already.
        let model = try await makeModel(expecting: 2)
        let feature = try XCTUnwrap(model.commits.first { $0.subject == "feature work" })

        model.cherryPick([feature.hash])
        try await waitUntil("the pick") { model.commits.contains { $0.subject == "feature work" && $0.refs.contains("main") } }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("f.txt").path))

        let picked = try XCTUnwrap(model.commits.first { $0.refs.contains("main") })
        model.revertCommits([picked.hash])
        try await waitUntil("the revert") { !FileManager.default.fileExists(atPath: directory.appendingPathComponent("f.txt").path) }
        try await settled(model)
    }

    func testResetOpensASheetAndMovesTheBranch() async throws {
        try await commit("a.txt", "1\n", "one")
        try await commit("a.txt", "2\n", "two")
        let model = try await makeModel(expecting: 2)
        let first = model.commits[1]

        model.requestReset(to: first)
        try await waitUntil("the sheet") { model.sheets.current != nil }
        guard case .reset(let request)? = model.sheets.current else { return XCTFail("expected the reset sheet") }
        XCTAssertEqual(request.hash, first.hash)
        XCTAssertEqual(request.branch, "main")
        model.sheets.finish(model.sheets.current!.id)

        model.reset(to: first.hash, mode: .hard)
        try await waitUntil("the reset") { model.commits.count == 1 }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("a.txt"), encoding: .utf8), "1\n")
    }

    func testEditingTheMessageOfAnOlderCommit() async throws {
        try await commit("a.txt", "1\n", "one")
        try await commit("b.txt", "2\n", "two")
        try await commit("c.txt", "3\n", "three")
        let model = try await makeModel(expecting: 3)
        let middle = model.commits[1]

        model.requestEditMessage(of: middle)
        try await waitUntil("the prompt") { model.sheets.current != nil }
        guard case .textPrompt(let prompt)? = model.sheets.current else { return XCTFail("expected a prompt") }
        XCTAssertEqual(prompt.initial, "two")
        model.sheets.finish(model.sheets.current!.id)
        prompt.action("two, better")

        try await waitUntil("the new message") { self.subjects(model) == ["three", "two, better", "one"] }
    }

    func testEditingTheHeadMessageAmends() async throws {
        try await commit("a.txt", "1\n", "one")
        try await commit("b.txt", "2\n", "two")
        let model = try await makeModel(expecting: 2)

        model.requestEditMessage(of: model.commits[0])
        try await waitUntil("the prompt") { model.sheets.current != nil }
        guard case .textPrompt(let prompt)? = model.sheets.current else { return XCTFail("expected a prompt") }
        model.sheets.finish(model.sheets.current!.id)
        prompt.action("two, amended")

        try await waitUntil("the amend") { self.subjects(model) == ["two, amended", "one"] }
    }

    func testSquashCombinesSelectedCommits() async throws {
        try await commit("a.txt", "1\n", "one")
        try await commit("b.txt", "2\n", "two")
        try await commit("c.txt", "3\n", "three")
        let model = try await makeModel(expecting: 3)
        let selected = model.commits.filter { ["two", "three"].contains($0.subject) }.reversed() as [IDEGitCommit]

        model.requestSquash(selected)
        guard case .textPrompt(let prompt)? = model.sheets.current else { return XCTFail("expected a prompt") }
        XCTAssertEqual(prompt.initial, "two\nthree")
        model.sheets.finish(model.sheets.current!.id)
        prompt.action("two and three")

        try await waitUntil("the squash") { self.subjects(model) == ["two and three", "one"] }
    }

    func testFixupIntoParentKeepsTheParentsMessage() async throws {
        try await commit("base.txt", "b\n", "base")
        try await commit("a.txt", "1\n", "one")
        try await commit("a.txt", "2\n", "fix typo")
        let model = try await makeModel(expecting: 3)

        model.fixupIntoParent(model.commits[0])

        try await waitUntil("the fixup") { self.subjects(model) == ["one", "base"] }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("a.txt"), encoding: .utf8), "2\n")
    }

    func testFixupIntoTheRootCommitIsReportedNotAttempted() async throws {
        try await commit("a.txt", "1\n", "root")
        try await commit("a.txt", "2\n", "fix typo")
        let model = try await makeModel(expecting: 2)

        model.fixupIntoParent(model.commits[0])

        try await waitUntil("the refusal") { model.actionFailed }
        XCTAssertEqual(subjects(model), ["fix typo", "root"], "nothing changed")
    }

    func testDropAsksThenRemovesTheCommit() async throws {
        try await commit("a.txt", "1\n", "one")
        try await commit("b.txt", "2\n", "two")
        try await commit("c.txt", "3\n", "three")
        let model = try await makeModel(expecting: 3)
        let two = try XCTUnwrap(model.commits.first { $0.subject == "two" })

        model.requestDrop([two])
        try await waitUntil("the confirmation") { model.sheets.current != nil }
        guard case .confirm(let confirmation)? = model.sheets.current else { return XCTFail("expected a confirmation") }
        XCTAssertTrue(confirmation.isDestructive)
        XCTAssertEqual(model.commits.count, 3, "nothing is dropped before the user confirms")
        model.sheets.finish(model.sheets.current!.id)
        confirmation.action()

        try await waitUntil("the drop") { self.subjects(model) == ["three", "one"] }
    }

    func testInteractiveRebaseSheetCarriesThePlanAndStartRunsIt() async throws {
        try await commit("base.txt", "b\n", "base")
        try await commit("a.txt", "1\n", "add a")
        try await commit("b.txt", "2\n", "add b")
        let model = try await makeModel(expecting: 3)
        let addA = try XCTUnwrap(model.commits.first { $0.subject == "add a" })

        model.requestInteractiveRebase(from: addA)
        try await waitUntil("the sheet") { model.sheets.current != nil }
        guard case .rebase(let request)? = model.sheets.current else { return XCTFail("expected the rebase sheet") }
        XCTAssertEqual(request.steps.map(\.subject), ["add a", "add b"])
        model.sheets.finish(model.sheets.current!.id)

        var plan = GitRebasePlan(steps: request.steps)
        plan.steps.reverse()
        model.startInteractiveRebase(base: request.base, plan: plan)

        try await waitUntil("the reorder") { self.subjects(model) == ["add a", "add b", "base"] }
    }

    func testRebasingFromTheRootCommitReportsWhyNot() async throws {
        try await commit("a.txt", "1\n", "root")
        let model = try await makeModel(expecting: 1)

        model.requestInteractiveRebase(from: model.commits[0])

        try await waitUntil("the refusal") { model.actionFailed }
        XCTAssertNil(model.sheets.current)
    }

    // MARK: - Filters and line history

    func testPathAndDateFiltersNarrowTheLog() async throws {
        try await commit("src/a.txt", "1\n", "in src")
        try await commit("docs/b.txt", "2\n", "in docs")
        let model = try await makeModel(expecting: 2)

        model.setHistoryPath("src")
        try await waitUntil("the path filter") { self.subjects(model) == ["in src"] }
        XCTAssertTrue(model.commits.allSatisfy { $0.graph == nil }, "a filtered list has no lanes")

        model.setHistoryPath("")
        try await waitUntil("the whole log") { model.commits.count == 2 }
        model.setHistoryWindow(since: Date().addingTimeInterval(3600))
        try await waitUntil("the empty window") { model.commits.isEmpty }
        model.setHistoryWindow(since: nil)
        try await waitUntil("the log again") { model.commits.count == 2 }
        XCTAssertFalse(model.hasMoreHistory)
    }

    func testLineHistoryLoadsTheCommitsThatChangedTheLines() async throws {
        try await commit("a.txt", "one\ntwo\nthree\n", "add file")
        try await commit("a.txt", "one\nTWO\nthree\n", "change two")
        try await commit("a.txt", "one\nTWO\nTHREE\n", "change three")
        let model = try await makeModel(expecting: 3)

        model.showLineHistory(path: directory.appendingPathComponent("a.txt").path, startLine: 2, endLine: 2)

        try await waitUntil("the entries") { model.lineHistory?.entries.count == 2 }
        XCTAssertEqual(model.lineHistory?.entries.map(\.commit.subject), ["change two", "add file"])
        XCTAssertEqual(model.lineHistory?.selectedHash, model.lineHistory?.entries.first?.commit.hash)
        model.clearLineHistory()
        XCTAssertNil(model.lineHistory)
    }
}
