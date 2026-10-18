import EditorIntelligence
import XCTest
@testable import JavaIntelligence
@testable import LanguageSyntax

final class JavaDocumentParseCacheTests: XCTestCase {
    private func document(_ source: String, version: Int = 0, url: URL? = nil) -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let fileURL = url ?? URL(fileURLWithPath: "/proj/T.java")
        return Document(
            url: fileURL,
            displayName: fileURL.lastPathComponent,
            contentSnapshot: TextSnapshot(version: version, text: source),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
    }

    private func editReplacing(_ source: String, marker: String, with replacement: String) -> (Document, TextEdit) {
        let range = (source as NSString).range(of: marker)
        let start = TextPosition(line: 0, column: range.location, utf16Offset: range.location)
        let end = TextPosition(line: 0, column: range.location + range.length, utf16Offset: range.location + range.length)
        let updated = (source as NSString).replacingCharacters(in: range, with: replacement) as String
        return (
            document(updated, version: 1),
            TextEdit(range: TextRange(start: start, end: end), replacement: replacement)
        )
    }

    func testIncrementalEditPreservesClassName() async {
        let cache = JavaDocumentParseCache()
        let original = "class T { int x; }"
        let doc = document(original, version: 0)
        let first = await cache.tree(for: doc)
        let firstName = first?.rootNode.namedChildren.first?.child(byFieldName: "name")?.text
        XCTAssertEqual(firstName, "T")

        let (edited, edit) = editReplacing(original, marker: "x", with: "y")
        let second = await cache.tree(for: edited, edits: [edit])
        let secondName = second?.rootNode.namedChildren.first?.child(byFieldName: "name")?.text
        XCTAssertEqual(secondName, "T")
    }

    func testFullParseAfterLargeChange() async {
        let cache = JavaDocumentParseCache()
        let original = "class T { }"
        _ = await cache.tree(for: document(original, version: 0))
        let rewritten = "interface Service { void run(); }"
        let tree = await cache.tree(for: document(rewritten, version: 1))
        XCTAssertEqual(tree?.rootNode.type, "program")
        XCTAssertEqual(tree?.rootNode.namedChildren.first?.type, "interface_declaration")
    }

    // MARK: - Memory bounds

    func testCacheStaysWithinTheEntryCap() async {
        let saved = DocumentParseCache.maxEntries
        DocumentParseCache.maxEntries = 8
        defer { DocumentParseCache.maxEntries = saved }
        let cache = JavaDocumentParseCache()
        for i in 0 ..< 12 {
            let url = URL(fileURLWithPath: "/proj/File\(i).java")
            _ = await cache.tree(for: document("class File\(i) { }", url: url))
        }
        let count = await cache.entryCount
        XCTAssertEqual(count, 8)
        let oldestKept = await cache.contains(URL(fileURLWithPath: "/proj/File0.java"))
        XCTAssertFalse(oldestKept, "oldest entries go first")
        let newestKept = await cache.contains(URL(fileURLWithPath: "/proj/File11.java"))
        XCTAssertTrue(newestKept)
    }

    func testCacheStaysWithinTheByteCap() async {
        let saved = DocumentParseCache.maxSourceBytes
        DocumentParseCache.maxSourceBytes = 200_000
        defer { DocumentParseCache.maxSourceBytes = saved }
        let cache = JavaDocumentParseCache()
        let blob = String(repeating: "int field\(12345); ", count: 4_000)
        let url0 = URL(fileURLWithPath: "/proj/Big0.java")
        _ = await cache.tree(for: document("class Big0 { \(blob) }", url: url0))
        let bytesAfterOne = await cache.cachedSourceBytes
        XCTAssertGreaterThan(bytesAfterOne, 0)
        for i in 1 ..< 8 {
            let url = URL(fileURLWithPath: "/proj/Big\(i).java")
            _ = await cache.tree(for: document("class Big\(i) { \(blob) }", url: url))
        }
        let bytes = await cache.cachedSourceBytes
        XCTAssertLessThanOrEqual(bytes, DocumentParseCache.maxSourceBytes)
        let firstSurvived = await cache.contains(url0)
        XCTAssertFalse(firstSurvived, "byte pressure evicts the oldest first")
    }

    func testAnOverCapSingleDocumentStaysCached() async {
        let saved = DocumentParseCache.maxSourceBytes
        DocumentParseCache.maxSourceBytes = 1_000
        defer { DocumentParseCache.maxSourceBytes = saved }
        let cache = JavaDocumentParseCache()
        let url = URL(fileURLWithPath: "/proj/Huge.java")
        _ = await cache.tree(for: document("class Huge { \(String(repeating: "int f;", count: 1_000)) }", url: url))
        let kept = await cache.contains(url)
        XCTAssertTrue(kept, "evicting the just-stored entry would re-parse it on every request")
    }

    func testInvalidateRemovesTheEntry() async {
        let cache = JavaDocumentParseCache()
        let url = URL(fileURLWithPath: "/proj/T.java")
        _ = await cache.tree(for: document("class T { }", url: url))
        let before = await cache.entryCount
        XCTAssertEqual(before, 1)
        await cache.invalidate(url)
        let count = await cache.entryCount
        let bytes = await cache.cachedSourceBytes
        let kept = await cache.contains(url)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(bytes, 0)
        XCTAssertFalse(kept)
    }

    func testInvalidateFindsUnstandardizedPaths() async {
        let cache = JavaDocumentParseCache()
        let raw = URL(fileURLWithPath: "/proj/sub/../T.java")
        _ = await cache.tree(for: document("class T { }", url: raw))
        let before = await cache.entryCount
        XCTAssertEqual(before, 1)
        await cache.invalidate(URL(fileURLWithPath: "/proj/T.java"))
        let count = await cache.entryCount
        XCTAssertEqual(count, 0, "both spellings address one entry")
    }

    func testInvalidateAllResetsByteAccounting() async {
        let cache = JavaDocumentParseCache()
        _ = await cache.tree(for: document("class T { }"))
        let before = await cache.cachedSourceBytes
        XCTAssertGreaterThan(before, 0)
        await cache.invalidateAll()
        let count = await cache.entryCount
        let bytes = await cache.cachedSourceBytes
        XCTAssertEqual(count, 0)
        XCTAssertEqual(bytes, 0)
    }
}
