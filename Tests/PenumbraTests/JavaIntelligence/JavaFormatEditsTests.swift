import XCTest
import EditorIntelligence
@testable import JavaIntelligence

final class JavaFormatEditsTests: XCTestCase {
    /// Applies edits the way the editor does: by line and column, last first.
    private func apply(_ edits: [TextEdit], to text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var offsets: [Int] = []
        var running = 0
        for line in lines { offsets.append(running); running += line.utf16.count + 1 }
        _ = lines
        var result = text as NSString
        for edit in edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            // Line/column must agree with the offset the edit reports.
            XCTAssertEqual(offsets[edit.range.start.line] + edit.range.start.column, edit.range.start.utf16Offset)
            XCTAssertEqual(offsets[edit.range.end.line] + edit.range.end.column, edit.range.end.utf16Offset)
            result = result.replacingCharacters(
                in: NSRange(location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset),
                with: edit.replacement
            ) as NSString
        }
        lines = []
        return result as String
    }

    func testChangedLinesBecomeMinimalPerLineEdits() {
        let old = "class A {\nint x;\n    int y;\n}\n"
        let new = "class A {\n    int x;\n    int y;\n}\n"
        let edits = JavaFormatEdits.edits(from: old, to: new)
        XCTAssertEqual(edits.count, 1)
        // Only the missing indentation is inserted, so a caret in the line moves with its text.
        XCTAssertEqual(edits[0].replacement, "    ")
        XCTAssertEqual(edits[0].range.start.utf16Offset, edits[0].range.end.utf16Offset)
        XCTAssertEqual(apply(edits, to: old), new)
    }

    func testTrailingWhitespaceIsRemovedFromTheEndOfALine() {
        let old = "a  \nb\n"
        let edits = JavaFormatEdits.edits(from: old, to: "a\nb\n")
        XCTAssertEqual(apply(edits, to: old), "a\nb\n")
        XCTAssertEqual(edits.first?.replacement, "")
    }

    func testCutBlankLinesBecomeOneBlockEdit() {
        let old = "a\n\n\n\n\nb\nc\n"
        let new = "a\n\n\nb\nc\n"
        let edits = JavaFormatEdits.edits(from: old, to: new)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(apply(edits, to: old), new)
    }

    func testDroppedTrailingBlankLinesAtTheEndOfTheFile() {
        let old = "a\n}\n\n\n"
        let new = "a\n}\n"
        XCTAssertEqual(apply(JavaFormatEdits.edits(from: old, to: new), to: old), new)
    }

    func testAddedFinalNewline() {
        let old = "a\n}"
        let new = "a\n}\n"
        XCTAssertEqual(apply(JavaFormatEdits.edits(from: old, to: new), to: old), new)
    }

    func testRestrictingToLinesLeavesTheRestAlone() {
        let old = "a\n  b\n  c\n  d\n"
        let new = "a\n    b\n    c\n    d\n"
        let edits = JavaFormatEdits.edits(from: old, to: new, lines: 1...2)
        XCTAssertEqual(apply(edits, to: old), "a\n    b\n    c\n  d\n")
    }

    func testRestrictingToLinesNeedsTheSameLineCount() {
        XCTAssertTrue(JavaFormatEdits.edits(from: "a\n\n\nb\n", to: "a\n\nb\n", lines: 0...1).isEmpty)
    }

    func testIdenticalTextsNeedNoEdits() {
        XCTAssertTrue(JavaFormatEdits.edits(from: "x\n", to: "x\n").isEmpty)
    }

    func testMultibyteTextKeepsUTF16Columns() {
        let old = "// café ☕\n  int x;\n"
        let new = "// café ☕\n    int x;\n"
        XCTAssertEqual(apply(JavaFormatEdits.edits(from: old, to: new), to: old), new)
    }
}
