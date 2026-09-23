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
}
