import AppKit
import XCTest
@testable import Runestone

/// `GoToLinePaletteProvider` (the `:` sigil / ⌘G row) and the `TextView.goToLine(_:)` it calls.
@MainActor
final class GoToLinePaletteProviderTests: XCTestCase {
    func testParseAcceptsOneBasedLineNumbers() {
        XCTAssertEqual(GoToLinePaletteProvider.parse("1"), 1)
        XCTAssertEqual(GoToLinePaletteProvider.parse("  12  "), 12)
        XCTAssertEqual(GoToLinePaletteProvider.parse("3"), 3)
    }

    func testParseRejectsEmptyNonNumericAndNonPositive() {
        XCTAssertNil(GoToLinePaletteProvider.parse(""))
        XCTAssertNil(GoToLinePaletteProvider.parse("   "))
        XCTAssertNil(GoToLinePaletteProvider.parse("abc"))
        XCTAssertNil(GoToLinePaletteProvider.parse("1.5"))
        XCTAssertNil(GoToLinePaletteProvider.parse("0"))
        XCTAssertNil(GoToLinePaletteProvider.parse("-2"))
    }

    func testItemsIsEmptyForNonNumericQuery() async {
        let provider = GoToLinePaletteProvider(lineCount: { 10 }, onGoToLine: { _ in })
        let items = await provider.items(matching: "abc", limit: 10)
        XCTAssertTrue(items.isEmpty)
    }

    func testItemsOffersTheRequestedLineAndInvokesTheCallbackOnAction() async {
        var requested: Int?
        let provider = GoToLinePaletteProvider(lineCount: { 10 }, onGoToLine: { requested = $0 })
        let items = await provider.items(matching: "3", limit: 10)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Go to Line 3")
        XCTAssertNil(items.first?.subtitle)

        items.first?.action()
        XCTAssertEqual(requested, 3)
    }

    func testItemsClampsARequestPastTheLastLine() async {
        let provider = GoToLinePaletteProvider(lineCount: { 5 }, onGoToLine: { _ in })
        let items = await provider.items(matching: "99", limit: 10)
        XCTAssertEqual(items.first?.title, "Go to Line 5")
        XCTAssertNotNil(items.first?.subtitle, "A clamped request should say so")
    }

    func testTextViewGoToLineMovesTheCaretToTheZeroBasedLine() {
        let textView = makeTextView(text: "alpha\nbeta\ngamma\n")
        XCTAssertTrue(textView.goToLine(0))
        XCTAssertEqual(textView.textLocation(at: textView.selectedRange.location)?.lineNumber, 0)

        XCTAssertTrue(textView.goToLine(2))
        XCTAssertEqual(textView.textLocation(at: textView.selectedRange.location)?.lineNumber, 2)
        XCTAssertEqual(textView.selectedRange.length, 0)
    }

    func testTextViewGoToLineRejectsOutOfRangeWithoutCrashing() {
        let textView = makeTextView(text: "only\ntwo\n")
        let original = textView.selectedRange
        XCTAssertFalse(textView.goToLine(99))
        XCTAssertEqual(textView.selectedRange, original)
    }

    private func makeTextView(text: String) -> TextView {
        let textView = TextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        textView.setState(TextViewState(text: text, theme: DefaultTheme()))
        textView.layoutIfNeeded()
        return textView
    }
}
