import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaDocumentParseCacheTests: XCTestCase {
    private func document(_ source: String, version: Int = 0) -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            url: URL(fileURLWithPath: "/proj/T.java"),
            displayName: "T.java",
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
}
