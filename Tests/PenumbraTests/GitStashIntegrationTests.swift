import XCTest
@testable import GitIntelligence

final class GitStashIntegrationTests: XCTestCase {
    private var directory: URL!
    private var repo: GitRepository!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-stash-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Tester"],
                     ["config", "user.email", "t@example.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
        let found = await GitRepository.discover(from: directory)
        repo = try XCTUnwrap(found)
        try write("a.txt", "base\n")
        try write("b.txt", "base\n")
        _ = try await runner.run(["add", "."], in: directory)
        _ = try await runner.run(["commit", "-q", "-m", "base"], in: directory)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func firstStash() async throws -> GitStash {
        let list = try await repo.stashes()
        return try XCTUnwrap(list.first)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    func testParserReadsHashDateAndSubject() {
        let h = String(repeating: "a", count: 40)
        let stashes = GitStashParser.parse("\(h)\u{1f}1700000000\u{1f}On main: my message\n\(h)\u{1f}1600000000\u{1f}WIP on feature: 1a2b3c4 subject\n")
        XCTAssertEqual(stashes.map(\.ref), ["stash@{0}", "stash@{1}"])
        XCTAssertEqual(stashes[0].title, "my message")
        XCTAssertEqual(stashes[0].branch, "main")
        XCTAssertEqual(stashes[1].branch, "feature")
        XCTAssertEqual(stashes[1].title, "1a2b3c4 subject")
    }

    func testPushListAndTheTreeGoesClean() async throws {
        try write("a.txt", "changed\n")
        try write("new.txt", "untracked\n")

        let created = try await repo.stashPush(message: "wip a", includeUntracked: true)

        XCTAssertTrue(created)
        XCTAssertEqual(try read("a.txt"), "base\n")
        XCTAssertFalse(exists("new.txt"), "include-untracked takes the new file too")
        let list = try await repo.stashes()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].title, "wip a")
        XCTAssertEqual(list[0].branch, "main")
    }

    func testPushOfACleanTreeCreatesNothing() async throws {
        let created = try await repo.stashPush(message: "nothing")
        XCTAssertFalse(created)
        let list = try await repo.stashes()
        XCTAssertTrue(list.isEmpty)
    }

    func testPushWithPathsStashesOnlyThose() async throws {
        try write("a.txt", "changed a\n")
        try write("b.txt", "changed b\n")

        try await repo.stashPush(message: "only a", includeUntracked: false, paths: ["a.txt"])

        XCTAssertEqual(try read("a.txt"), "base\n")
        XCTAssertEqual(try read("b.txt"), "changed b\n")
    }

    func testKeepIndexLeavesStagedChangesInTheTree() async throws {
        try write("a.txt", "staged\n")
        _ = try await runner.run(["add", "a.txt"], in: directory)

        try await repo.stashPush(message: "keep", includeUntracked: false, keepIndex: true)

        XCTAssertEqual(try read("a.txt"), "staged\n")
        let count = try await repo.stashes().count
        XCTAssertEqual(count, 1)
    }

    func testApplyKeepsTheStashAndPopDropsIt() async throws {
        try write("a.txt", "one\n")
        try await repo.stashPush(message: "one")
        try write("a.txt", "two\n")
        try await repo.stashPush(message: "two")
        var list = try await repo.stashes()
        XCTAssertEqual(list.map(\.title), ["two", "one"])

        // The older stash, by hash: the index would have shifted if another one had been added.
        _ = try await repo.stashApply(list[1])
        XCTAssertEqual(try read("a.txt"), "one\n")
        list = try await repo.stashes()
        XCTAssertEqual(list.count, 2, "apply keeps the stash")

        _ = try await runner.run(["checkout", "--", "a.txt"], in: directory)
        _ = try await repo.stashPop(list[0])
        XCTAssertEqual(try read("a.txt"), "two\n")
        let after = try await repo.stashes()
        XCTAssertEqual(after.map(\.title), ["one"])
    }

    func testApplyWithReinstateIndexStagesAgain() async throws {
        try write("a.txt", "staged\n")
        _ = try await runner.run(["add", "a.txt"], in: directory)
        try await repo.stashPush(message: "staged", includeUntracked: false)
        let stash = try await firstStash()

        _ = try await repo.stashApply(stash, reinstateIndex: true)

        let status = try await repo.status()
        XCTAssertEqual(status.first?.indexCode, "M")
    }

    func testDropAndClear() async throws {
        for name in ["one", "two", "three"] {
            try write("a.txt", "\(name)\n")
            try await repo.stashPush(message: name)
        }
        let list = try await repo.stashes()
        // Dropping the middle one by hash leaves the others.
        _ = try await repo.stashDrop(list[1])
        let left = try await repo.stashes().map(\.title)
        XCTAssertEqual(left, ["three", "one"])

        try await repo.stashClear()
        let none = try await repo.stashes()
        XCTAssertTrue(none.isEmpty)
    }

    func testAStashThatIsGoneIsReportedNotDroppedByIndex() async throws {
        try write("a.txt", "one\n")
        try await repo.stashPush(message: "one")
        let stale = try await firstStash()
        try await repo.stashClear()
        try write("a.txt", "other\n")
        try await repo.stashPush(message: "other")

        do {
            _ = try await repo.stashDrop(stale)
            XCTFail("the stale stash must not drop whatever is at its old index")
        } catch {
            XCTAssertTrue(error is GitError)
        }
        let list = try await repo.stashes()
        XCTAssertEqual(list.map(\.title), ["other"])
    }

    func testBranchFromAStashCheckoutsTheOriginalCommitAndAppliesIt() async throws {
        try write("a.txt", "stashed\n")
        try await repo.stashPush(message: "wip")
        try write("a.txt", "moved on\n")
        _ = try await runner.run(["commit", "-q", "-am", "later"], in: directory)
        let stash = try await firstStash()

        _ = try await repo.stashBranch("from-stash", from: stash)

        let branch = await repo.currentBranch()
        XCTAssertEqual(branch, "from-stash")
        XCTAssertEqual(try read("a.txt"), "stashed\n")
        let remaining = try await repo.stashes()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testStashChangesListTrackedAndUntrackedFiles() async throws {
        try write("a.txt", "changed\n")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("b.txt"))
        try write("new.txt", "untracked\n")
        try await repo.stashPush(message: "mixed", includeUntracked: true)
        let stash = try await firstStash()

        let changes = try await repo.stashChanges(stash)

        let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.file.path, $0) })
        XCTAssertEqual(byPath["a.txt"]?.file.status, "M")
        XCTAssertEqual(byPath["a.txt"]?.isUntracked, false)
        XCTAssertEqual(byPath["b.txt"]?.file.status, "D")
        XCTAssertEqual(byPath["new.txt"]?.isUntracked, true)
        // The untracked file's content is readable from the stash's third parent.
        let data = try await repo.fileContents(at: .ref(stash.hash + "^3"), path: "new.txt")
        XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, "untracked\n")
    }

    func testAConflictingPopKeepsTheStash() async throws {
        try write("a.txt", "stashed\n")
        try await repo.stashPush(message: "wip")
        try write("a.txt", "committed\n")
        _ = try await runner.run(["commit", "-q", "-am", "diverge"], in: directory)

        do {
            _ = try await repo.stashPop()
            XCTFail("a conflicting pop must fail")
        } catch {
            XCTAssertTrue(error is GitError)
        }

        let kept = try await repo.stashes()
        XCTAssertEqual(kept.count, 1, "git keeps the stash when the pop conflicts")
        let status = try await repo.status()
        XCTAssertTrue(status.contains(where: \.isConflicted))
    }
}
