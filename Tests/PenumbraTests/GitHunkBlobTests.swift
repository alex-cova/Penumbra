import XCTest
@testable import GitIntelligence

/// `applyHunk` swaps a hunk's lines into the index blob the diff was read from.
final class GitHunkBlobTests: XCTestCase {
    private var directory: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-hunk-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@e.com"],
                     ["config", "commit.gpgsign", "false"], ["config", "core.autocrlf", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func repo() async throws -> GitRepository {
        let found = await GitRepository.discover(from: directory)
        return try XCTUnwrap(found)
    }

    private func commit(_ name: String, _ text: String, executable: Bool = false) async throws {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        _ = try await runner.run(["add", "--", name], in: directory)
        _ = try await runner.run(["commit", "-qm", "add \(name)"], in: directory)
    }

    private func show(_ name: String) async throws -> String {
        try await runner.run(["show", ":\(name)"], in: directory).text
    }

    private func patch(_ body: String, name: String = "f.txt") -> String {
        "diff --git a/\(name) b/\(name)\n--- a/\(name)\n+++ b/\(name)\n" + body
    }

    func testTheFileModeSurvivesAHunk() async throws {
        try await commit("run.sh", "1\n2\n", executable: true)
        let repo = try await repo()
        let blob = await repo.indexBlobID("run.sh")
        try await repo.applyHunk(GitHunkApply(
            relativePath: "run.sh", baseBlobID: blob, patch: patch("@@ -2,1 +2,1 @@\n-2\n+TWO\n", name: "run.sh"), reverse: false
        ))
        let listing = try await runner.run(["ls-files", "-s", "run.sh"], in: directory).text
        XCTAssertTrue(listing.hasPrefix("100755"), listing)
        let contents = try await show("run.sh")
        XCTAssertEqual(contents, "1\nTWO\n")
    }

    func testAMissingFinalLineBreakIsKeptAndAddedLinesAfterItGainTheBreak() async throws {
        try await commit("f.txt", "a\nb")
        let repo = try await repo()
        var blob = await repo.indexBlobID("f.txt")
        try await repo.applyHunk(GitHunkApply(
            relativePath: "f.txt", baseBlobID: blob,
            patch: patch("@@ -2,1 +2,1 @@\n-b\n\\ No newline at end of file\n+c\n\\ No newline at end of file\n"), reverse: false
        ))
        var contents = try await show("f.txt")
        XCTAssertEqual(contents, "a\nc")
        blob = await repo.indexBlobID("f.txt")
        try await repo.applyHunk(GitHunkApply(
            relativePath: "f.txt", baseBlobID: blob,
            patch: patch("@@ -2,1 +2,2 @@\n-c\n\\ No newline at end of file\n+c\n+d\n"), reverse: false
        ))
        contents = try await show("f.txt")
        XCTAssertEqual(contents, "a\nc\nd\n")
    }

    func testReverseTakesTheHunkBackOutOfTheIndex() async throws {
        try await commit("f.txt", "1\n2\n3\n")
        try "1\nTWO\n3\n".write(to: directory.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "f.txt"], in: directory)
        let repo = try await repo()
        let blob = await repo.indexBlobID("f.txt")
        try await repo.applyHunk(GitHunkApply(
            relativePath: "f.txt", baseBlobID: blob, patch: patch("@@ -2,1 +2,1 @@\n-2\n+TWO\n"), reverse: true
        ))
        let contents = try await show("f.txt")
        XCTAssertEqual(contents, "1\n2\n3\n")
    }

    func testAPureInsertionLandsAfterTheNamedLine() async throws {
        try await commit("f.txt", "1\n3\n")
        let repo = try await repo()
        let blob = await repo.indexBlobID("f.txt")
        try await repo.applyHunk(GitHunkApply(
            relativePath: "f.txt", baseBlobID: blob, patch: patch("@@ -1,0 +2,1 @@\n+2\n"), reverse: false
        ))
        let contents = try await show("f.txt")
        XCTAssertEqual(contents, "1\n2\n3\n")
    }

    func testANameWithANewlineAndAQuoteIsNotAnObstacle() async throws {
        let name = "we\"ird\nname.txt"
        try await commit(name, "1\n2\n")
        let repo = try await repo()
        let blob = await repo.indexBlobID(name)
        XCTAssertNotNil(blob)
        try await repo.applyHunk(GitHunkApply(
            relativePath: name, baseBlobID: blob, patch: patch("@@ -2,1 +2,1 @@\n-2\n+TWO\n", name: "x"), reverse: false
        ))
        let contents = try await show(name)
        XCTAssertEqual(contents, "1\nTWO\n")
    }

    func testAHunkThatNamesOtherLinesThanTheIndexHoldsIsRefusedAndLeavesTheIndex() async throws {
        try await commit("f.txt", "1\n2\n3\n")
        let repo = try await repo()
        let blob = await repo.indexBlobID("f.txt")
        do {
            try await repo.applyHunk(GitHunkApply(
                relativePath: "f.txt", baseBlobID: blob, patch: patch("@@ -3,1 +3,1 @@\n-2\n+x\n"), reverse: false
            ))
            XCTFail("the lines do not match")
        } catch is GitError {}
        let after = await repo.indexBlobID("f.txt")
        XCTAssertEqual(after, blob)
    }

    func testAnUnmergedFileIsRefused() async throws {
        try await commit("f.txt", "1\n")
        _ = try await runner.run(["checkout", "-qb", "side"], in: directory)
        try await commit("f.txt", "side\n")
        _ = try await runner.run(["checkout", "-q", "main"], in: directory)
        try await commit("f.txt", "main\n")
        _ = try? await runner.run(["merge", "side"], in: directory)
        let repo = try await repo()
        do {
            try await repo.applyHunk(GitHunkApply(relativePath: "f.txt", baseBlobID: nil, patch: patch("@@ -1,1 +1,1 @@\n-main\n+x\n"), reverse: false))
            XCTFail("a conflicted path has no single blob")
        } catch let error as GitError {
            guard case .invalidRequest(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("conflict"), message)
        }
    }

    func testTheParserReadsCountsAndMarkers() {
        let hunk = GitZeroContextHunk.parse("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -2,1 +2,2 @@\n-b\n\\ No newline at end of file\n+b\n+c\n")
        XCTAssertEqual(hunk?.removed, [Data("b".utf8)])
        XCTAssertEqual(hunk?.added, [Data("b\n".utf8), Data("c\n".utf8)])
        XCTAssertNil(GitZeroContextHunk.parse("@@ -1,1 +1,1 @@\n-a\n"), "the counts must match the lines")
        XCTAssertNil(GitZeroContextHunk.parse("@@ -1,1 +1,1 @@\n-a\n+b\n@@ -5,1 +5,1 @@\n-c\n+d\n"), "one hunk only")
    }
}
