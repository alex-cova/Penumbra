import XCTest
@testable import GitIntelligence

/// Fetch, pull, push, branches, tags, config, compare and the smart-operation wrapper, against
/// real git with a local bare repository as the remote (no network).
final class GitRemoteIntegrationTests: XCTestCase {
    private var directory: URL!
    private var remote: URL!
    private var repo: GitRepository!
    private let runner = SystemGitRunner()
    private var scratch: [URL] = []

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = try makeDirectory("git-remote")
        remote = try makeDirectory("git-bare")
        _ = try await runner.run(["init", "-q", "--bare", "-b", "main", remote.path], in: directory)
        try await configure(directory, init: true)
        _ = try await runner.run(["remote", "add", "origin", remote.path], in: directory)
        let found = await GitRepository.discover(from: directory)
        repo = try XCTUnwrap(found)
    }

    override func tearDown() async throws {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Helpers

    private func makeDirectory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        scratch.append(url)
        return url
    }

    private func configure(_ url: URL, init initialize: Bool = false) async throws {
        if initialize { _ = try await runner.run(["init", "-q", "-b", "main"], in: url) }
        for args in [["config", "user.name", "Tester"], ["config", "user.email", "t@example.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: url)
        }
    }

    private func git(_ args: [String], in url: URL? = nil) async throws {
        _ = try await runner.run(args, in: url ?? directory)
    }

    private func write(_ name: String, _ text: String, in url: URL? = nil) throws {
        try text.write(to: (url ?? directory).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String, in url: URL? = nil) throws -> String {
        try String(contentsOf: (url ?? directory).appendingPathComponent(name), encoding: .utf8)
    }

    @discardableResult
    private func commit(_ name: String, _ text: String, _ message: String, in url: URL? = nil) async throws -> String {
        let root = url ?? directory!
        try write(name, text, in: root)
        try await git(["add", name], in: root)
        try await git(["commit", "-q", "-m", message], in: root)
        let out = try await runner.run(["rev-parse", "HEAD"], in: root)
        return out.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pushes `main` once so the remote has history, and returns a second clone to act as a teammate.
    private func publishAndClone() async throws -> (clone: URL, cloned: GitRepository) {
        try await commit("a.txt", "base\n", "base")
        try await repo.push(GitPushOptions(remote: "origin", source: "main", targetBranch: "main", setUpstream: true))
        let clone = try makeDirectory("git-clone")
        try FileManager.default.removeItem(at: clone)
        _ = try await runner.run(["clone", "-q", remote.path, clone.path], in: directory)
        try await configure(clone)
        return (clone, GitRepository(root: clone, runner: runner))
    }

    private func currentBranch() async -> String? { await repo.currentBranch() }

    // MARK: - Remotes and the branch list

    func testRemoteDetailsListsFetchAndPushUrls() async throws {
        let remotes = await repo.remoteDetails()
        XCTAssertEqual(remotes, [GitRemote(name: "origin", fetchURL: remote.path, pushURL: remote.path)])
    }

    func testBranchListHasUpstreamAheadBehindAndCurrent() async throws {
        let (clone, cloned) = try await publishAndClone()
        try await commit("b.txt", "b\n", "teammate", in: clone)
        try await cloned.push(GitPushOptions())
        try await commit("a.txt", "mine\n", "local")
        try await repo.fetch()

        let branches = try await repo.branchList()

        let main = try XCTUnwrap(branches.first { $0.id == "heads/main" })
        XCTAssertTrue(main.isCurrent)
        XCTAssertEqual(main.upstream, "origin/main")
        XCTAssertEqual(main.ahead, 1)
        XCTAssertEqual(main.behind, 1)
        let tracking = try XCTUnwrap(branches.first { $0.id == "remotes/origin/main" })
        XCTAssertEqual(tracking.remoteName, "origin")
        XCTAssertEqual(tracking.shortName, "main")
        XCTAssertFalse(branches.contains { $0.name.hasSuffix("/HEAD") })
    }

    func testFetchPrunesBranchesDeletedOnTheRemoteAndMarksTheUpstreamGone() async throws {
        let (clone, cloned) = try await publishAndClone()
        try await git(["switch", "-q", "-c", "topic"], in: clone)
        try await commit("t.txt", "t\n", "topic", in: clone)
        try await cloned.push(GitPushOptions(remote: "origin", source: "topic", setUpstream: true))
        try await repo.fetch()
        _ = try await repo.checkoutRemoteBranch("origin/topic")
        let tracking = try await repo.branchList().first { $0.name == "topic" }
        XCTAssertEqual(tracking?.upstream, "origin/topic")
        try await git(["switch", "-q", "main"])

        _ = try await cloned.deleteRemoteBranch(remote: "origin", branch: "topic")
        try await repo.fetch(prune: true)

        let after = try await repo.branchList()
        XCTAssertNil(after.first { $0.id == "remotes/origin/topic" })
        XCTAssertEqual(after.first { $0.name == "topic" }?.upstreamIsGone, true)
    }

    // MARK: - Pull

    func testPullMergeCreatesAMergeCommitWhenBranchesDiverged() async throws {
        let (clone, cloned) = try await publishAndClone()
        try await commit("remote.txt", "r\n", "remote work", in: clone)
        try await cloned.push(GitPushOptions())
        try await commit("local.txt", "l\n", "local work")

        _ = try await repo.pull(strategy: .merge)

        let log = try await repo.log(scope: .head)
        XCTAssertTrue(log.first?.isMerge == true)
        XCTAssertEqual(try read("remote.txt"), "r\n")
        XCTAssertEqual(try read("local.txt"), "l\n")
    }

    func testPullRebaseKeepsHistoryLinear() async throws {
        let (clone, cloned) = try await publishAndClone()
        try await commit("remote.txt", "r\n", "remote work", in: clone)
        try await cloned.push(GitPushOptions())
        try await commit("local.txt", "l\n", "local work")

        _ = try await repo.pull(strategy: .rebase)

        let log = try await repo.log(scope: .head)
        XCTAssertEqual(log.map(\.subject), ["local work", "remote work", "base"])
        XCTAssertFalse(log.contains(where: \.isMerge))
    }

    func testPullFastForwardOnlyRefusesDivergedHistory() async throws {
        let (clone, cloned) = try await publishAndClone()
        try await commit("remote.txt", "r\n", "remote work", in: clone)
        try await cloned.push(GitPushOptions())
        try await commit("local.txt", "l\n", "local work")

        do {
            _ = try await repo.pull(strategy: .fastForwardOnly)
            XCTFail("a diverged fast-forward-only pull must fail")
        } catch {
            XCTAssertTrue(error is GitError)
        }
        let log = try await repo.log(scope: .head)
        XCTAssertEqual(log.count, 2)
    }

    func testPullWithAutostashKeepsUncommittedChanges() async throws {
        let (clone, cloned) = try await publishAndClone()
        try await commit("remote.txt", "r\n", "remote work", in: clone)
        try await cloned.push(GitPushOptions())
        try await commit("local.txt", "l\n", "local work")
        try write("a.txt", "dirty\n")

        _ = try await repo.pull(strategy: .rebase, autostash: true)

        XCTAssertEqual(try read("a.txt"), "dirty\n")
        XCTAssertEqual(try read("remote.txt"), "r\n")
    }

    // MARK: - Push

    func testPushSetsUpstreamAndTargetsAnotherBranchName() async throws {
        try await commit("a.txt", "1\n", "one")

        _ = try await repo.push(GitPushOptions(remote: "origin", source: "HEAD", targetBranch: "release", setUpstream: false))

        let heads = try await runner.run(["--git-dir", remote.path, "branch", "--list"], in: directory)
        XCTAssertTrue(heads.text.contains("release"), heads.text)
    }

    func testForceWithLeaseRefusesWhenTheRemoteMovedAndAcceptsAfterFetch() async throws {
        let (clone, cloned) = try await publishAndClone()
        // The teammate adds a commit; we rewrite ours without having fetched it.
        try await commit("t.txt", "t\n", "teammate", in: clone)
        try await cloned.push(GitPushOptions())
        try await git(["commit", "-q", "--amend", "-m", "base, rewritten"])
        try await repo.fetch(remote: "origin", prune: false)
        // The lease is against the ref we just fetched, so a forced push would erase "teammate":
        // a plain push is refused, and force-with-lease is accepted only for what we last saw.
        do {
            _ = try await repo.push(GitPushOptions())
            XCTFail("a non-fast-forward push must be refused")
        } catch {
            XCTAssertTrue(error is GitError)
        }

        _ = try await repo.push(GitPushOptions(forceWithLease: true))
        let tip = try await runner.run(["--git-dir", remote.path, "log", "-1", "--format=%s", "main"], in: directory)
        XCTAssertEqual(tip.text.trimmingCharacters(in: .whitespacesAndNewlines), "base, rewritten")
    }

    func testForceWithLeaseIsRefusedWhenTheRemoteMovedSinceTheLastFetch() async throws {
        let (clone, cloned) = try await publishAndClone()
        try await git(["commit", "-q", "--amend", "-m", "rewritten"])
        try await commit("t.txt", "t\n", "teammate", in: clone)
        try await cloned.push(GitPushOptions())

        do {
            _ = try await repo.push(GitPushOptions(forceWithLease: true))
            XCTFail("the lease must refuse a remote we have not fetched")
        } catch {
            XCTAssertTrue(error is GitError)
        }
        let tip = try await runner.run(["--git-dir", remote.path, "log", "-1", "--format=%s", "main"], in: directory)
        XCTAssertEqual(tip.text.trimmingCharacters(in: .whitespacesAndNewlines), "teammate")
    }

    func testPushFollowTagsSendsAnAnnotatedTag() async throws {
        let (_, _) = try await publishAndClone()
        try await repo.createTag("v1", message: "release 1")
        try await commit("a.txt", "2\n", "two")

        _ = try await repo.push(GitPushOptions(tags: .following))

        let tags = try await runner.run(["--git-dir", remote.path, "tag", "--list"], in: directory)
        XCTAssertTrue(tags.text.contains("v1"))
    }

    func testPushRejectsAnOptionLookingRemoteOrBranch() async throws {
        try await commit("a.txt", "1\n", "one")
        for options in [GitPushOptions(remote: "--mirror"), GitPushOptions(remote: "origin", targetBranch: "-f")] {
            do {
                _ = try await repo.push(options)
                XCTFail("must not reach git")
            } catch {
                XCTAssertTrue(error is GitError)
            }
        }
    }

    // MARK: - Branch operations

    func testRenameDeleteAndCreateAtAStartPoint() async throws {
        let first = try await commit("a.txt", "1\n", "one")
        try await commit("a.txt", "2\n", "two")

        _ = try await repo.createBranch("old", startPoint: first, checkout: false)
        _ = try await repo.renameBranch("old", to: "new")
        var names = try await repo.branchList().map(\.name)
        XCTAssertTrue(names.contains("new"))
        XCTAssertFalse(names.contains("old"))
        let current = await currentBranch()
        XCTAssertEqual(current, "main", "checkout: false must stay on the branch")

        _ = try await repo.deleteBranch("new")
        names = try await repo.branchList().map(\.name)
        XCTAssertFalse(names.contains("new"))
    }

    func testDeleteOfAnUnmergedBranchNeedsForce() async throws {
        try await commit("a.txt", "1\n", "one")
        _ = try await repo.createBranch("topic")
        try await commit("a.txt", "topic\n", "topic work")
        _ = try await repo.switchBranch("main")

        do {
            _ = try await repo.deleteBranch("topic")
            XCTFail("an unmerged branch needs -D")
        } catch {
            XCTAssertTrue(error is GitError)
        }
        _ = try await repo.deleteBranch("topic", force: true)
    }

    func testCheckoutRemoteBranchTracksIt() async throws {
        let (clone, cloned) = try await publishAndClone()
        try await git(["switch", "-q", "-c", "feature/x"], in: clone)
        try await commit("f.txt", "f\n", "feature", in: clone)
        try await cloned.push(GitPushOptions(remote: "origin", source: "feature/x", setUpstream: true))
        try await repo.fetch()

        _ = try await repo.checkoutRemoteBranch("origin/feature/x")

        let current = await currentBranch()
        XCTAssertEqual(current, "feature/x")
        XCTAssertEqual(try read("f.txt"), "f\n")
        let branch = try await repo.branchList().first { $0.name == "feature/x" }
        XCTAssertEqual(branch?.upstream, "origin/feature/x")
    }

    func testCheckoutRevisionDetachesHead() async throws {
        let first = try await commit("a.txt", "1\n", "one")
        try await commit("a.txt", "2\n", "two")

        _ = try await repo.checkout(revision: first)

        XCTAssertTrue(repo.state().isDetached)
        XCTAssertEqual(try read("a.txt"), "1\n")
    }

    func testMergedBranchesListsOnlyWhatIsInTheBase() async throws {
        try await commit("a.txt", "1\n", "one")
        _ = try await repo.createBranch("done", startPoint: nil, checkout: false)
        _ = try await repo.createBranch("wip")
        try await commit("a.txt", "wip\n", "wip work")
        _ = try await repo.switchBranch("main")

        let merged = try await repo.mergedBranches(into: "main")

        XCTAssertEqual(merged, ["done"])
    }

    func testDefaultBranchNameFallsBackToMain() async throws {
        try await commit("a.txt", "1\n", "one")
        let name = await repo.defaultBranchName()
        XCTAssertEqual(name, "main")
    }

    // MARK: - Tags, config, compare

    func testTagsRoundTrip() async throws {
        let first = try await commit("a.txt", "1\n", "one")
        try await commit("a.txt", "2\n", "two")
        try await repo.createTag("light", at: first)
        try await repo.createTag("v1", message: "the first release")

        let tags = try await repo.tags()
        XCTAssertEqual(Set(tags.map(\.name)), ["light", "v1"])
        let annotated = try XCTUnwrap(tags.first { $0.name == "v1" })
        XCTAssertTrue(annotated.isAnnotated)
        XCTAssertEqual(annotated.subject, "the first release")
        let lightweight = try XCTUnwrap(tags.first { $0.name == "light" })
        XCTAssertFalse(lightweight.isAnnotated)
        XCTAssertEqual(lightweight.commit, first)

        _ = try await repo.pushTag("v1")
        let remoteTags = try await runner.run(["--git-dir", remote.path, "tag", "--list"], in: directory)
        XCTAssertEqual(remoteTags.text.trimmingCharacters(in: .whitespacesAndNewlines), "v1")

        try await repo.deleteTag("light")
        let left = try await repo.tags().map(\.name)
        XCTAssertEqual(left, ["v1"])
    }

    func testConfigGetAndSet() async throws {
        let missing = await repo.config("umbra.test")
        XCTAssertNil(missing)
        try await repo.setConfig("umbra.test", to: "yes")
        let value = await repo.config("umbra.test")
        XCTAssertEqual(value, "yes")
        let name = await repo.config("user.name")
        XCTAssertEqual(name, "Tester")
    }

    func testCompareListsCommitsOnEachSideAndTheDifferingFiles() async throws {
        try await commit("a.txt", "base\n", "base")
        _ = try await repo.createBranch("feature")
        try await commit("f.txt", "f\n", "feature work")
        _ = try await repo.switchBranch("main")
        try await commit("m.txt", "m\n", "main work")

        let result = try await repo.compare("main", "feature")

        XCTAssertEqual(result.onlyInLeft.map(\.subject), ["main work"])
        XCTAssertEqual(result.onlyInRight.map(\.subject), ["feature work"])
        XCTAssertEqual(Set(result.files.map(\.path)), ["f.txt", "m.txt"])
        XCTAssertEqual(result.files.first { $0.path == "f.txt" }?.status, "A")
        XCTAssertEqual(result.files.first { $0.path == "m.txt" }?.status, "D")
    }

    // MARK: - Smart operations

    func testSwitchFailureNamesTheFilesThatWouldBeOverwritten() async throws {
        try await commit("a.txt", "main\n", "one")
        _ = try await repo.createBranch("feature")
        try await commit("a.txt", "feature\n", "feature")
        _ = try await repo.switchBranch("main")
        try write("a.txt", "dirty\n")

        do {
            _ = try await repo.switchBranch("feature")
            XCTFail("switch must refuse")
        } catch GitError.failed(_, let stderr, _) {
            XCTAssertEqual(GitSwitchConflictParser.parse(stderr), ["a.txt"])
        }
    }

    func testSmartCheckoutCarriesLocalChangesToTheOtherBranch() async throws {
        try await commit("a.txt", "main\nsep\nline3\n", "one")
        _ = try await repo.createBranch("feature")
        try await commit("a.txt", "feature\nsep\nline3\n", "feature")
        _ = try await repo.switchBranch("main")
        // A change a line away from the one the branches disagree about: git merges it cleanly.
        try write("a.txt", "main\nsep\nline3 edited\n")
        try write("new.txt", "untracked\n")

        let (_, outcome) = try await repo.preservingLocalChanges { [repo] in
            try await repo!.switchBranch("feature")
        }

        XCTAssertEqual(outcome, .completed)
        let current = await currentBranch()
        XCTAssertEqual(current, "feature")
        XCTAssertEqual(try read("a.txt"), "feature\nsep\nline3 edited\n")
        XCTAssertEqual(try read("new.txt"), "untracked\n")
        let top = await repo.stashTopForTests()
        XCTAssertNil(top, "the stash is popped")
    }

    func testSmartCheckoutThatConflictsKeepsTheStash() async throws {
        try await commit("a.txt", "main\n", "one")
        _ = try await repo.createBranch("feature")
        try await commit("a.txt", "feature\n", "feature")
        _ = try await repo.switchBranch("main")
        try write("a.txt", "dirty\n")

        let (_, outcome) = try await repo.preservingLocalChanges { [repo] in
            try await repo!.switchBranch("feature")
        }

        XCTAssertEqual(outcome, .restoredWithConflicts)
        let current = await currentBranch()
        XCTAssertEqual(current, "feature")
        let top = await repo.stashTopForTests()
        XCTAssertNotNil(top, "git keeps the stash when the pop conflicts")
    }

    func testAFailedOperationRestoresTheChangesBeforeRethrowing() async throws {
        try await commit("a.txt", "1\n", "one")
        try write("a.txt", "dirty\n")
        try write("new.txt", "untracked\n")

        do {
            _ = try await repo.preservingLocalChanges { [repo] in
                try await repo!.switchBranch("no-such-branch")
            }
            XCTFail("the operation fails")
        } catch {
            XCTAssertTrue(error is GitError)
        }

        XCTAssertEqual(try read("a.txt"), "dirty\n")
        XCTAssertEqual(try read("new.txt"), "untracked\n")
        let top = await repo.stashTopForTests()
        XCTAssertNil(top)
    }

    func testACleanTreeNeedsNoStash() async throws {
        try await commit("a.txt", "1\n", "one")
        _ = try await repo.createBranch("other", startPoint: nil, checkout: false)

        let (_, outcome) = try await repo.preservingLocalChanges { [repo] in
            try await repo!.switchBranch("other")
        }

        XCTAssertEqual(outcome, .completed)
        let current = await currentBranch()
        XCTAssertEqual(current, "other")
    }
}

extension GitRepository {
    /// `stashTop` is internal; tests reach it through `@testable`.
    fileprivate func stashTopForTests() async -> String? { await stashTop() }
}
