import XCTest
@testable import GitIntelligence

/// Cherry-pick, revert, reset, line history and interactive rebase, against real git.
final class GitHistoryIntegrationTests: XCTestCase {
    private var directory: URL!
    private var repo: GitRepository!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-history-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Tester"],
                     ["config", "user.email", "t@example.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
        let found = await GitRepository.discover(from: directory)
        repo = try XCTUnwrap(found)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func git(_ args: String...) async throws {
        _ = try await runner.run(args, in: directory)
    }

    @discardableResult
    private func commit(_ name: String, _ text: String, _ message: String) async throws -> String {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try await git("add", name)
        try await git("commit", "-q", "-m", message)
        let out = try await runner.run(["rev-parse", "HEAD"], in: directory)
        return out.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private func subjects() async throws -> [String] {
        try await repo.log(scope: .head).map(\.subject)
    }

    // MARK: - Cherry-pick and revert

    func testCherryPickAppliesCommitsInTheGivenOrder() async throws {
        try await commit("base.txt", "b\n", "base")
        try await git("switch", "-q", "-c", "feature")
        let one = try await commit("one.txt", "1\n", "one")
        let two = try await commit("two.txt", "2\n", "two")
        try await git("switch", "-q", "main")

        let result = try await repo.cherryPick([one, two])

        XCTAssertFalse(result.isStopped)
        let log = try await subjects()
        XCTAssertEqual(log, ["two", "one", "base"])
        XCTAssertEqual(try read("two.txt"), "2\n")
    }

    func testAConflictingCherryPickStopsAndCanBeAborted() async throws {
        try await commit("a.txt", "base\n", "base")
        try await git("switch", "-q", "-c", "feature")
        let theirs = try await commit("a.txt", "feature\n", "feature")
        try await git("switch", "-q", "main")
        try await commit("a.txt", "main\n", "main")

        let result = try await repo.cherryPick([theirs])

        XCTAssertTrue(result.isStopped)
        XCTAssertEqual(repo.state().operation?.kind, .cherryPick)
        _ = try await repo.abortOperation(.cherryPick)
        XCTAssertNil(repo.state().operation)
    }

    func testAMergeCommitCannotBeCherryPickedOrReverted() async throws {
        try await commit("a.txt", "base\n", "base")
        try await git("switch", "-q", "-c", "feature")
        try await commit("b.txt", "b\n", "feature work")
        try await git("switch", "-q", "main")
        try await commit("c.txt", "c\n", "main work")
        try await git("merge", "-q", "--no-edit", "feature")
        let tip = try await repo.log(scope: .head)[0]
        let merge = tip.hash
        XCTAssertTrue(tip.isMerge)

        do {
            _ = try await repo.revertCommits([merge])
            XCTFail("a merge commit must be refused")
        } catch {
            XCTAssertTrue(error is GitError)
        }
    }

    func testRevertMakesACommitThatUndoesTheChange() async throws {
        try await commit("a.txt", "one\n", "one")
        let two = try await commit("a.txt", "two\n", "two")

        _ = try await repo.revertCommits([two])

        XCTAssertEqual(try read("a.txt"), "one\n")
        let log = try await subjects()
        XCTAssertEqual(log.first, "Revert \"two\"")
    }

    // MARK: - Reset

    func testResetModes() async throws {
        let first = try await commit("a.txt", "1\n", "first")
        try await commit("a.txt", "2\n", "second")

        _ = try await repo.reset(to: first, mode: .soft)
        var status = try await repo.status()
        XCTAssertEqual(status.first?.indexCode, "M", "soft keeps the change staged")
        XCTAssertEqual(try read("a.txt"), "2\n")

        try await git("commit", "-q", "-m", "second again")
        _ = try await repo.reset(to: first, mode: .mixed)
        status = try await repo.status()
        XCTAssertEqual(status.first?.indexCode, " ")
        XCTAssertEqual(status.first?.worktreeCode, "M", "mixed unstages but keeps the file")

        try await git("commit", "-q", "-am", "third")
        _ = try await repo.reset(to: first, mode: .hard)
        XCTAssertEqual(try read("a.txt"), "1\n")
        status = try await repo.status()
        XCTAssertTrue(status.isEmpty)
    }

    func testKeepRefusesWhenLocalChangesWouldBeLost() async throws {
        let first = try await commit("a.txt", "1\n", "first")
        try await commit("a.txt", "2\n", "second")
        try "dirty\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        do {
            _ = try await repo.reset(to: first, mode: .keep)
            XCTFail("keep must refuse")
        } catch {
            XCTAssertTrue(error is GitError)
        }
        XCTAssertEqual(try read("a.txt"), "dirty\n")
    }

    func testUndoLastCommitKeepsItsChangesStaged() async throws {
        try await commit("a.txt", "1\n", "first")
        try await commit("a.txt", "2\n", "second")

        try await repo.undoLastCommit()

        let log = try await subjects()
        XCTAssertEqual(log, ["first"])
        let status = try await repo.status()
        XCTAssertEqual(status.first?.indexCode, "M")
    }

    func testTheFirstCommitCannotBeUndone() async throws {
        try await commit("a.txt", "1\n", "first")
        do {
            try await repo.undoLastCommit()
            XCTFail("there is nothing before the first commit")
        } catch {
            XCTAssertTrue(error is GitError)
        }
    }

    func testAmendMessageLeavesStagedChangesOut() async throws {
        try await commit("a.txt", "1\n", "first")
        try "2\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git("add", "a.txt")

        try await repo.amendMessage("better message")

        let log = try await subjects()
        XCTAssertEqual(log, ["better message"])
        let status = try await repo.status()
        XCTAssertEqual(status.first?.indexCode, "M", "the staged change is not in the amended commit")
    }

    // MARK: - Reading history

    func testLogFiltersByPathAndDate() async throws {
        try await commit("a.txt", "1\n", "a one")
        try await commit("b.txt", "1\n", "b one")
        try await commit("a.txt", "2\n", "a two")

        let aOnly = try await repo.log(scope: .head, paths: ["a.txt"])
        XCTAssertEqual(aOnly.map(\.subject), ["a two", "a one"])

        let future = try await repo.log(scope: .head, since: Date().addingTimeInterval(3600))
        XCTAssertTrue(future.isEmpty)
        let past = try await repo.log(scope: .head, until: Date().addingTimeInterval(-3600))
        XCTAssertTrue(past.isEmpty)
        let window = try await repo.log(scope: .head, since: Date().addingTimeInterval(-3600), until: Date().addingTimeInterval(3600))
        XCTAssertEqual(window.count, 3)
    }

    func testLineHistoryListsOnlyTheCommitsThatTouchedThoseLines() async throws {
        try await commit("a.txt", "one\ntwo\nthree\nfour\n", "add file")
        try await commit("a.txt", "one\nTWO\nthree\nfour\n", "change line 2")
        try await commit("a.txt", "one\nTWO\nthree\nFOUR\n", "change line 4")

        let entries = try await repo.lineHistory(path: "a.txt", start: 2, end: 2)

        XCTAssertEqual(entries.map(\.commit.subject), ["change line 2", "add file"])
        XCTAssertTrue(entries[0].patch.contains("+TWO"), entries[0].patch)
        XCTAssertFalse(entries[0].patch.contains("FOUR"))
    }

    func testBranchesContainingAndRemoteBranches() async throws {
        let first = try await commit("a.txt", "1\n", "first")
        try await git("branch", "other")
        try await commit("a.txt", "2\n", "second")

        let names = await repo.branchesContaining(first)
        XCTAssertEqual(Set(names), ["main", "other"])
        let remote = await repo.remoteBranchesContaining(first)
        XCTAssertTrue(remote.isEmpty)
    }

    // MARK: - Interactive rebase

    private func makeLinearHistory() async throws -> [String] {
        try await commit("base.txt", "b\n", "base")
        let a = try await commit("a.txt", "a\n", "add a")
        let b = try await commit("b.txt", "b\n", "add b")
        let c = try await commit("c.txt", "c\n", "add c")
        return [a, b, c]
    }

    func testRebasePlanListsTheCommitsOldestFirst() async throws {
        let hashes = try await makeLinearHistory()

        let (base, plan) = try await repo.rebasePlan(startingAt: hashes[0])

        XCTAssertEqual(plan.steps.map(\.subject), ["add a", "add b", "add c"])
        XCTAssertEqual(plan.steps.map(\.hash), hashes)
        let parent = try await runner.run(["rev-parse", hashes[0] + "^"], in: directory)
        XCTAssertEqual(base, parent.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testRebasePlanRefusesTheRootAndMerges() async throws {
        let root = try await commit("a.txt", "1\n", "root")
        do {
            _ = try await repo.rebasePlan(startingAt: root)
            XCTFail("the root has no parent to rebase onto")
        } catch {
            XCTAssertTrue(error is GitError)
        }
        try await git("switch", "-q", "-c", "feature")
        try await commit("b.txt", "b\n", "feature work")
        try await git("switch", "-q", "main")
        try await commit("c.txt", "c\n", "main work")
        let before = try await repo.log(scope: .head)[0].hash
        try await git("merge", "-q", "--no-edit", "feature")
        do {
            _ = try await repo.rebasePlan(startingAt: before)
            XCTFail("a merge in the range must be refused")
        } catch {
            XCTAssertTrue(error is GitError)
        }
    }

    func testReorderingCommits() async throws {
        let hashes = try await makeLinearHistory()
        var (base, plan) = try await repo.rebasePlan(startingAt: hashes[0])
        plan.steps.swapAt(1, 2)

        let result = try await repo.interactiveRebase(onto: base, plan: plan)

        XCTAssertFalse(result.isStopped)
        let log = try await subjects()
        XCTAssertEqual(log, ["add b", "add c", "add a", "base"])
    }

    func testRewordingACommitInTheMiddle() async throws {
        let hashes = try await makeLinearHistory()
        var (base, plan) = try await repo.rebasePlan(startingAt: hashes[0])
        plan.steps[1].action = .reword
        plan.steps[1].message = "add b, properly described\n\nWith a body."

        _ = try await repo.interactiveRebase(onto: base, plan: plan)

        let log = try await repo.log(scope: .head)
        XCTAssertEqual(log.map(\.subject), ["add c", "add b, properly described", "add a", "base"])
        let full = try await repo.commit(hash: log[1].hash)
        XCTAssertTrue(full?.body.contains("With a body.") == true)
        XCTAssertEqual(try read("b.txt"), "b\n")
    }

    func testSquashWithACustomMessageAndFixupWithGits() async throws {
        let hashes = try await makeLinearHistory()
        var (base, plan) = try await repo.rebasePlan(startingAt: hashes[0])
        plan.steps[0].message = "a, b and c together"
        plan.steps[1].action = .squash
        plan.steps[2].action = .fixup

        _ = try await repo.interactiveRebase(onto: base, plan: plan)

        let log = try await repo.log(scope: .head)
        XCTAssertEqual(log.map(\.subject), ["a, b and c together", "base"])
        XCTAssertEqual(try read("c.txt"), "c\n")
    }

    func testFixupKeepsTheOlderMessage() async throws {
        let hashes = try await makeLinearHistory()
        var (base, plan) = try await repo.rebasePlan(startingAt: hashes[1])
        plan.steps[1].action = .fixup

        _ = try await repo.interactiveRebase(onto: base, plan: plan)

        let log = try await subjects()
        XCTAssertEqual(log, ["add b", "add a", "base"])
    }

    func testDroppingACommit() async throws {
        let hashes = try await makeLinearHistory()
        var (base, plan) = try await repo.rebasePlan(startingAt: hashes[0])
        plan.steps[1].action = .drop

        _ = try await repo.interactiveRebase(onto: base, plan: plan)

        let log = try await subjects()
        XCTAssertEqual(log, ["add c", "add a", "base"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("b.txt").path))
    }

    func testEditStopsTheRebaseAndContinueFinishesIt() async throws {
        let hashes = try await makeLinearHistory()
        var (base, plan) = try await repo.rebasePlan(startingAt: hashes[0])
        plan.steps[1].action = .edit

        let result = try await repo.interactiveRebase(onto: base, plan: plan)

        XCTAssertTrue(result.isStopped)
        XCTAssertEqual(repo.state().operation?.kind, .rebase)
        let finished = try await repo.continueOperation(.rebase)
        XCTAssertFalse(finished.isStopped)
        XCTAssertNil(repo.state().operation)
        let log = try await subjects()
        XCTAssertEqual(log, ["add c", "add b", "add a", "base"])
    }

    func testAReorderThatConflictsStopsAndCanBeAborted() async throws {
        try await commit("f.txt", "1\n", "base")
        let first = try await commit("f.txt", "2\n", "set 2")
        let second = try await commit("f.txt", "3\n", "set 3")
        _ = second
        var (base, plan) = try await repo.rebasePlan(startingAt: first)
        plan.steps.reverse()

        let result = try await repo.interactiveRebase(onto: base, plan: plan)

        XCTAssertTrue(result.isStopped)
        _ = try await repo.abortOperation(.rebase)
        let log = try await subjects()
        XCTAssertEqual(log, ["set 3", "set 2", "base"])
    }

    func testAPlanThatDoesNotMatchTheHistoryIsRefused() async throws {
        let hashes = try await makeLinearHistory()
        var (base, plan) = try await repo.rebasePlan(startingAt: hashes[0])
        try await commit("d.txt", "d\n", "add d")
        plan.steps[1].action = .drop

        do {
            _ = try await repo.interactiveRebase(onto: base, plan: plan)
            XCTFail("a new commit changed the range")
        } catch {
            XCTAssertTrue(error is GitError)
        }
    }

    func testPlanRefusedWhileAnotherOperationIsInProgress() async throws {
        try await commit("a.txt", "base\n", "base")
        try await git("switch", "-q", "-c", "feature")
        let theirs = try await commit("a.txt", "feature\n", "feature")
        try await git("switch", "-q", "main")
        try await commit("a.txt", "main\n", "main")
        let tip = try await repo.log(scope: .head)[0].hash
        _ = try await repo.cherryPick([theirs])
        XCTAssertNotNil(repo.state().operation)
        let plan = GitRebasePlan(steps: [GitRebaseStep(hash: tip, subject: "main")])

        do {
            _ = try await repo.interactiveRebase(onto: "HEAD", plan: plan)
            XCTFail("an operation is in progress")
        } catch {
            XCTAssertTrue(error is GitError)
        }
    }
}

/// What the commit options and the pre-commit facts read from git.
final class GitCommitChecksIntegrationTests: XCTestCase {
    private var directory: URL!
    private var repo: GitRepository!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-checks-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Tester"],
                     ["config", "user.email", "t@example.com"], ["config", "commit.gpgsign", "false"],
                     ["config", "core.autocrlf", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
        let found = await GitRepository.discover(from: directory)
        repo = try XCTUnwrap(found)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testParsers() {
        let problems = GitDiffCheckParser.parse("a.txt:3: leftover conflict marker\nb.txt:10: trailing whitespace.\n")
        XCTAssertEqual(problems.map(\.path), ["a.txt", "b.txt"])
        XCTAssertTrue(problems[0].isConflictMarker)
        XCTAssertFalse(problems[1].isConflictMarker)
        let endings = GitEOLParser.parse("i/lf    w/lf    attr/                \ta.txt\ni/crlf  w/crlf  attr/                \tb c.txt\ni/-text w/-text attr/                \tbin\n")
        XCTAssertEqual(endings["a.txt"], .lf)
        XCTAssertEqual(endings["b c.txt"], .crlf)
        XCTAssertEqual(endings["bin"], GitIndexLineEndings.binary)
    }

    func testStagedConflictMarkersAreFound() async throws {
        try write("a.txt", "one\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> branch\n")
        _ = try await runner.run(["add", "a.txt"], in: directory)

        let problems = await repo.stagedCheckProblems()

        XCTAssertTrue(problems.contains { $0.path == "a.txt" && $0.isConflictMarker })
    }

    func testACleanIndexHasNoProblems() async throws {
        try write("a.txt", "fine\n")
        _ = try await runner.run(["add", "a.txt"], in: directory)
        let problems = await repo.stagedCheckProblems()
        XCTAssertTrue(problems.isEmpty)
    }

    func testCRLFIsDetectedAndNormalised() async throws {
        try write("dos.txt", "one\r\ntwo\r\n")
        try write("unix.txt", "one\ntwo\n")
        _ = try await runner.run(["add", "dos.txt", "unix.txt"], in: directory)

        let before = await repo.indexLineEndings(of: ["dos.txt", "unix.txt"])
        XCTAssertEqual(before["dos.txt"], .crlf)
        XCTAssertEqual(before["unix.txt"], .lf)

        try await repo.normalizeLineEndings(of: ["dos.txt"])

        let after = await repo.indexLineEndings(of: ["dos.txt"])
        XCTAssertEqual(after["dos.txt"], .lf)
        let value = await repo.config("core.autocrlf")
        XCTAssertEqual(value, "input")
    }

    func testSignoffAndSkippedHooks() async throws {
        let hooks = directory.appendingPathComponent(".git/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("pre-commit")
        try "#!/bin/sh\necho blocked >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try write("a.txt", "1\n")

        do {
            _ = try await repo.commit(message: "blocked", paths: [], untrackedPaths: ["a.txt"], amend: false)
            XCTFail("the hook must block the commit")
        } catch {
            XCTAssertTrue(error is GitError)
        }
        _ = try await repo.commit(message: "signed", paths: [], untrackedPaths: [], amend: false, signoff: true, skipHooks: true)

        let message = await repo.lastCommitMessage()
        XCTAssertTrue(message?.contains("Signed-off-by: Tester <t@example.com>") == true, message ?? "nil")
    }
}
