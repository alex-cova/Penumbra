import XCTest
@testable import GitIntelligence

/// `git blame` options, revision blame and the extra porcelain fields, against real git.
final class GitBlameIntegrationTests: XCTestCase {
    private var directory: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath),
                          "git is not installed at \(SystemGitRunner.executablePath)")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-blame-\(UUID().uuidString)", isDirectory: true)
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

    private func makeRepo() async throws -> GitRepository {
        let found = await GitRepository.discover(from: directory)
        return try XCTUnwrap(found)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Commits `text` as `name` and returns the new HEAD.
    @discardableResult
    private func commit(_ repo: GitRepository, _ name: String, _ text: String, _ message: String) async throws -> String {
        try write(name, text)
        _ = try await repo.commit(message: message, paths: [name], untrackedPaths: [name], amend: false)
        let head = await repo.headCommit()
        return try XCTUnwrap(head)
    }

    func testIgnoreWhitespaceSkipsAReindentingCommit() async throws {
        let repo = try await makeRepo()
        let first = try await commit(repo, "a.txt", "one\ntwo\n", "first")
        let indented = try await commit(repo, "a.txt", "  one\n  two\n", "indent")
        let contents = Data("  one\n  two\n".utf8)

        let plain = try await repo.blame(relativePath: "a.txt", contents: contents)
        XCTAssertEqual(plain.map(\.hash), [indented, indented])

        let ignoring = try await repo.blame(relativePath: "a.txt", contents: contents,
                                            options: GitBlameOptions(ignoreWhitespace: true))
        XCTAssertEqual(ignoring.map(\.hash), [first, first])
    }

    func testIgnoredRevisionHandsTheLineBackToTheCommitBefore() async throws {
        let repo = try await makeRepo()
        let first = try await commit(repo, "a.txt", "keep\nformat me\n", "first")
        let formatting = try await commit(repo, "a.txt", "keep\nformat me!\n", "formatting")
        let contents = Data("keep\nformat me!\n".utf8)

        let plain = try await repo.blame(relativePath: "a.txt", contents: contents)
        XCTAssertEqual(plain[1].hash, formatting)

        let hidden = try await repo.blame(relativePath: "a.txt", contents: contents,
                                          options: GitBlameOptions(ignoredRevisions: [formatting]))
        XCTAssertEqual(hidden.map(\.hash), [first, first])
    }

    func testAnOptionLookingRevisionToIgnoreIsRefusedBeforeGitRuns() async throws {
        let repo = try await makeRepo()
        try await commit(repo, "a.txt", "one\n", "first")
        do {
            _ = try await repo.blame(relativePath: "a.txt", contents: Data("one\n".utf8),
                                     options: GitBlameOptions(ignoredRevisions: ["--contents=/etc/passwd"]))
            XCTFail("expected the revision to be refused")
        } catch GitError.invalidRequest {
        }
    }

    func testDetectMovesWithinFileAttributesAMovedBlockToItsOrigin() async throws {
        let repo = try await makeRepo()
        // The block is the shorter side of the move, so git's diff sees it as removed and added again
        // (a lone line moved past it would leave the block as unchanged context).
        let block = "alpha beta gamma\ndelta epsilon zeta\neta theta iota\n"
        let filler = (1...12).map { "filler line number \($0)\n" }.joined()
        let first = try await commit(repo, "a.txt", block + filler, "first")
        let moved = try await commit(repo, "a.txt", filler + block, "move")
        let contents = Data((filler + block).utf8)
        let blockRows = 12..<15

        let plain = try await repo.blame(relativePath: "a.txt", contents: contents)
        XCTAssertEqual(plain[blockRows].map(\.hash), [moved, moved, moved])

        let detecting = try await repo.blame(relativePath: "a.txt", contents: contents,
                                             options: GitBlameOptions(detectMovesWithinFile: true))
        XCTAssertEqual(detecting[blockRows].map(\.hash), [first, first, first])
        XCTAssertEqual(detecting[0].hash, first)
    }

    func testRevisionBlameAnnotatesTheFileAsItWasThen() async throws {
        let repo = try await makeRepo()
        let first = try await commit(repo, "a.txt", "one\ntwo\n", "first")
        let second = try await commit(repo, "a.txt", "one\ntwo\nthree\n", "second")

        let old = try await repo.blame(relativePath: "a.txt", revision: first)
        XCTAssertEqual(old.count, 2)
        XCTAssertEqual(old.map(\.hash), [first, first])

        let current = try await repo.blame(relativePath: "a.txt", revision: second)
        XCTAssertEqual(current.map(\.hash), [first, first, second])
        let blob = try await repo.fileContents(at: .commit(second), path: "a.txt")
        let contents = try XCTUnwrap(blob)
        XCTAssertEqual(current.count, String(decoding: contents, as: UTF8.self).split(separator: "\n").count)

        do {
            _ = try await repo.blame(relativePath: "a.txt", revision: "--contents")
            XCTFail("expected the revision to be refused")
        } catch GitError.invalidRequest {
        }
    }

    func testPreviousOriginalLineAndBoundaryComeFromTheCommit() async throws {
        let repo = try await makeRepo()
        let first = try await commit(repo, "a.txt", "one\ntwo\n", "first")
        let second = try await commit(repo, "a.txt", "one\nTWO\n", "second")

        let lines = try await repo.blame(relativePath: "a.txt", contents: Data("one\nTWO\n".utf8))
        XCTAssertEqual(lines[0].hash, first)
        XCTAssertNil(lines[0].previous)
        XCTAssertEqual(lines[1].hash, second)
        XCTAssertEqual(lines[1].previous, GitBlamePrevious(hash: first, path: "a.txt"))
        XCTAssertEqual(lines[1].originalLine, 2)
        XCTAssertEqual(lines[1].originalPath, "a.txt")
        XCTAssertEqual(lines[1].authorEmail, "t@example.com")
        XCTAssertEqual(lines[1].committer, "Tester")
        XCTAssertFalse(lines[1].isBoundary)
    }

    func testAnUncommittedLineHasNoPreviousCommit() async throws {
        let repo = try await makeRepo()
        try await commit(repo, "a.txt", "one\n", "first")
        let lines = try await repo.blame(relativePath: "a.txt", contents: Data("one\nunsaved\n".utf8))
        XCTAssertTrue(lines[1].isUncommitted)
        XCTAssertNil(lines[1].previous)
    }
}
