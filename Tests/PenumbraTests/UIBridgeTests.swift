import XCTest
import EditorIntelligence

final class UIBridgeTests: XCTestCase {
    func testCompletionPanelModel() {
        let range = makeRange(line: 0, startColumn: 0, endColumn: 2)
        let item = CompletionItem(label: "foo", insertText: "foo", kind: .function, range: range, source: "Test")
        let model = CompletionPanelModel(items: [item], replacementRange: range)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertNil(model.selectedIndex)
    }

    func testHoverWindowModel() {
        let range = makeRange(line: 0, startColumn: 0, endColumn: 3)
        let model = HoverWindowModel(contents: "Hello", anchorRange: range)
        XCTAssertEqual(model.contents, "Hello")
        XCTAssertTrue(model.isMarkdown)
    }

    func testGhostTextModel() {
        let position = TextPosition(line: 0, column: 5, utf16Offset: 5)
        let model = GhostTextModel(text: "world", anchorPosition: position)
        XCTAssertEqual(model.text, "world")
        XCTAssertEqual(model.anchorPosition.utf16Offset, 5)
    }

    func testParameterHintsModel() {
        let model = ParameterHintsModel(
            signatures: ["foo(_ a: Int)", "bar(_ b: String)"],
            activeSignature: 1,
            activeParameter: 0
        )
        XCTAssertEqual(model.activeSignature, 1)
        XCTAssertEqual(model.signatures.count, 2)
    }
}

private func makeRange(line: Int, startColumn: Int, endColumn: Int) -> EditorIntelligence.TextRange {
    EditorIntelligence.TextRange(
        start: TextPosition(line: line, column: startColumn, utf16Offset: startColumn),
        end: TextPosition(line: line, column: endColumn, utf16Offset: endColumn)
    )
}