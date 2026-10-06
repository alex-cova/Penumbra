import XCTest
@testable import GitIntelligence

final class GitRepositoryIntegrationTests: XCTestCase {
    private var directory: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-it-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Tester"], ["config", "user.email", "t@example.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeRepo() async throws -> GitRepository {
        let found = await GitRepository.discover(from: directory)
        return try XCTUnwrap(found)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testCommitLogAndBlameWithUnsavedContents() async throws {
        let repo = try await makeRepo()
        try write("a.txt", "one\ntwo\n")
        _ = try await repo.commit(message: "first", paths: [], untrackedPaths: ["a.txt"], amend: false)

        let log = try await repo.log(scope: .all)
        XCTAssertEqual(log.map(\.subject), ["first"])
        let branch = await repo.currentBranch()
        XCTAssertEqual(branch, "main")

        let blame = try await repo.blame(relativePath: "a.txt", contents: Data("one\ntwo\nthree\n".utf8))
        XCTAssertEqual(blame.count, 3)
        XCTAssertFalse(blame[0].isUncommitted)
        XCTAssertEqual(blame[0].summary, "first")
        XCTAssertTrue(blame[2].isUncommitted)
    }

    func testCommitOnlyLeavesOtherChangesUncommitted() async throws {
        let repo = try await makeRepo()
        try write("a.txt", "a\n")
        try write("b.txt", "b\n")
        _ = try await repo.commit(message: "base", paths: [], untrackedPaths: ["a.txt", "b.txt"], amend: false)

        try write("a.txt", "a2\n")
        try write("b.txt", "b2\n")
        try write("c.txt", "c\n")
        _ = try await repo.commit(message: "partial", paths: ["a.txt", "c.txt"], untrackedPaths: ["c.txt"], amend: false)

        let status = try await repo.status()
        XCTAssertEqual(status.map(\.path), ["b.txt"])

        let head = try await repo.log(scope: .head).first?.hash
        let changes = try await repo.commitChanges(hash: try XCTUnwrap(head))
        XCTAssertEqual(Set(changes.map(\.path)), ["a.txt", "c.txt"])
    }

    func testUntrackedDiffReturnsContents() async throws {
        let repo = try await makeRepo()
        try write("seed.txt", "s\n")
        _ = try await repo.commit(message: "seed", paths: [], untrackedPaths: ["seed.txt"], amend: false)
        try write("new.txt", "hello\n")
        let diff = try await repo.workingTreeDiff(path: "new.txt", isUntracked: true)
        XCTAssertTrue(diff.contains("+hello"))
    }

    func testStageDiffShowAndAuthors() async throws {
        let repo = try await makeRepo()
        try write("a.txt", "one\n")
        _ = try await repo.commit(message: "base", paths: [], untrackedPaths: ["a.txt"], amend: false)
        try write("a.txt", "one\ntwo\n")
        try write("ignored.txt", "secret\n")
        try "ignored.txt\n".write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

        let ignored = try await repo.status(includingIgnored: true)
        XCTAssertTrue(ignored.contains { $0.path == "ignored.txt" && $0.isIgnored })

        try await repo.stage(paths: ["a.txt"])
        let staged = try await repo.stagedDiff(path: "a.txt")
        XCTAssertTrue(staged.contains("+two"))
        let unstaged = try await repo.unstagedDiff(path: "a.txt")
        XCTAssertFalse(unstaged.contains("+two"))

        try await repo.unstage(paths: ["a.txt"])
        let after = try await repo.status()
        XCTAssertTrue(after.contains { $0.path == "a.txt" })
        XCTAssertFalse(after.contains { $0.isIgnored })

        let shown = try await repo.show(hash: "HEAD")
        XCTAssertTrue(shown.contains("base"))
        let authors = try await repo.authors()
        XCTAssertEqual(authors, ["Tester"])
        let filtered = try await repo.log(author: "Nobody")
        XCTAssertTrue(filtered.isEmpty)
    }

    func testVisibleFilesHonorsGitignoreAndStaysInsideANestedProject() async throws {
        let app = directory.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "keep\n".write(to: app.appendingPathComponent("src/Keep.txt"), atomically: true, encoding: .utf8)
        try "skip\n".write(to: app.appendingPathComponent("src/Skip.txt"), atomically: true, encoding: .utf8)
        try "Skip.txt\n".write(to: app.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "fresh\n".write(to: app.appendingPathComponent("src/Fresh.txt"), atomically: true, encoding: .utf8)
        try "sibling\n".write(to: directory.appendingPathComponent("sibling.txt"), atomically: true, encoding: .utf8)
        try "logged\n".write(to: app.appendingPathComponent("tracked.log"), atomically: true, encoding: .utf8)
        let repo = try await makeRepo()
        _ = try await repo.commit(
            message: "base",
            paths: [],
            untrackedPaths: ["app/src/Keep.txt", "app/.gitignore", "sibling.txt", "app/tracked.log"],
            amend: false
        )
        // A tracked file stays visible after a later ignore rule. A new match of that rule does not.
        // The working tree's ignore file is what `ls-files` reads, so Skip.txt has to stay in it.
        try "Skip.txt\n*.log\n".write(to: app.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "other\n".write(to: app.appendingPathComponent("other.log"), atomically: true, encoding: .utf8)

        let paths = await GitRepository.visibleFiles(under: app)
        XCTAssertEqual(
            Set(paths ?? []),
            ["src/Keep.txt", "src/Fresh.txt", ".gitignore", "tracked.log"]
        )
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let missing = await GitRepository.visibleFiles(under: outside)
        XCTAssertNil(missing)
    }

    func testPushWithoutRemoteFailsQuickly() async throws {
        let repo = try await makeRepo()
        try write("a.txt", "a\n")
        _ = try await repo.commit(message: "x", paths: [], untrackedPaths: ["a.txt"], amend: false)
        do {
            _ = try await repo.push()
            XCTFail("push without a remote should fail")
        } catch {
            XCTAssertTrue(error is GitError)
        }
    }

    func testSwitchBranchFollowsFileContentsAndRefusesOverwrite() async throws {
        let repo = try await makeRepo()
        try write("a.txt", "main\n")
        _ = try await repo.commit(message: "base", paths: [], untrackedPaths: ["a.txt"], amend: false)

        _ = try await repo.createBranch("feature")
        let created = await repo.currentBranch()
        XCTAssertEqual(created, "feature")
        try write("a.txt", "feature\n")
        _ = try await repo.commit(message: "feature", paths: ["a.txt"], untrackedPaths: [], amend: false)

        _ = try await repo.switchBranch("main")
        let switched = await repo.currentBranch()
        XCTAssertEqual(switched, "main")
        XCTAssertEqual(try read("a.txt"), "main\n")

        try write("a.txt", "dirty\n")
        do {
            _ = try await repo.switchBranch("feature")
            XCTFail("switch should refuse to overwrite local changes")
        } catch {
            XCTAssertTrue(error is GitError)
        }
        let stayed = await repo.currentBranch()
        XCTAssertEqual(stayed, "main")
        XCTAssertEqual(try read("a.txt"), "dirty\n")
    }

    func testCreateBranchRejectsALeadingDash() async throws {
        let repo = try await makeRepo()
        try write("a.txt", "a\n")
        _ = try await repo.commit(message: "base", paths: [], untrackedPaths: ["a.txt"], amend: false)
        do {
            _ = try await repo.createBranch("-evil")
            XCTFail("a branch name must not become a git option")
        } catch {
            XCTAssertTrue(error is GitError)
        }
        let names = try await repo.branches().map(\.name)
        XCTAssertFalse(names.contains("-evil"))
        let branch = await repo.currentBranch()
        XCTAssertEqual(branch, "main")
    }

    func testPushSetsUpstreamAndPullFastForwards() async throws {
        let repo = try await makeRepo()
        try write("a.txt", "one\n")
        _ = try await repo.commit(message: "base", paths: [], untrackedPaths: ["a.txt"], amend: false)
        let remote = try await makeBareRemote()
        defer { try? FileManager.default.removeItem(at: remote) }
        _ = try await runner.run(["remote", "add", "origin", remote.path], in: directory)

        _ = try await repo.push()
        let upstream = try await runner.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: directory)
        XCTAssertEqual(upstream.text.trimmingCharacters(in: .whitespacesAndNewlines), "origin/main")

        let clone = try await cloneRemote(remote)
        defer { try? FileManager.default.removeItem(at: clone) }
        try write("a.txt", "two\n")
        _ = try await repo.commit(message: "second", paths: ["a.txt"], untrackedPaths: [], amend: false)
        _ = try await repo.push()

        let cloned = GitRepository(root: clone, runner: runner)
        _ = try await cloned.pull()
        XCTAssertEqual(try read("a.txt", in: clone), "two\n")
    }

    func testPullRefusesDivergedHistoryWithoutMerging() async throws {
        let repo = try await makeRepo()
        try write("a.txt", "one\n")
        _ = try await repo.commit(message: "base", paths: [], untrackedPaths: ["a.txt"], amend: false)
        let remote = try await makeBareRemote()
        defer { try? FileManager.default.removeItem(at: remote) }
        _ = try await runner.run(["remote", "add", "origin", remote.path], in: directory)
        _ = try await repo.push()

        let clone = try await cloneRemote(remote)
        defer { try? FileManager.default.removeItem(at: clone) }
        try await configureIdentity(in: clone)
        let cloned = GitRepository(root: clone, runner: runner)

        try write("a.txt", "origin\n")
        _ = try await repo.commit(message: "origin", paths: ["a.txt"], untrackedPaths: [], amend: false)
        _ = try await repo.push()

        try write("a.txt", "clone\n", in: clone)
        _ = try await cloned.commit(message: "clone", paths: ["a.txt"], untrackedPaths: [], amend: false)
        do {
            _ = try await cloned.pull()
            XCTFail("a diverged pull must not merge")
        } catch {
            XCTAssertTrue(error is GitError)
        }
        let log = try await cloned.log(scope: .head)
        XCTAssertEqual(log.count, 2)
        XCTAssertFalse(log.contains(where: \.isMerge))
        XCTAssertEqual(try read("a.txt", in: clone), "clone\n")
    }

    private func read(_ name: String, in directory: URL? = nil) throws -> String {
        let root = directory ?? self.directory!
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    private func write(_ name: String, _ text: String, in directory: URL) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func configureIdentity(in directory: URL) async throws {
        for args in [["config", "user.name", "Tester"], ["config", "user.email", "t@example.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
    }

    private func makeBareRemote() async throws -> URL {
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-remote-\(UUID().uuidString)", isDirectory: true)
        _ = try await runner.run(["init", "-q", "--bare", "-b", "main", remote.path], in: directory)
        return remote
    }

    private func cloneRemote(_ remote: URL) async throws -> URL {
        let clone = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-clone-\(UUID().uuidString)", isDirectory: true)
        _ = try await runner.run(["clone", "-q", remote.path, clone.path], in: directory)
        return clone
    }

    // MARK: - File history and revert

    private func commitFile(_ name: String, _ text: String, message: String, _ repo: GitRepository) async throws {
        try write(name, text)
        _ = try await repo.commit(message: message, paths: [name], untrackedPaths: [name], amend: false)
    }

    func testLogOfAFileListsOnlyTheCommitsThatTouchedIt() async throws {
        let repo = try await makeRepo()
        try await commitFile("a.txt", "1\n", message: "add a", repo)
        try await commitFile("b.txt", "1\n", message: "add b", repo)
        try await commitFile("a.txt", "2\n", message: "change a", repo)

        let history = try await repo.log(scope: .head, path: "a.txt")

        XCTAssertEqual(history.map(\.subject), ["change a", "add a"])
        let everything = try await repo.log(scope: .head)
        XCTAssertEqual(everything.map(\.subject), ["change a", "add b", "add a"])
    }

    func testLogOfAFileFollowsARename() async throws {
        let repo = try await makeRepo()
        try await commitFile("old.txt", "some content\nthat is long enough\nto be recognised\n", message: "add old", repo)
        _ = try await runner.run(["mv", "old.txt", "new.txt"], in: directory)
        _ = try await repo.commit(message: "rename", paths: [], untrackedPaths: [], amend: false)

        let history = try await repo.log(scope: .head, path: "new.txt")

        XCTAssertEqual(history.map(\.subject), ["rename", "add old"], "History continues under the old name")
    }

    func testExistsInHeadTellsCommittedFilesFromNewOnes() async throws {
        let repo = try await makeRepo()
        try await commitFile("a.txt", "1\n", message: "add a", repo)
        try write("new.txt", "n\n")
        _ = try await runner.run(["add", "new.txt"], in: directory)

        let committed = await repo.existsInHead(relativePath: "a.txt")
        let staged = await repo.existsInHead(relativePath: "new.txt")
        let missing = await repo.existsInHead(relativePath: "nope.txt")
        XCTAssertTrue(committed)
        XCTAssertFalse(staged, "A staged new file has nothing in HEAD to go back to")
        XCTAssertFalse(missing)
    }

    func testRevertDiscardsStagedAndUnstagedChanges() async throws {
        let repo = try await makeRepo()
        try await commitFile("a.txt", "original\n", message: "add a", repo)
        try await commitFile("keep.txt", "keep\n", message: "add keep", repo)
        try write("a.txt", "staged edit\n")
        try await repo.stage(paths: ["a.txt"])
        try write("a.txt", "staged edit\nand an unstaged one\n")
        try write("keep.txt", "keep, edited\n")

        try await repo.revertToHead(paths: ["a.txt"])

        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("a.txt"), encoding: .utf8), "original\n")
        let status = try await repo.status()
        XCTAssertEqual(status.map(\.path), ["keep.txt"], "Only the reverted file is clean again")
    }

    func testRevertBringsBackADeletedFile() async throws {
        let repo = try await makeRepo()
        try await commitFile("a.txt", "original\n", message: "add a", repo)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("a.txt"))

        try await repo.revertToHead(paths: ["a.txt"])

        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("a.txt"), encoding: .utf8), "original\n")
    }

    func testRevertOfAFileNeverCommittedFailsAndChangesNothing() async throws {
        let repo = try await makeRepo()
        try await commitFile("a.txt", "1\n", message: "add a", repo)
        try write("new.txt", "mine\n")

        do {
            try await repo.revertToHead(paths: ["new.txt"])
            XCTFail("git should refuse a path with no committed version")
        } catch {
            // expected
        }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("new.txt"), encoding: .utf8), "mine\n")
    }

    // MARK: - Multi-file revert

    func testPathsInHeadSplitsCommittedFromTheRest() async throws {
        let repo = try await makeRepo()
        try await commitFile("a.txt", "1\n", message: "add a", repo)
        try await commitFile("gone.txt", "1\n", message: "add gone", repo)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("gone.txt"))
        try write("staged.txt", "s\n")
        try await repo.stage(paths: ["staged.txt"])
        try write("untracked.txt", "u\n")

        let found = await repo.pathsInHead(["a.txt", "gone.txt", "staged.txt", "untracked.txt", "nope.txt"])

        XCTAssertEqual(found, ["a.txt", "gone.txt"], "A deleted file is still in HEAD; staged-new and untracked are not")
    }

    func testPathsInHeadFollowsRenames() async throws {
        let repo = try await makeRepo()
        try await commitFile("old.txt", "1\n", message: "add old", repo)
        _ = try await runner.run(["mv", "old.txt", "new.txt"], in: directory)

        let found = await repo.pathsInHead(["old.txt", "new.txt"])

        XCTAssertEqual(found, ["old.txt"], "The new name of a staged rename has no committed version")
    }

    func testPathsWithSpacesNonASCIIAndGlobCharactersAreLiteral() async throws {
        let repo = try await makeRepo()
        let names = ["with space.txt", "café ☕.txt", "star*.txt", "q?.txt"]
        for name in names { try await commitFile(name, "1\n", message: "add \(name)", repo) }
        try write("starX.txt", "x\n")
        try await repo.stage(paths: ["starX.txt"])
        for name in names { try write(name, "edited\n") }

        let found = await repo.pathsInHead(names + ["starX.txt"])
        XCTAssertEqual(found, Set(names), "`star*.txt` must not match starX.txt")

        let result = try await repo.revert(paths: names)
        XCTAssertEqual(Set(result.reverted), Set(names))
        for name in names {
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8), "1\n", name)
        }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("starX.txt"), encoding: .utf8), "x\n")
    }

    func testRevertOfAStagedAndUnstagedMixSkipsWhatHasNoCommittedVersion() async throws {
        let repo = try await makeRepo()
        try await commitFile("a.txt", "a\n", message: "add a", repo)
        try await commitFile("b.txt", "b\n", message: "add b", repo)
        try await commitFile("gone.txt", "g\n", message: "add gone", repo)
        try write("a.txt", "a staged\n")
        try await repo.stage(paths: ["a.txt"])
        try write("a.txt", "a staged\nand unstaged\n")
        try write("b.txt", "b edited\n")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("gone.txt"))
        try write("new.txt", "mine\n")
        try await repo.stage(paths: ["new.txt"])
        try write("loose.txt", "loose\n")

        let result = try await repo.revert(paths: ["a.txt", "b.txt", "gone.txt", "new.txt", "loose.txt", "a.txt"])

        XCTAssertEqual(result.reverted, ["a.txt", "b.txt", "gone.txt"], "In request order, without the duplicate")
        XCTAssertEqual(result.skipped, ["new.txt", "loose.txt"])
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("a.txt"), encoding: .utf8), "a\n")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("b.txt"), encoding: .utf8), "b\n")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("gone.txt"), encoding: .utf8), "g\n")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("new.txt"), encoding: .utf8), "mine\n")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("loose.txt"), encoding: .utf8), "loose\n")
        let status = try await repo.status()
        XCTAssertEqual(Set(status.map(\.path)), ["new.txt", "loose.txt"], "The skipped files keep their state")
    }

    func testRevertOfNothingRunsNoGit() async throws {
        let repo = try await makeRepo()
        try await commitFile("a.txt", "1\n", message: "add a", repo)
        let result = try await repo.revert(paths: [])
        XCTAssertEqual(result, GitRevertResult(reverted: [], skipped: []))
    }

    func testRevertHandlesMoreThanOneChunkOfPaths() async throws {
        let repo = try await makeRepo()
        let names = (0..<1000).map { "f\($0).txt" }
        for name in names { try write(name, "1\n") }
        _ = try await repo.commit(message: "many", paths: [], untrackedPaths: names, amend: false)
        for name in names { try write(name, "edited\n") }
        try write("extra.txt", "x\n")

        let result = try await repo.revert(paths: names + ["extra.txt"])

        XCTAssertEqual(result.reverted.count, 1000)
        XCTAssertEqual(result.skipped, ["extra.txt"])
        let status = try await repo.status()
        XCTAssertEqual(status.map(\.path), ["extra.txt"])
    }

    func testSyncStatusCountsCommitsOnEachSideOfTheUpstream() async throws {
        let repo = try await makeRepo()
        try write("a.txt", "a\n")
        _ = try await repo.commit(message: "base", paths: [], untrackedPaths: ["a.txt"], amend: false)
        let noUpstream = await repo.syncStatus()
        XCTAssertNil(noUpstream)

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-sync-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let remote = scratch.appendingPathComponent("remote.git")
        let other = scratch.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        _ = try await runner.run(["init", "-q", "--bare", "-b", "main", remote.path], in: scratch)
        _ = try await runner.run(["remote", "add", "origin", remote.path], in: directory)
        _ = try await runner.run(["push", "-q", "-u", "origin", "main"], in: directory)

        let synced = await repo.syncStatus()
        XCTAssertEqual(synced, GitSyncStatus(upstream: "origin/main", ahead: 0, behind: 0, outgoing: [], incoming: []))

        try write("b.txt", "b\n")
        _ = try await repo.commit(message: "local", paths: [], untrackedPaths: ["b.txt"], amend: false)

        _ = try await runner.run(["clone", "-q", remote.path, other.path], in: scratch)
        for args in [["config", "user.name", "Other"], ["config", "user.email", "o@example.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: other)
        }
        try "c\n".write(to: other.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        for args in [["add", "c.txt"], ["commit", "-q", "-m", "remote"], ["push", "-q"]] {
            _ = try await runner.run(args, in: other)
        }
        _ = try await runner.run(["fetch", "-q"], in: directory)

        let divergedStatus = await repo.syncStatus()
        let diverged = try XCTUnwrap(divergedStatus)
        XCTAssertEqual(diverged.upstream, "origin/main")
        XCTAssertEqual(diverged.ahead, 1)
        XCTAssertEqual(diverged.behind, 1)
        XCTAssertEqual(diverged.outgoing.map(\.subject), ["local"])
        XCTAssertEqual(diverged.incoming.map(\.subject), ["remote"])
    }

    func testFileContentsAtEachRevision() async throws {
        let repo = try await makeRepo()
        try write("a.txt", "one\n")
        _ = try await repo.commit(message: "first", paths: [], untrackedPaths: ["a.txt"], amend: false)
        let log = try await repo.log(scope: .head)
        let first = try XCTUnwrap(log.first?.hash)
        try write("a.txt", "two\n")
        try await repo.stage(paths: ["a.txt"])
        try write("a.txt", "three\n")

        func text(_ revision: GitRevision) async throws -> String? {
            try await repo.fileContents(at: revision, path: "a.txt").map { String(decoding: $0, as: UTF8.self) }
        }
        let head = try await text(.head)
        let index = try await text(.index)
        let commit = try await text(.commit(first))
        let rootParent = try await text(.parent(of: first))
        let branch = try await text(.ref("main"))
        XCTAssertEqual(head, "one\n")
        XCTAssertEqual(index, "two\n")
        XCTAssertEqual(commit, "one\n")
        XCTAssertNil(rootParent)
        XCTAssertEqual(branch, "one\n")
        let missing = try await repo.fileContents(at: .head, path: "nope.txt")
        XCTAssertNil(missing)
    }

    func testApplyPatchStagesAndUnstagesOneHunk() async throws {
        let repo = try await makeRepo()
        try write("a.txt", "1\n2\n3\n4\n5\n6\n7\n8\n")
        _ = try await repo.commit(message: "base", paths: [], untrackedPaths: ["a.txt"], amend: false)
        try write("a.txt", "1\nTWO\n3\n4\n5\n6\nSEVEN\n8\n")
        let patch = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -2 +2 @@
        -2
        +TWO

        """
        try await repo.applyPatch(patch, toIndex: true)
        var staged = try await repo.stagedDiff(path: "a.txt")
        XCTAssertTrue(staged.contains("+TWO"))
        XCTAssertFalse(staged.contains("+SEVEN"))
        let unstaged = try await repo.unstagedDiff(path: "a.txt")
        XCTAssertTrue(unstaged.contains("+SEVEN"))
        XCTAssertFalse(unstaged.contains("+TWO"))

        try await repo.applyPatch(patch, toIndex: true, reverse: true)
        staged = try await repo.stagedDiff(path: "a.txt")
        XCTAssertTrue(staged.isEmpty)
    }
}
