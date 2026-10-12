import XCTest
@testable import GitIntelligence

final class GitParsersTests: XCTestCase {
    func testStatusParsesRenameOriginAndUntracked() {
        let out = "R  new.txt\0old.txt\0 M a.swift\0?? b.swift\0UU c.swift\0"
        let entries = GitStatusParser.parse(out)
        XCTAssertEqual(entries.map(\.path), ["new.txt", "a.swift", "b.swift", "c.swift"])
        XCTAssertEqual(entries[0].originalPath, "old.txt")
        XCTAssertTrue(entries[2].isUntracked)
        XCTAssertTrue(entries[3].isConflicted)
        XCTAssertFalse(entries[1].isConflicted)
    }

    func testRefParserClassifiesDecorations() {
        let refs = GitRefParser.parse("HEAD -> main, origin/main, tag: v1, feature/x", remotes: ["origin"])
        XCTAssertEqual(refs, [
            GitRef(name: "HEAD", kind: .head),
            GitRef(name: "main", kind: .localBranch),
            GitRef(name: "origin/main", kind: .remoteBranch),
            GitRef(name: "v1", kind: .tag),
            GitRef(name: "feature/x", kind: .localBranch)
        ])
        XCTAssertEqual(GitRefParser.parse("HEAD"), [GitRef(name: "HEAD", kind: .head)])
    }

    func testLogParser() {
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
        let out = "\(a)\0\(b)\0Ann\0ann@x.com\01700000000\0HEAD -> main\0Fix thing\u{1e}\n\(b)\0\0Bob\0b@x.com\01600000000\0\0Root\u{1e}\n"
        let commits = GitLogParser.parse(out)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].parents, [b])
        XCTAssertEqual(commits[0].subject, "Fix thing")
        XCTAssertEqual(commits[1].hash, b)
        XCTAssertTrue(commits[1].parents.isEmpty)
        XCTAssertEqual(commits[1].author, "Bob")
    }

    func testNameStatusParserHandlesRenames() {
        let files = GitNameStatusParser.parse("M\0a.txt\0R100\0old.txt\0new.txt\0A\0c.txt\0")
        XCTAssertEqual(files.map(\.path), ["a.txt", "new.txt", "c.txt"])
        XCTAssertEqual(files[1].oldPath, "old.txt")
        XCTAssertEqual(files[1].status, "R")
    }

    func testBlameCachesCommitDetailsAndFlagsUncommitted() {
        let h = String(repeating: "a", count: 40)
        let z = String(repeating: "0", count: 40)
        let out = """
        \(h) 1 1 2
        author Ann
        author-time 1700000000
        summary First
        filename f
        \tline one
        \(h) 2 2
        \tline two
        \(z) 3 3 1
        author Not Committed Yet
        author-time 1700000500
        summary External file (--contents)
        filename f
        \tline three

        """
        let lines = GitBlameParser.parse(out)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1].author, "Ann")
        XCTAssertEqual(lines[1].summary, "First")
        XCTAssertFalse(lines[1].isUncommitted)
        XCTAssertTrue(lines[2].isUncommitted)
    }

    // MARK: - Progress

    func testProgressLineWithAPercentage() {
        let progress = GitProgressParser.parseLine("Receiving objects:  45% (450/1000), 1.2 MiB | 3.4 MiB/s")
        XCTAssertEqual(progress?.phase, "Receiving objects")
        XCTAssertEqual(progress?.fraction, 0.45)
    }

    func testProgressStripsTheRemotePrefix() {
        let progress = GitProgressParser.parseLine("remote: Compressing objects: 100% (12/12), done.")
        XCTAssertEqual(progress?.phase, "Compressing objects")
        XCTAssertEqual(progress?.fraction, 1)
        XCTAssertEqual(progress?.text, "Compressing objects: 100% (12/12), done.")
    }

    func testAMessageWithoutAPercentageHasNoFraction() {
        let progress = GitProgressParser.parseLine("From github.com:owner/repo")
        XCTAssertEqual(progress?.fraction, nil)
        XCTAssertEqual(progress?.text, "From github.com:owner/repo")
        XCTAssertNil(GitProgressParser.parseLine("   "))
    }

    func testProgressParserJoinsALineSplitAcrossChunksAndHandlesCarriageReturns() {
        var parser = GitProgressParser()
        var seen: [GitProgress] = []
        seen += parser.feed(Data("Receiving objects:  10% (1/10)\rReceiving obj".utf8))
        seen += parser.feed(Data("ects:  20% (2/10)\rResolving deltas: 100% (3/3), done.\n".utf8))
        seen += parser.finish()
        XCTAssertEqual(seen.map(\.fraction), [0.1, 0.2, 1])
        XCTAssertEqual(seen.map(\.phase), ["Receiving objects", "Receiving objects", "Resolving deltas"])
    }

    func testProgressParserKeepsAMultiByteCharacterSplitAcrossReads() {
        var parser = GitProgressParser()
        let bytes = Array("From café:repo\n".utf8)
        // Split inside the two-byte "é".
        let split = bytes.firstIndex(of: 0xC3)! + 1
        var seen = parser.feed(Data(bytes[..<split]))
        seen += parser.feed(Data(bytes[split...]))
        XCTAssertEqual(seen.map(\.text), ["From café:repo"])
    }

    func testProgressParserFlushesAnUnterminatedLastLine() {
        var parser = GitProgressParser()
        XCTAssertTrue(parser.feed(Data("Writing objects: 100% (4/4)".utf8)).isEmpty)
        XCTAssertEqual(parser.finish().map(\.fraction), [1])
    }

    func testCommandRecordQuotesArgumentsForAShell() {
        let record = GitCommandRecord(
            arguments: ["commit", "-m", "it's a message", "--", "a b.txt"],
            directory: URL(fileURLWithPath: "/tmp"), exitStatus: 0, stderr: "", output: "", duration: 0)
        XCTAssertEqual(record.commandLine, "git commit -m 'it'\\''s a message' -- 'a b.txt'")
        XCTAssertFalse(record.isReadOnly)
        let query = GitCommandRecord(
            arguments: ["--no-optional-locks", "status"], directory: URL(fileURLWithPath: "/tmp"),
            exitStatus: 0, stderr: "", output: "", duration: 0)
        XCTAssertTrue(query.isReadOnly)
        XCTAssertEqual(query.commandLine, "git status")
    }

    // MARK: - Remotes, branches, tags

    func testRemoteParserPairsFetchAndPushUrls() {
        let out = "origin\tgit@host:o/r.git (fetch)\norigin\tgit@host:o/r.git (push)\nfork\thttps://h/x.git (fetch)\nfork\thttps://h/y.git (push)\n"
        XCTAssertEqual(GitRemoteParser.parse(out), [
            GitRemote(name: "origin", fetchURL: "git@host:o/r.git", pushURL: "git@host:o/r.git"),
            GitRemote(name: "fork", fetchURL: "https://h/x.git", pushURL: "https://h/y.git")
        ])
    }

    func testBranchParserReadsTrackingAndCurrent() {
        let a = String(repeating: "a", count: 40)
        let out = [
            "refs/heads/main\0\(a)\0origin/main\0[ahead 2, behind 1]\01700000000\0*",
            "refs/heads/old\0\(a)\0origin/old\0[gone]\01700000000\0 ",
            "refs/heads/local\0\(a)\0\0\01700000000\0 ",
            "refs/remotes/origin/HEAD\0\(a)\0\0\01700000000\0 ",
            "refs/remotes/origin/feature/x\0\(a)\0\0\01700000000\0 "
        ].joined(separator: "\n")

        let branches = GitBranchParser.parse(out)

        XCTAssertEqual(branches.map(\.name), ["main", "old", "local", "origin/feature/x"])
        XCTAssertTrue(branches[0].isCurrent)
        XCTAssertEqual(branches[0].ahead, 2)
        XCTAssertEqual(branches[0].behind, 1)
        XCTAssertTrue(branches[1].upstreamIsGone)
        XCTAssertNil(branches[2].upstream)
        XCTAssertEqual(branches[3].kind, .remote)
        XCTAssertEqual(branches[3].remoteName, "origin")
        XCTAssertEqual(branches[3].shortName, "feature/x")
        XCTAssertEqual(GitBranchParser.parseTrack("[behind 3]").behind, 3)
    }

    func testTagParserPeelsAnnotatedTags() {
        let t = String(repeating: "t", count: 40), c = String(repeating: "c", count: 40)
        let out = "v1\0\(t)\0\(c)\01700000000\0Release\nlight\0\(c)\0\01600000000\0A commit\n"
        let tags = GitTagParser.parse(out)
        XCTAssertEqual(tags.map(\.name), ["v1", "light"])
        XCTAssertEqual(tags[0].commit, c)
        XCTAssertTrue(tags[0].isAnnotated)
        XCTAssertFalse(tags[1].isAnnotated)
    }

    func testSwitchConflictParserReadsTheFileList() {
        let stderr = """
        error: Your local changes to the following files would be overwritten by checkout:
        \ta.txt
        \tdir/b.txt
        Please commit your changes or stash them before you switch branches.
        Aborting
        """
        XCTAssertEqual(GitSwitchConflictParser.parse(stderr), ["a.txt", "dir/b.txt"])
        XCTAssertNil(GitSwitchConflictParser.parse("fatal: invalid reference: nope"))
    }
}
