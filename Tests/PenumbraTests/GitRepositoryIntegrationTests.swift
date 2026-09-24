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
}
