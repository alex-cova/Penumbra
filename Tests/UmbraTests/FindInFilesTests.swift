import Foundation
import XCTest
@testable import UmbraCore

final class FindInFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-find-in-files-\(UUID().uuidString)", isDirectory: true)
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

    func testSearchFindsHitInNestedFile() throws {
        let hits = FindInFilesService.search(query: "needle", root: root)
        XCTAssertEqual(hits.count, 1, "expected one hit in the nested fixture")
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.url.lastPathComponent, "greet.swift")
        XCTAssertTrue(hit.url.path.contains("/src/nested/"), "hit must come from the nested file")
        XCTAssertEqual(hit.lineNumber, 2)
        XCTAssertTrue(hit.lineText.contains("hello needle world"))
    }

    func testMissQueryReturnsEmpty() {
        let hits = FindInFilesService.search(query: "this-token-is-not-in-the-tree", root: root)
        XCTAssertTrue(hits.isEmpty)
    }

    func testEmptyQueryReturnsEmpty() {
        XCTAssertTrue(FindInFilesService.search(query: "   ", root: root).isEmpty)
        XCTAssertTrue(FindInFilesService.search(query: "", root: root).isEmpty)
    }

    func testChoosingAHitYieldsFileURLAndRangeOnMatchingLine() throws {
        let hits = FindInFilesService.search(query: "needle", root: root)
        let hit = try XCTUnwrap(hits.first)
        let target = FindInFilesService.openTarget(for: hit)

        XCTAssertEqual(target.url, hit.url)
        XCTAssertEqual(target.lineNumber, hit.lineNumber)
        XCTAssertEqual(target.range, hit.matchRange)

        let text = try String(contentsOf: target.url, encoding: .utf8)
        let nsText = text as NSString
        XCTAssertEqual(nsText.substring(with: target.range).lowercased(), "needle")

        let lineRange = nsText.lineRange(for: NSRange(location: target.range.location, length: 0))
        let intersection = NSIntersectionRange(target.range, lineRange)
        XCTAssertEqual(intersection, target.range, "chosen range must lie on the matching line")
        XCTAssertEqual(hit.lineNumber, 2)
    }

    func testSearchUsesTheSameFileEnumeratorAsTheScanEntry() {
        let files = FindInFilesService.files(under: root)
        XCTAssertTrue(files.contains { $0.lastPathComponent == "greet.swift" })
        XCTAssertEqual(
            FindInFilesService.search(query: "needle", files: files).map(\.url),
            FindInFilesService.search(query: "needle", root: root).map(\.url)
        )
    }
}
