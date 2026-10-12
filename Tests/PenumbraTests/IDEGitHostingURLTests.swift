import XCTest
@testable import Umbra

final class IDEGitHostingURLTests: XCTestCase {
    private func parse(_ url: String) -> IDEGitHostingURL? { IDEGitHostingURL(remoteURL: url) }

    func testTheCommonRemoteForms() {
        for url in [
            "git@github.com:alex-cova/Penumbra.git",
            "ssh://git@github.com/alex-cova/Penumbra.git",
            "ssh://git@github.com:22/alex-cova/Penumbra",
            "https://github.com/alex-cova/Penumbra.git",
            "https://token@github.com/alex-cova/Penumbra",
            "git://github.com/alex-cova/Penumbra.git"
        ] {
            let parsed = parse(url)
            XCTAssertEqual(parsed?.host, "github.com", url)
            XCTAssertEqual(parsed?.path, "alex-cova/Penumbra", url)
            XCTAssertEqual(parsed?.base?.absoluteString, "https://github.com/alex-cova/Penumbra", url)
        }
    }

    func testLocalPathsAndGarbageAreNotHostedRepositories() {
        XCTAssertNil(parse("/Users/me/repo.git"))
        XCTAssertNil(parse("../sibling"))
        XCTAssertNil(parse("file:///tmp/remote.git"))
        XCTAssertNil(parse(""))
    }

    func testGitHubPages() throws {
        let host = try XCTUnwrap(parse("git@github.com:o/r.git"))
        XCTAssertEqual(host.serviceName, "GitHub")
        XCTAssertEqual(host.commitURL("abc123")?.absoluteString, "https://github.com/o/r/commit/abc123")
        XCTAssertEqual(host.branchURL("feature/x")?.absoluteString, "https://github.com/o/r/tree/feature/x")
        XCTAssertEqual(host.fileURL(ref: "main", path: "src/A b.swift", isCommit: false, lines: 10 ... 20)?.absoluteString,
                       "https://github.com/o/r/blob/main/src/A%20b.swift#L10-L20")
        XCTAssertEqual(host.fileURL(ref: "main", path: "a.swift", isCommit: false, lines: 7 ... 7)?.absoluteString,
                       "https://github.com/o/r/blob/main/a.swift#L7")
    }

    func testGitLabKeepsSubgroupsAndUsesTheDashPaths() throws {
        let host = try XCTUnwrap(parse("git@gitlab.example.com:group/sub/repo.git"))
        XCTAssertEqual(host.path, "group/sub/repo")
        XCTAssertEqual(host.commitURL("abc")?.absoluteString, "https://gitlab.example.com/group/sub/repo/-/commit/abc")
        XCTAssertEqual(host.fileURL(ref: "main", path: "a.rb", isCommit: false, lines: 3 ... 9)?.absoluteString,
                       "https://gitlab.example.com/group/sub/repo/-/blob/main/a.rb#L3-9")
    }

    func testBitbucketAndGitea() throws {
        let bitbucket = try XCTUnwrap(parse("git@bitbucket.org:team/repo.git"))
        XCTAssertEqual(bitbucket.commitURL("abc")?.absoluteString, "https://bitbucket.org/team/repo/commits/abc")
        XCTAssertEqual(bitbucket.fileURL(ref: "main", path: "a.py", isCommit: false, lines: 3 ... 9)?.absoluteString,
                       "https://bitbucket.org/team/repo/src/main/a.py#lines-3:9")
        let gitea = try XCTUnwrap(parse("https://codeberg.org/o/r.git"))
        XCTAssertEqual(gitea.serviceName, "Codeberg")
        XCTAssertEqual(gitea.fileURL(ref: "abc", path: "a.go", isCommit: true)?.absoluteString,
                       "https://codeberg.org/o/r/src/commit/abc/a.go")
        XCTAssertEqual(gitea.branchURL("main")?.absoluteString, "https://codeberg.org/o/r/src/branch/main")
    }

    func testHashesAndQuestionMarksInPathsAreEscaped() throws {
        let host = try XCTUnwrap(parse("git@github.com:o/r.git"))
        let url = host.fileURL(ref: "main", path: "notes/#1 what?.md", isCommit: false)?.absoluteString
        XCTAssertEqual(url, "https://github.com/o/r/blob/main/notes/%231%20what%3F.md")
    }
}
