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
}
