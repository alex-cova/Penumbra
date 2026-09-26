@preconcurrency import AppKit
import XCTest
@testable import Penumbra

/// ⌘/⌥ arrow keys, Home/End and ⌥⌫ driven through real key events: Smart Home, line end before
/// trailing whitespace, document start/end, IntelliJ word stops, and multi-caret moves.
@MainActor
final class CaretNavigationKeyTests: XCTestCase {
    private typealias KeyCode = TestKeyCode

    // MARK: - ⌘←/→

    func testCommandLeftTogglesBetweenCodeStartAndColumnZero() {
        let textView = makeFocusedTextView(text: "a\n    foo()")
        textView.selectedRange = NSRange(location: 9, length: 0)

        send(keyEvent(keyCode: KeyCode.leftArrow, flags: .command), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 6, length: 0))
        send(keyEvent(keyCode: KeyCode.leftArrow, flags: .command), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 2, length: 0))
        send(keyEvent(keyCode: KeyCode.leftArrow, flags: .command), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 6, length: 0))
    }

    func testCommandRightStopsBeforeTrailingWhitespaceFirst() {
        let textView = makeFocusedTextView(text: "foo();   \nbar")
        textView.selectedRange = NSRange(location: 0, length: 0)

        send(keyEvent(keyCode: KeyCode.rightArrow, flags: .command), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 6, length: 0))
        send(keyEvent(keyCode: KeyCode.rightArrow, flags: .command), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 9, length: 0))
    }

    func testShiftCommandLeftExtendsToCodeStart() {
        let textView = makeFocusedTextView(text: "    foo()")
        textView.selectedRange = NSRange(location: 9, length: 0)

        send(keyEvent(keyCode: KeyCode.leftArrow, flags: [.shift, .command]), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 5))
    }

    func testSmartHomeCanBeTurnedOff() {
        let textView = makeFocusedTextView(text: "    foo()")
        textView.isSmartHomeEnabled = false
        textView.selectedRange = NSRange(location: 9, length: 0)

        send(keyEvent(keyCode: KeyCode.leftArrow, flags: .command), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 0))
    }

    func testHomeKeyUsesSmartHome() {
        let textView = makeFocusedTextView(text: "  x")
        textView.selectedRange = NSRange(location: 3, length: 0)

        send(keyEvent(keyCode: 0x73), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 2, length: 0))
    }

    // MARK: - ⌘↑/↓

    func testCommandUpAndDownGoToDocumentBoundaries() {
        let textView = makeFocusedTextView(text: "one\ntwo\nthree")
        textView.selectedRange = NSRange(location: 5, length: 0)

        send(keyEvent(keyCode: KeyCode.downArrow, flags: .command), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 13, length: 0))
        send(keyEvent(keyCode: KeyCode.upArrow, flags: .command), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 0))
    }

    func testShiftCommandDownSelectsToDocumentEnd() {
        let textView = makeFocusedTextView(text: "one\ntwo\nthree")
        textView.selectedRange = NSRange(location: 5, length: 0)

        send(keyEvent(keyCode: KeyCode.downArrow, flags: [.shift, .command]), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 5, length: 8))
    }

    // MARK: - ⌥←/→

    func testOptionRightStopsAtWordAndPunctuationEnds() {
        let textView = makeFocusedTextView(text: "list.stream()")
        textView.selectedRange = NSRange(location: 0, length: 0)

        var stops: [Int] = []
        for _ in 0..<4 {
            send(keyEvent(keyCode: KeyCode.rightArrow, flags: .option), to: textView)
            stops.append(textView.selectedRange.location)
        }
        XCTAssertEqual(stops, [4, 5, 11, 13])
    }

    func testOptionRightAtLineEndGoesToNextLineStart() {
        let textView = makeFocusedTextView(text: "ab\n  cd")
        textView.selectedRange = NSRange(location: 2, length: 0)

        send(keyEvent(keyCode: KeyCode.rightArrow, flags: .option), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 3, length: 0))
        send(keyEvent(keyCode: KeyCode.rightArrow, flags: .option), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 7, length: 0))
    }

    func testOptionLeftAtLineStartGoesToPreviousLineEnd() {
        let textView = makeFocusedTextView(text: "ab  \ncd")
        textView.selectedRange = NSRange(location: 5, length: 0)

        send(keyEvent(keyCode: KeyCode.leftArrow, flags: .option), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 0))
        send(keyEvent(keyCode: KeyCode.leftArrow, flags: .option), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 0))
    }

    func testCamelHumpsNavigation() {
        let textView = makeFocusedTextView(text: "getHTTPResponse")
        textView.isCamelHumpsNavigationEnabled = true
        textView.selectedRange = NSRange(location: 0, length: 0)

        send(keyEvent(keyCode: KeyCode.rightArrow, flags: .option), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 3, length: 0))
    }

    func testOptionRightMovesEveryCaretByWord() {
        let textView = makeFocusedTextView(text: "ab cd\nef gh")
        textView.selectedRanges = [NSRange(location: 0, length: 0), NSRange(location: 6, length: 0)]

        send(keyEvent(keyCode: KeyCode.rightArrow, flags: .option), to: textView)
        XCTAssertEqual(textView.selectedRanges, [NSRange(location: 2, length: 0), NSRange(location: 8, length: 0)])
    }

    func testCommandRightMovesEveryCaretToItsLineEnd() {
        let textView = makeFocusedTextView(text: "ab cd\nef gh")
        textView.selectedRanges = [NSRange(location: 0, length: 0), NSRange(location: 6, length: 0)]

        send(keyEvent(keyCode: KeyCode.rightArrow, flags: .command), to: textView)
        XCTAssertEqual(textView.selectedRanges, [NSRange(location: 5, length: 0), NSRange(location: 11, length: 0)])
    }

    // MARK: - ⌥⌫

    func testOptionDeleteRemovesToPreviousWordStart() {
        let textView = makeFocusedTextView(text: "foo.bar")
        textView.selectedRange = NSRange(location: 7, length: 0)

        send(keyEvent(keyCode: KeyCode.delete, flags: .option), to: textView)
        XCTAssertEqual(textView.text, "foo.")
        send(keyEvent(keyCode: KeyCode.delete, flags: .option), to: textView)
        XCTAssertEqual(textView.text, "foo")
    }
}
