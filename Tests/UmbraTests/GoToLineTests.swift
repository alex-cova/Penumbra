import AppKit
import Runestone
import XCTest
@testable import UmbraCore

final class GoToLineTests: XCTestCase {
    func testParseAcceptsOneBasedLineNumbers() {
        XCTAssertEqual(GoToLineCommand.parse("1"), 1)
        XCTAssertEqual(GoToLineCommand.parse("  12  "), 12)
        XCTAssertEqual(GoToLineCommand.parse("3"), 3)
    }

    func testParseRejectsEmptyNonNumericAndNonPositive() {
        XCTAssertNil(GoToLineCommand.parse(""))
        XCTAssertNil(GoToLineCommand.parse("   "))
        XCTAssertNil(GoToLineCommand.parse("abc"))
        XCTAssertNil(GoToLineCommand.parse("1.5"))
        XCTAssertNil(GoToLineCommand.parse("0"))
        XCTAssertNil(GoToLineCommand.parse("-2"))
    }

    @MainActor
    func testApplyMovesCaretToRequestedLine() {
        let textView = makeTextView(text: "alpha\nbeta\ngamma\n")
        XCTAssertTrue(GoToLineCommand.apply("1", to: textView))
        XCTAssertEqual(textView.textLocation(at: textView.selectedRange.location)?.lineNumber, 0)

        XCTAssertTrue(GoToLineCommand.apply("3", to: textView))
        XCTAssertEqual(textView.textLocation(at: textView.selectedRange.location)?.lineNumber, 2)
        XCTAssertEqual(textView.selectedRange.length, 0)
    }

    @MainActor
    func testApplyRejectsEmptyNonNumericAndOutOfRangeWithoutCrashing() {
        let textView = makeTextView(text: "only\ntwo\n")
        let original = textView.selectedRange

        XCTAssertFalse(GoToLineCommand.apply("", to: textView))
        XCTAssertEqual(textView.selectedRange, original)

        XCTAssertFalse(GoToLineCommand.apply("nope", to: textView))
        XCTAssertEqual(textView.selectedRange, original)

        XCTAssertFalse(GoToLineCommand.apply("99", to: textView))
        XCTAssertEqual(textView.selectedRange, original)
    }

    @MainActor
    func testApplyUsesTextViewGoToLine() {
        let textView = makeTextView(text: "a\nb\nc\nd\n")
        let lastLine = textView.lineCount
        XCTAssertTrue(GoToLineCommand.apply(String(lastLine), to: textView))
        XCTAssertEqual(
            textView.textLocation(at: textView.selectedRange.location)?.lineNumber,
            lastLine - 1
        )
    }

    @MainActor
    private func makeTextView(text: String) -> TextView {
        let textView = TextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        textView.setState(TextViewState(text: text, theme: DefaultTheme()))
        textView.layoutIfNeeded()
        return textView
    }
}
