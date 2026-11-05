import XCTest
import EditorIntelligence

/// F-15: LSP positions carry only a line-local character. Conversions with the source text
/// resolve the true global UTF-16 offset; without text the offset stays line-local.
final class LSPConversionTests: XCTestCase {
    func testTextPositionResolvesGlobalOffsetOnLaterLines() {
        let text = "ab\ncdef\n"
        let position = textPosition(from: LSPPosition(line: 1, character: 2), in: text)
        XCTAssertEqual(position.line, 1)
        XCTAssertEqual(position.column, 2)
        // "ab\n" is 3 units; line 1 starts at offset 3.
        XCTAssertEqual(position.utf16Offset, 5)
    }

    func testTextPositionOnFirstLineMatchesColumn() {
        let text = "ab\ncdef\n"
        let position = textPosition(from: LSPPosition(line: 0, character: 1), in: text)
        XCTAssertEqual(position.utf16Offset, 1)
    }

    func testTextRangeResolvesGlobalOffsets() {
        let text = "ab\ncdef\n"
        let range = textRange(
            from: LSPRange(start: LSPPosition(line: 1, character: 0), end: LSPPosition(line: 1, character: 4)),
            in: text
        )
        XCTAssertEqual(range.start.utf16Offset, 3)
        XCTAssertEqual(range.end.utf16Offset, 7)
    }

    func testDiagnosticConversionUsesGlobalOffsets() {
        let text = "ab\ncdef\n"
        let lsp = LSPDiagnostic(
            range: LSPRange(start: LSPPosition(line: 1, character: 1), end: LSPPosition(line: 1, character: 3)),
            severity: 1,
            message: "boom"
        )
        let converted = diagnostic(from: lsp, in: text, source: "test")
        XCTAssertEqual(converted.range.start.utf16Offset, 4)
        XCTAssertEqual(converted.range.end.utf16Offset, 6)
    }

    func testOutOfRangePositionsClamp() {
        let text = "ab\ncdef\n"
        XCTAssertEqual(textPosition(from: LSPPosition(line: 9, character: 0), in: text).utf16Offset, 8)
        // Column past the line end clamps to the line end (offset 7, the second newline).
        XCTAssertEqual(textPosition(from: LSPPosition(line: 1, character: 99), in: text).utf16Offset, 7)
    }

    func testCRLFLineEndings() {
        let text = "a\r\nbc"
        XCTAssertEqual(textPosition(from: LSPPosition(line: 1, character: 1), in: text).utf16Offset, 4)
    }

    func testMultibyteTextCountsUTF16Units() {
        // 😀 is two UTF-16 units; LSP columns are UTF-16, so line 1 starts at offset 3.
        let text = "😀\nxy"
        XCTAssertEqual(textPosition(from: LSPPosition(line: 1, character: 1), in: text).utf16Offset, 4)
    }

    func testCompletionAdditionalEditsUseGlobalOffsets() {
        let text = "ab\ncdef\n"
        let item = LSPCompletionItem(
            label: "x",
            additionalTextEdits: [
                LSPTextEdit(
                    range: LSPRange(start: LSPPosition(line: 1, character: 0), end: LSPPosition(line: 1, character: 1)),
                    newText: "C"
                )
            ]
        )
        let position = TextPosition(line: 1, column: 0, utf16Offset: 3)
        let converted = completionItem(
            from: item,
            source: "test",
            range: TextRange(start: position, end: position),
            in: text
        )
        XCTAssertEqual(converted.additionalEdits.count, 1)
        XCTAssertEqual(converted.additionalEdits.first?.range.start.utf16Offset, 3)
        XCTAssertEqual(converted.additionalEdits.first?.range.end.utf16Offset, 4)
    }
}
