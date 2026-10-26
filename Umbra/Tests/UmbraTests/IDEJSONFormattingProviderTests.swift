import EditorIntelligence
import XCTest

@testable import Umbra

final class IDEJSONFormattingProviderTests: XCTestCase {
    private let provider = IDEJSONFormattingProvider(indentUnit: { "  " })

    private func document(_ text: String, language: String? = "json", selection: (Int, Int)? = nil) -> Document {
        let start = TextPosition(line: 0, column: 0, utf16Offset: selection?.0 ?? 0)
        let end = TextPosition(line: 0, column: 0, utf16Offset: selection?.1 ?? 0)
        return Document(
            id: DocumentID(),
            url: URL(fileURLWithPath: "/tmp/a.json"),
            displayName: "a.json",
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: start, end: end)),
            cursor: Cursor(position: start),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: language
        )
    }

    private func apply(_ edits: [TextEdit], to text: String) -> String {
        var result = text as NSString
        for edit in edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            let range = NSRange(location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset)
            result = result.replacingCharacters(in: range, with: edit.replacement) as NSString
        }
        return result as String
    }

    func testSupportsOnlyJSON() {
        XCTAssertTrue(provider.supportsFormatting(document("{}")))
        XCTAssertFalse(provider.supportsFormatting(document("{}", language: "java")))
    }

    func testFormatsWholeDocument() async {
        let text = #"{"a":1,"b":[true,null]}"#
        let edits = await provider.formatDocument(document(text))
        XCTAssertEqual(apply(edits, to: text), "{\n  \"a\": 1,\n  \"b\": [\n    true,\n    null\n  ]\n}")
    }

    func testInvalidJSONIsLeftAlone() async {
        let edits = await provider.formatDocument(document(#"{"a":"#))
        XCTAssertTrue(edits.isEmpty)
    }

    func testFormattedDocumentProducesNoEdits() async {
        let edits = await provider.formatDocument(document("{\n  \"a\": 1\n}"))
        XCTAssertTrue(edits.isEmpty)
    }

    func testFormatsSelectionKeepingLineIndent() async {
        let text = "{\n  \"a\": {\"b\":1}\n}"
        let start = (text as NSString).range(of: "{\"b\"").location
        let end = start + 7
        let doc = document(text, selection: (start, end))
        let edits = await provider.formatSelection(in: doc, range: doc.selection.range)
        XCTAssertEqual(apply(edits, to: text), "{\n  \"a\": {\n    \"b\": 1\n  }\n}")
    }
}
