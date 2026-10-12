import XCTest
@testable import GitIntelligence

/// Merge, rebase and the commands that resolve, continue, skip and abort them, against real git.
final class GitOperationsIntegrationTests: XCTestCase {
    private var directory: URL!
    private var repo: GitRepository!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-ops-\(UUID().uuidString)", isDirectory: true)
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

    private func commit(_ name: String, _ text: String, _ message: String) async throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try await git("add", name)
        try await git("commit", "-q", "-m", message)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    /// `main` and `feature` both change a.txt's only line.
    private func makeConflict() async throws {
        try await commit("a.txt", "base\n", "base")
        try await git("switch", "-q", "-c", "feature")
        try await commit("a.txt", "feature\n", "feature change")
        try await git("switch", "-q", "main")
        try await commit("a.txt", "main\n", "main change")
    }

    // MARK: - Merge

    func testACleanMergeCompletes() async throws {
        try await commit("a.txt", "base\n", "base")
        try await git("switch", "-q", "-c", "feature")
        try await commit("b.txt", "b\n", "feature work")
        try await git("switch", "-q", "main")
        try await commit("c.txt", "c\n", "main work")

        let result = try await repo.merge("feature")

        XCTAssertFalse(result.isStopped)
        XCTAssertNil(repo.state().operation)
        let log = try await repo.log(scope: .head)
        XCTAssertTrue(log.first?.isMerge == true)
    }

    func testNoFastForwardMakesAMergeCommitEvenWhenItCouldFastForward() async throws {
        try await commit("a.txt", "base\n", "base")
        try await git("switch", "-q", "-c", "feature")
        try await commit("b.txt", "b\n", "feature work")
        try await git("switch", "-q", "main")

        _ = try await repo.merge("feature", noFastForward: true)

        let log = try await repo.log(scope: .head)
        XCTAssertTrue(log.first?.isMerge == true)
    }

    func testAConflictingMergeStopsAndReportsTheConflict() async throws {
        try await makeConflict()

        let result = try await repo.merge("feature")

        XCTAssertTrue(result.isStopped)
        XCTAssertTrue(result.report.contains("CONFLICT"), result.report)
        XCTAssertEqual(repo.state().operation?.kind, .merge)
        let files = try await repo.conflictedFiles()
        XCTAssertEqual(files, ["a.txt"])
        let stages = try await repo.conflictStages(of: "a.txt")
        XCTAssertEqual(stages, GitConflictStages(hasBase: true, hasOurs: true, hasTheirs: true))
    }

    func testConflictStagesAreReadableAsRevisions() async throws {
        try await makeConflict()
        _ = try await repo.merge("feature")

        let base = try await repo.fileContents(at: .stage(1), path: "a.txt")
        let ours = try await repo.fileContents(at: .stage(2), path: "a.txt")
        let theirs = try await repo.fileContents(at: .stage(3), path: "a.txt")

        XCTAssertEqual(base.map { String(decoding: $0, as: UTF8.self) }, "base\n")
        XCTAssertEqual(ours.map { String(decoding: $0, as: UTF8.self) }, "main\n")
        XCTAssertEqual(theirs.map { String(decoding: $0, as: UTF8.self) }, "feature\n")
    }

    func testResolveTakingTheirsThenContinueCommitsTheMerge() async throws {
        try await makeConflict()
        _ = try await repo.merge("feature")

        try await repo.resolve(paths: ["a.txt"], taking: .theirs)
        let result = try await repo.continueOperation(.merge)

        XCTAssertFalse(result.isStopped)
        XCTAssertNil(repo.state().operation)
        XCTAssertEqual(try read("a.txt"), "feature\n")
        let log = try await repo.log(scope: .head)
        XCTAssertTrue(log[0].isMerge)
        XCTAssertTrue(log[0].subject.hasPrefix("Merge branch 'feature'"), log[0].subject)
    }

    func testResolveWithCustomContentsStagesIt() async throws {
        try await makeConflict()
        _ = try await repo.merge("feature")

        try await repo.resolve(path: "a.txt", with: Data("both\n".utf8))
        _ = try await repo.continueOperation(.merge, message: "Merge feature, keeping both")

        XCTAssertEqual(try read("a.txt"), "both\n")
        let log = try await repo.log(scope: .head)
        XCTAssertEqual(log[0].subject, "Merge feature, keeping both")
    }

    func testContinuingWithUnresolvedFilesFails() async throws {
        try await makeConflict()
        _ = try await repo.merge("feature")

        do {
            _ = try await repo.continueOperation(.merge)
            XCTFail("a merge with conflicts cannot be committed")
        } catch {
            XCTAssertTrue(error is GitError)
        }
        XCTAssertEqual(repo.state().operation?.kind, .merge)
    }

    func testAbortGoesBackToBeforeTheMerge() async throws {
        try await makeConflict()
        _ = try await repo.merge("feature")

        _ = try await repo.abortOperation(.merge)

        XCTAssertNil(repo.state().operation)
        XCTAssertEqual(try read("a.txt"), "main\n")
        let status = try await repo.status()
        XCTAssertTrue(status.isEmpty)
    }

    func testMergingAnUnknownBranchIsAnErrorNotAStop() async throws {
        try await commit("a.txt", "base\n", "base")
        do {
            _ = try await repo.merge("no-such-branch")
            XCTFail("an unknown branch is an error")
        } catch {
            XCTAssertTrue(error is GitError)
        }
        XCTAssertNil(repo.state().operation)
    }

    func testModifyDeleteConflictResolvedByTheSideThatDeleted() async throws {
        try await commit("a.txt", "base\n", "base")
        try await git("switch", "-q", "-c", "feature")
        try await git("rm", "-q", "a.txt")
        try await git("commit", "-q", "-m", "delete a")
        try await git("switch", "-q", "main")
        try await commit("a.txt", "modified\n", "modify a")
        let result = try await repo.merge("feature")
        XCTAssertTrue(result.isStopped)
        let stages = try await repo.conflictStages(of: "a.txt")
        XCTAssertEqual(stages, GitConflictStages(hasBase: true, hasOurs: true, hasTheirs: false))

        try await repo.resolve(paths: ["a.txt"], taking: .theirs)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("a.txt").path))
        let remaining = try await repo.conflictedFiles()
        XCTAssertTrue(remaining.isEmpty)
        _ = try await repo.continueOperation(.merge)
        XCTAssertNil(repo.state().operation)
    }

    // MARK: - Rebase

    func testRebaseStopsAtAConflictAndContinuesAfterResolving() async throws {
        try await makeConflict()
        try await git("switch", "-q", "feature")

        let result = try await repo.rebase(onto: "main")

        XCTAssertTrue(result.isStopped)
        let state = repo.state().operation
        XCTAssertEqual(state?.kind, .rebase)
        XCTAssertEqual(state?.step, 1)
        XCTAssertEqual(state?.total, 1)
        // During a rebase "ours" is the branch being rebased onto and "theirs" the commit replayed.
        let ours = try await repo.fileContents(at: .stage(2), path: "a.txt")
        XCTAssertEqual(ours.map { String(decoding: $0, as: UTF8.self) }, "main\n")

        try await repo.resolve(paths: ["a.txt"], taking: .theirs)
        let finished = try await repo.continueOperation(.rebase)

        XCTAssertFalse(finished.isStopped)
        XCTAssertNil(repo.state().operation)
        let branch = await repo.currentBranch()
        XCTAssertEqual(branch, "feature")
        let log = try await repo.log(scope: .head)
        XCTAssertEqual(log.map(\.subject), ["feature change", "main change", "base"])
    }

    func testSkipDropsTheCommitThatConflicts() async throws {
        try await makeConflict()
        try await git("switch", "-q", "feature")
        _ = try await repo.rebase(onto: "main")

        let result = try await repo.skipOperation(.rebase)

        XCTAssertFalse(result.isStopped)
        XCTAssertNil(repo.state().operation)
        let log = try await repo.log(scope: .head)
        XCTAssertEqual(log.map(\.subject), ["main change", "base"])
    }

    func testAbortingARebaseRestoresTheBranch() async throws {
        try await makeConflict()
        try await git("switch", "-q", "feature")
        _ = try await repo.rebase(onto: "main")

        _ = try await repo.abortOperation(.rebase)

        XCTAssertNil(repo.state().operation)
        let branch = await repo.currentBranch()
        XCTAssertEqual(branch, "feature")
        XCTAssertEqual(try read("a.txt"), "feature\n")
    }

    func testACleanRebaseCompletes() async throws {
        try await commit("a.txt", "base\n", "base")
        try await git("switch", "-q", "-c", "feature")
        try await commit("b.txt", "b\n", "feature work")
        try await git("switch", "-q", "main")
        try await commit("c.txt", "c\n", "main work")
        try await git("switch", "-q", "feature")

        let result = try await repo.rebase(onto: "main")

        XCTAssertFalse(result.isStopped)
        let log = try await repo.log(scope: .head)
        XCTAssertEqual(log.map(\.subject), ["feature work", "main work", "base"])
    }

    func testTheErrorOfAFailedConflictIsReadableFromStdout() {
        let error = GitError.failed(status: 1, stderr: "", stdout: Data("CONFLICT (content): Merge conflict in a.txt\n".utf8))
        XCTAssertEqual(error.errorDescription, "CONFLICT (content): Merge conflict in a.txt")
    }
}
