import XCTest
import EditorIntelligence

final class SnippetEngineTests: XCTestCase {
    private let engine = SnippetEngine()

    func testSimpleTabStopsAndFinalCursor() {
        let body = "func ${1:name}(${2:arg}) {\n\t$0\n}"
        let expansion = engine.expand(body: body, context: SnippetExpansionContext())
        XCTAssertEqual(expansion.text, "func name(arg) {\n\t\n}")
        XCTAssertEqual(expansion.finalCursorOffset, 18)

        let byID = Dictionary(grouping: expansion.placeholders) { $0.id }
        XCTAssertEqual(byID[1]?.first?.startOffset, 5)
        XCTAssertEqual(byID[1]?.first?.length, 4)
        XCTAssertEqual(byID[2]?.first?.startOffset, 10)
        XCTAssertEqual(byID[2]?.first?.length, 3)
    }

    func testNestedPlaceholders() {
        let body = "${1:func ${2:arg}()}"
        let expansion = engine.expand(body: body, context: SnippetExpansionContext())
        XCTAssertEqual(expansion.text, "func arg()")

        let root = expansion.placeholders.first { $0.id == 1 }
        XCTAssertNotNil(root)
        XCTAssertEqual(root?.startOffset, 0)
        XCTAssertEqual(root?.length, 10)
        XCTAssertEqual(root?.children.first?.id, 2)

        let nested = expansion.placeholders.first { $0.id == 2 }
        XCTAssertNotNil(nested)
        XCTAssertEqual(nested?.startOffset, 5)
        XCTAssertEqual(nested?.length, 3)
    }

    func testVariables() {
        let context = SnippetExpansionContext(
            selectedText: "hello",
            currentLine: "let x = 1",
            currentWord: "x",
            filename: "Foo.swift",
            filenameBase: "Foo",
            lineIndex: 4,
            lineNumber: 5,
            softTab: "  "
        )
        let body = "$TM_SELECTED_TEXT $TM_FILENAME $TM_FILENAME_BASE $TM_LINE_NUMBER $TM_SOFT_TAB"
        let expansion = engine.expand(body: body, context: context)
        XCTAssertEqual(expansion.text, "hello Foo.swift Foo 5   ")
    }

    func testVariableDefault() {
        let context = SnippetExpansionContext(selectedText: "")
        let body = "${TM_SELECTED_TEXT:none}"
        let expansion = engine.expand(body: body, context: context)
        XCTAssertEqual(expansion.text, "none")
    }

    func testEscapedDollar() {
        let expansion = engine.expand(body: "$$1", context: SnippetExpansionContext())
        XCTAssertEqual(expansion.text, "$1")
    }

    func testTransformOnVariable() {
        let context = SnippetExpansionContext(filename: "Foo.swift")
        let body = "${TM_FILENAME/(.*)/prefix-$1/}"
        let expansion = engine.expand(body: body, context: context)
        XCTAssertEqual(expansion.text, "prefix-Foo.swift")
    }

    func testGlobalTransform() {
        let context = SnippetExpansionContext(currentWord: "abc")
        let body = "${TM_CURRENT_WORD/./X/g}"
        let expansion = engine.expand(body: body, context: context)
        XCTAssertEqual(expansion.text, "XXX")
    }
}
