import Foundation
import XCTest
import EditorIntelligence

/// Disk-wide search: enumeration policy (ignored directories, skipped extensions, size cap,
/// binary/symlink skip) and per-file matching (case sensitivity, whole word, regex, hit cap).
final class ProjectSearchEngineTests: XCTestCase {
    private var root: URL!
    private let engine = ProjectSearchEngine()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-search-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("src/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "nothing to see here\n".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "func greet() {\n    print(\"hello needle world\")\n}\n".write(
            to: nested.appendingPathComponent("greet.swift"),
            atomically: true,
            encoding: .utf8
        )
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    func testSearchFindsHitInNestedFile() async throws {
        let hits = await engine.search(WorkspaceSearchQuery(text: "needle"), in: root)
        XCTAssertEqual(hits.count, 1, "expected one hit in the nested fixture")
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.url.lastPathComponent, "greet.swift")
        XCTAssertTrue(hit.url.path.contains("/src/nested/"), "hit must come from the nested file")
        XCTAssertEqual(hit.line, 1, "0-based, matching WorkspaceSearchResult.line")
        XCTAssertTrue(hit.preview.contains("hello needle world"))
    }

    func testMissQueryReturnsEmpty() async {
        let hits = await engine.search(WorkspaceSearchQuery(text: "this-token-is-not-in-the-tree"), in: root)
        XCTAssertTrue(hits.isEmpty)
    }

    func testEmptyQueryReturnsEmpty() async {
        let whitespaceOnly = await engine.search(WorkspaceSearchQuery(text: "   "), in: root)
        XCTAssertTrue(whitespaceOnly.isEmpty)
        let empty = await engine.search(WorkspaceSearchQuery(text: ""), in: root)
        XCTAssertTrue(empty.isEmpty)
    }

    func testHitRangeLiesOnTheMatchingLine() async throws {
        let hits = await engine.search(WorkspaceSearchQuery(text: "needle"), in: root)
        let hit = try XCTUnwrap(hits.first)

        let text = try String(contentsOf: hit.url, encoding: .utf8)
        let nsText = text as NSString
        let range = NSRange(location: hit.range.start.utf16Offset, length: hit.range.end.utf16Offset - hit.range.start.utf16Offset)
        XCTAssertEqual(nsText.substring(with: range).lowercased(), "needle")

        let lineRange = nsText.lineRange(for: NSRange(location: range.location, length: 0))
        XCTAssertEqual(NSIntersectionRange(range, lineRange), range, "chosen range must lie on the matching line")
    }

    func testFilesUnderRootFindsNestedFileAndSearchAgreesWithSearchByFileList() async {
        let files = await engine.files(under: root)
        XCTAssertTrue(files.contains { $0.lastPathComponent == "greet.swift" })
        let byRoot = await engine.search(WorkspaceSearchQuery(text: "needle"), in: root)
        let byFiles = await engine.search(WorkspaceSearchQuery(text: "needle"), files: files)
        XCTAssertEqual(byRoot.map(\.url), byFiles.map(\.url))
    }

    func testIgnoredDirectoryIsSkipped() async throws {
        let ignored = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
        try "needle\n".write(to: ignored.appendingPathComponent("packed-refs"), atomically: true, encoding: .utf8)

        let hits = await engine.search(WorkspaceSearchQuery(text: "needle"), in: root)
        XCTAssertFalse(hits.contains { $0.url.path.contains("/.git/") })
    }

    func testSkippedExtensionIsNotOpened() async throws {
        // A "png" with text content would match if opened; the extension skip must prevent that.
        try "needle\n".write(to: root.appendingPathComponent("image.png"), atomically: true, encoding: .utf8)

        let hits = await engine.search(WorkspaceSearchQuery(text: "needle"), in: root)
        XCTAssertFalse(hits.contains { $0.url.lastPathComponent == "image.png" })
    }

    func testOversizedFileIsSkipped() async throws {
        let big = root.appendingPathComponent("big.txt")
        let oneMegabyte = String(repeating: "x", count: 1_000_000)
        try (oneMegabyte + "needle").write(to: big, atomically: true, encoding: .utf8)

        let policy = FileEnumerationPolicy(maxFileByteCount: 100)
        let hits = await engine.search(WorkspaceSearchQuery(text: "needle"), in: root, policy: policy)
        XCTAssertFalse(hits.contains { $0.url.lastPathComponent == "big.txt" })
    }

    func testBinaryFileIsSkipped() async throws {
        let binary = root.appendingPathComponent("data.bin")
        var bytes = Array("needle".utf8)
        bytes.append(0)
        try Data(bytes).write(to: binary)

        let hits = await engine.search(WorkspaceSearchQuery(text: "needle"), in: root)
        XCTAssertFalse(hits.contains { $0.url.lastPathComponent == "data.bin" })
    }

    func testSymbolicLinkIsNotFollowedByDefault() async throws {
        let target = root.appendingPathComponent("src/nested/greet.swift")
        let link = root.appendingPathComponent("greet-link.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let files = await engine.files(under: root)
        XCTAssertFalse(files.contains { $0.lastPathComponent == "greet-link.swift" })
    }

    func testMultipleHitsInOneFileAreAllReturnedWithIncreasingLines() async throws {
        let multi = root.appendingPathComponent("multi.txt")
        try "needle one\nplain\nneedle two\nneedle three\n".write(to: multi, atomically: true, encoding: .utf8)

        let hits = await engine.search(WorkspaceSearchQuery(text: "needle"), files: [multi])
        XCTAssertEqual(hits.map(\.line), [0, 2, 3])
    }

    func testHitCountIsCappedAtMaxResults() async throws {
        let many = root.appendingPathComponent("many.txt")
        let content = (0..<10).map { "needle \($0)" }.joined(separator: "\n")
        try content.write(to: many, atomically: true, encoding: .utf8)

        let hits = await engine.search(WorkspaceSearchQuery(text: "needle"), files: [many], maxResults: 3)
        XCTAssertEqual(hits.count, 3)
    }

    func testCaseSensitiveFlagRestrictsMatches() async throws {
        let file = root.appendingPathComponent("case.txt")
        try "Needle\nneedle\n".write(to: file, atomically: true, encoding: .utf8)

        let insensitive = await engine.search(WorkspaceSearchQuery(text: "needle", isCaseSensitive: false), files: [file])
        XCTAssertEqual(insensitive.count, 2)

        let sensitive = await engine.search(WorkspaceSearchQuery(text: "needle", isCaseSensitive: true), files: [file])
        XCTAssertEqual(sensitive.count, 1)
        XCTAssertEqual(sensitive.first?.line, 1)
    }

    func testMatchWholeWordFlagExcludesSubstringMatches() async throws {
        let file = root.appendingPathComponent("word.txt")
        try "needles\nneedle\n".write(to: file, atomically: true, encoding: .utf8)

        let contains = await engine.search(WorkspaceSearchQuery(text: "needle"), files: [file])
        XCTAssertEqual(contains.count, 2)

        let wholeWord = await engine.search(WorkspaceSearchQuery(text: "needle", matchWholeWord: true), files: [file])
        XCTAssertEqual(wholeWord.count, 1)
        XCTAssertEqual(wholeWord.first?.line, 1)
    }

    func testRegularExpressionFlagTreatsQueryAsAPattern() async throws {
        let file = root.appendingPathComponent("regex.txt")
        try "foo123\nfoobar\n".write(to: file, atomically: true, encoding: .utf8)

        let hits = await engine.search(WorkspaceSearchQuery(text: "foo\\d+", useRegularExpression: true), files: [file])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.line, 0)
    }
}
