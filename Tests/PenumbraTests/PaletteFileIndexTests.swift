import XCTest
@testable import Penumbra

final class PaletteFileIndexTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/proj")

    private func makeIndex(_ paths: [String]) -> PaletteFileIndex {
        PaletteFileIndex(entries: paths.map { path in
            PaletteFileIndex.Entry(
                url: root.appendingPathComponent(path),
                relativePath: path,
                location: nil,
                module: nil,
                icon: PaletteIcon(systemName: "doc")
            )
        })
    }

    private func paths(_ result: PaletteFileIndex.SearchResult, in index: PaletteFileIndex) -> [String] {
        result.hits.map { index.entry(at: $0.index).relativePath }
    }

    private let sample = [
        "src/main/java/api/ApiKeyController.java",
        "src/main/java/api/ApiKeyFilter.java",
        "src/main/java/api/ApiKeyService.java",
        "src/main/java/auth/AuthenticationFilter.java",
        "src/main/java/util/KeyCache.java",
        "src/main/resources/bootstrap.yaml",
        "build.gradle.kts",
        "docs/api-notes.md"
    ]

    func testCamelHumpMatchesFileName() {
        let index = makeIndex(sample)
        let result = index.search("AKC", limit: 5)
        XCTAssertEqual(paths(result, in: index).first, "src/main/java/api/ApiKeyController.java")
    }

    func testNamePrefixBeatsPathOnlyMatch() {
        let index = makeIndex(sample)
        // "api" is a directory of three Java files and the start of "api-notes.md".
        let result = index.search("api", limit: 8)
        XCTAssertEqual(paths(result, in: index).first, "docs/api-notes.md")
    }

    func testStemEqualityRanksAboveLongerPrefix() {
        let index = makeIndex(["ApiKeyControllerTest.java", "ApiKeyController.java"])
        let result = index.search("ApiKeyController", limit: 2)
        XCTAssertEqual(paths(result, in: index), ["ApiKeyController.java", "ApiKeyControllerTest.java"])
    }

    func testDirectorySegmentRestrictsMatches() {
        let index = makeIndex(sample)
        let result = index.search("auth/Filter", limit: 8)
        XCTAssertEqual(paths(result, in: index), ["src/main/java/auth/AuthenticationFilter.java"])
    }

    func testMultipleTermsMustAllMatch() {
        let index = makeIndex(sample)
        let result = index.search("Key Filter", limit: 8)
        XCTAssertEqual(paths(result, in: index), ["src/main/java/api/ApiKeyFilter.java"])
    }

    func testPathSubsequenceIsWeakestFallback() {
        let index = makeIndex(sample)
        let result = index.search("mainbootstrap", limit: 8)
        XCTAssertEqual(paths(result, in: index), ["src/main/resources/bootstrap.yaml"])
    }

    func testNonMatchingQueryReturnsNothing() {
        let index = makeIndex(sample)
        XCTAssertTrue(index.search("zzzq", limit: 8).hits.isEmpty)
    }

    func testEmptyQueryLeadsWithBoostsInOrder() {
        let index = makeIndex(sample)
        let boosts = [root.appendingPathComponent("build.gradle.kts"), root.appendingPathComponent("docs/api-notes.md")]
        let result = index.search("", limit: 4, boosts: boosts)
        XCTAssertEqual(Array(paths(result, in: index).prefix(2)), ["build.gradle.kts", "docs/api-notes.md"])
        XCTAssertEqual(result.hits.count, 4)
    }

    func testBoostLiftsAnOtherwiseEqualMatch() {
        let index = makeIndex(["a/Foo.java", "b/Foo.java"])
        let boosts = [root.appendingPathComponent("b/Foo.java")]
        let result = index.search("Foo", limit: 2, boosts: boosts)
        XCTAssertEqual(paths(result, in: index).first, "b/Foo.java")
    }

    func testTiesResolveInIndexOrder() {
        let index = makeIndex(["a/Foo.java", "b/Foo.java", "c/Foo.java"])
        XCTAssertEqual(paths(index.search("Foo", limit: 3), in: index), ["a/Foo.java", "b/Foo.java", "c/Foo.java"])
    }

    func testLimitCapsResults() {
        let index = makeIndex((0..<200).map { "dir/File\($0).swift" })
        XCTAssertEqual(index.search("File", limit: 10).hits.count, 10)
    }

    func testNarrowingGivesTheSameResultsAsAColdSearch() {
        let index = makeIndex(sample)
        let first = index.search("Api", limit: 8)
        XCTAssertNotNil(first.candidates)
        let narrowed = index.search("ApiKeyS", limit: 8, among: first.candidates)
        let cold = index.search("ApiKeyS", limit: 8)
        XCTAssertEqual(narrowed.hits, cold.hits)
    }

    func testQueriesWithTermsOrDirectoriesAreNotNarrowable() {
        let index = makeIndex(sample)
        XCTAssertNil(index.search("api/Key", limit: 8).candidates)
        XCTAssertNil(index.search("Key Filter", limit: 8).candidates)
    }

    func testHighlightOffsetsCoverTheHumps() {
        let index = makeIndex(sample)
        let hit = index.search("AKC", limit: 1).hits[0]
        XCTAssertEqual(index.highlightOffsets(forEntryAt: hit.index, query: "AKC"), [0, 3, 6])
    }

    func testSubstringMatchesAreHighlighted() {
        let index = makeIndex(["src/BootstrapConfig.java"])
        let hit = index.search("strap", limit: 1).hits[0]
        XCTAssertEqual(index.highlightOffsets(forEntryAt: hit.index, query: "strap"), [4, 5, 6, 7, 8])
    }

    func testSearchStaysFastOnALargeIndex() {
        let paths = (0..<100_000).map { "module\($0 % 50)/src/main/java/pkg\($0 % 400)/Service\($0).java" }
        let index = makeIndex(paths)
        measure {
            _ = index.search("Serv99", limit: 60)
        }
    }
}
