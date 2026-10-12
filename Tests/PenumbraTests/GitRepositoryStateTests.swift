import XCTest
@testable import GitIntelligence

/// `GitRepositoryState` reads the `.git` directory without a process. These tests produce each
/// state with real git, then assert what the reader sees.
final class GitRepositoryStateTests: XCTestCase {
    private var directory: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-state-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Tester"], ["config", "user.email", "t@example.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func git(_ args: String...) async throws {
        _ = try await runner.run(args, in: directory)
    }

    /// Runs git expecting it to fail (a conflict), and returns normally either way.
    private func gitAllowingFailure(_ args: String...) async {
        _ = try? await runner.run(args, in: directory)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func commit(_ name: String, _ text: String, _ message: String) async throws {
        try write(name, text)
        try await git("add", name)
        try await git("commit", "-q", "-m", message)
    }

    /// `main` and `feature` both change a.txt from the same base.
    private func makeDivergedBranches() async throws {
        try await commit("a.txt", "base\n", "base")
        try await git("switch", "-q", "-c", "feature")
        try await commit("a.txt", "feature\n", "feature change")
        try await git("switch", "-q", "main")
        try await commit("a.txt", "main\n", "main change")
    }

    private func repository() async throws -> GitRepository {
        let found = await GitRepository.discover(from: directory)
        return try XCTUnwrap(found)
    }

    func testDiscoverFindsTheGitDirectory() async throws {
        let repo = try await repository()
        XCTAssertEqual(repo.gitDirectory.resolvingSymlinksInPath().path, directory.appendingPathComponent(".git").path)
    }

    func testCleanRepositoryHasABranchAndNoOperation() async throws {
        try await commit("a.txt", "1\n", "first")
        let state = try await repository().state()
        XCTAssertEqual(state.head, .branch("main"))
        XCTAssertNil(state.operation)
        XCTAssertFalse(state.isDetached)
    }

    func testDetachedHeadIsReportedWithItsCommit() async throws {
        try await commit("a.txt", "1\n", "first")
        try await git("checkout", "-q", "--detach")
        let state = try await repository().state()
        guard case .detached(let sha) = state.head else { return XCTFail("expected a detached head, got \(state.head)") }
        XCTAssertEqual(sha.count, 40)
        XCTAssertTrue(state.isDetached)
        XCTAssertNil(state.branchName)
    }

    func testAConflictedMergeIsAMergeWithItsMessageAndHead() async throws {
        try await makeDivergedBranches()
        await gitAllowingFailure("merge", "feature")

        let state = try await repository().state()

        let operation = try XCTUnwrap(state.operation)
        XCTAssertEqual(operation.kind, .merge)
        XCTAssertEqual(operation.heads.count, 1)
        XCTAssertEqual(operation.heads[0].count, 40)
        XCTAssertTrue(operation.message?.hasPrefix("Merge branch 'feature'") == true, operation.message ?? "nil")
        XCTAssertEqual(state.head, .branch("main"))
    }

    func testAStoppedRebaseReportsStepTotalOntoAndBranch() async throws {
        try await makeDivergedBranches()
        try await git("switch", "-q", "feature")
        await gitAllowingFailure("rebase", "main")

        let state = try await repository().state()

        let operation = try XCTUnwrap(state.operation)
        XCTAssertEqual(operation.kind, .rebase)
        XCTAssertEqual(operation.step, 1)
        XCTAssertEqual(operation.total, 1)
        XCTAssertEqual(operation.branch, "feature")
        XCTAssertEqual(operation.onto?.count, 40)
        XCTAssertTrue(state.isDetached, "git detaches HEAD while it replays commits")
    }

    func testAConflictedCherryPickNamesTheCommit() async throws {
        try await makeDivergedBranches()
        await gitAllowingFailure("cherry-pick", "feature")

        let state = try await repository().state()

        let operation = try XCTUnwrap(state.operation)
        XCTAssertEqual(operation.kind, .cherryPick)
        XCTAssertEqual(operation.heads.count, 1)
    }

    func testAConflictedRevertIsARevert() async throws {
        try await commit("a.txt", "one\n", "one")
        try await commit("a.txt", "two\n", "two")
        try await commit("a.txt", "three\n", "three")
        await gitAllowingFailure("revert", "HEAD~1", "--no-edit")

        let state = try await repository().state()

        XCTAssertEqual(state.operation?.kind, .revert)
    }

    func testFinishingTheOperationClearsTheState() async throws {
        try await makeDivergedBranches()
        await gitAllowingFailure("merge", "feature")
        try await git("merge", "--abort")

        let state = try await repository().state()

        XCTAssertNil(state.operation)
    }

    func testALinkedWorktreeReadsItsOwnHeadAndOperation() async throws {
        try await makeDivergedBranches()
        let linked = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-state-wt-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: linked) }
        try await git("worktree", "add", "-q", linked.path, "feature")
        _ = try? await runner.run(["merge", "main"], in: linked)

        let discovered = await GitRepository.discover(from: linked)
        let repo = try XCTUnwrap(discovered)

        XCTAssertTrue(repo.gitDirectory.path.contains("/worktrees/"), repo.gitDirectory.path)
        XCTAssertEqual(repo.state().head, .branch("feature"))
        XCTAssertEqual(repo.state().operation?.kind, .merge)
        // The main work tree is untouched.
        let main = try await repository().state()
        XCTAssertEqual(main.head, .branch("main"))
        XCTAssertNil(main.operation)
    }

    func testAMissingGitDirectoryIsUnknownNotACrash() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")
        let state = GitRepositoryState.read(gitDirectory: missing)
        XCTAssertEqual(state.head, .unknown)
        XCTAssertNil(state.operation)
    }
}
