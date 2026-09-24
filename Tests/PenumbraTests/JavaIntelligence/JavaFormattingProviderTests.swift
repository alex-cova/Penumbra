import XCTest
import EditorIntelligence
@testable import JavaIntelligence

final class JavaFormattingProviderTests: XCTestCase {
    private func document(_ text: String, language: String = "java") -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            displayName: "A.java", contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 10, height: 10),
            languageIdentifier: language
        )
    }

    private func apply(_ edits: [TextEdit], to text: String) -> String {
        var result = text as NSString
        for edit in edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            result = result.replacingCharacters(
                in: NSRange(location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset),
                with: edit.replacement
            ) as NSString
        }
        return result as String
    }

    private func range(of marker: String, in text: String, through end: String? = nil) -> EditorIntelligence.TextRange {
        let ns = text as NSString
        let start = ns.range(of: marker).location
        let stop = end.map { ns.range(of: $0).location + ($0 as NSString).length } ?? start
        return EditorIntelligence.TextRange(
            start: JavaNavigationText.position(utf16Offset: start, in: text),
            end: JavaNavigationText.position(utf16Offset: stop, in: text)
        )
    }

    func testFormatsAWholeJavaDocument() async {
        let provider = JavaFormattingProvider()
        let text = "class A{\nvoid m(){\nint x=1;\n}\n}\n"
        let edits = await provider.formatDocument(document(text))
        XCTAssertEqual(apply(edits, to: text), "class A {\n    void m() {\n        int x = 1;\n    }\n}\n")
    }

    func testAFormattedDocumentNeedsNoEdits() async {
        let provider = JavaFormattingProvider()
        let text = "class A {\n    int x;\n}\n"
        let edits = await provider.formatDocument(document(text))
        XCTAssertTrue(edits.isEmpty)
    }

    func testUsesTheConfiguredIndentUnitEachTime() async {
        let provider = JavaFormattingProvider()
        let text = "class A {\nint x;\n}\n"
        await provider.setIndentUnitProvider { "\t" }
        let tabbed = await provider.formatDocument(document(text))
        XCTAssertEqual(apply(tabbed, to: text), "class A {\n\tint x;\n}\n")
        await provider.setIndentUnitProvider { "  " }
        let two = await provider.formatDocument(document(text))
        XCTAssertEqual(apply(two, to: text), "class A {\n  int x;\n}\n")
    }

    func testSelectionFormatsOnlyTheSelectedLinesAndKeepsBlankLines() async {
        let provider = JavaFormattingProvider()
        let text = "class A {\nint a=1;\nint b=2;\n\n\n\nint c=3;\n}\n"
        let selection = range(of: "int b", in: text, through: "int b=2;")
        let edits = await provider.formatSelection(in: document(text), range: selection)
        XCTAssertEqual(apply(edits, to: text), "class A {\nint a=1;\n    int b = 2;\n\n\n\nint c=3;\n}\n")
    }

    func testSelectionEndingAtTheStartOfALineExcludesThatLine() async {
        let provider = JavaFormattingProvider()
        let text = "class A {\nint a=1;\nint b=2;\n}\n"
        let start = (text as NSString).range(of: "int a").location
        let end = (text as NSString).range(of: "int b").location
        let selection = EditorIntelligence.TextRange(
            start: JavaNavigationText.position(utf16Offset: start, in: text),
            end: JavaNavigationText.position(utf16Offset: end, in: text)
        )
        let edits = await provider.formatSelection(in: document(text), range: selection)
        XCTAssertEqual(apply(edits, to: text), "class A {\n    int a = 1;\nint b=2;\n}\n")
    }

    func testFilesThatDoNotParseAreLeftAlone() async {
        let provider = JavaFormattingProvider()
        let text = "class A { void m( { }\n"
        let whole = await provider.formatDocument(document(text))
        XCTAssertTrue(whole.isEmpty)
        let part = await provider.formatSelection(in: document(text), range: range(of: "class", in: text))
        XCTAssertTrue(part.isEmpty)
    }

    func testOnlyJavaDocumentsAreSupported() async {
        let provider = JavaFormattingProvider()
        XCTAssertTrue(provider.supportsFormatting(document("")))
        XCTAssertFalse(provider.supportsFormatting(document("", language: "swift")))
        let other = await provider.formatDocument(document("class A{}", language: "swift"))
        XCTAssertTrue(other.isEmpty)
    }
}
