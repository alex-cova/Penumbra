import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// A file-backed document whose snapshot carries no `text` (the adapter's open-document list, the
/// host's re-checks) is analysed from its full text. The parse cache answers nothing for it, and
/// that must never be published as a clean result.
final class JavaElidedDocumentInspectionTests: XCTestCase {
    func testAnElidedDocumentIsAnalysedFromItsFullText() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("java-elided-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let object = JavaSourceStubBuilder.build(source: "package java.lang; public class Object { }", url: scratch.appendingPathComponent("O.java")).classes
        let shard = scratch.appendingPathComponent("jdk.idx")
        try JavaIndexShardWriter().write(object, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: try JavaIndexShardReader(url: shard))])
        let service = JavaInspectionService(index: index, enabledRules: [.unresolvedType], idleDelay: .zero)

        let text = "package app;\nclass T { Missing m; }\n"
        let length = (text as NSString).length
        let reader = TextRangeReader(utf16Length: length) { offset, count in (text as NSString).substring(with: NSRange(location: offset, length: count)) }
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let elided = Document(
            url: scratch.appendingPathComponent("T.java"), displayName: "T.java",
            contentSnapshot: TextSnapshot(version: 3, utf16Length: length, text: nil, rangeReader: reader),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
        )
        XCTAssertTrue(elided.contentSnapshot.isElided)
        await service.analyzeNow(elided)
        let found = await service.diagnostics(for: elided).map(\.message)
        XCTAssertEqual(found, ["Cannot resolve type 'Missing'"])

        // The editor's own (materialized) document of the same text gets the same answer.
        let live = Document(
            url: elided.url, displayName: "T.java", contentSnapshot: TextSnapshot(version: 4, text: text),
            selection: elided.selection, cursor: elided.cursor, viewport: elided.viewport, languageIdentifier: "java"
        )
        let liveFound = await service.diagnostics(for: live).map(\.message)
        XCTAssertEqual(liveFound, ["Cannot resolve type 'Missing'"])
    }
}
