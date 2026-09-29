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

    // MARK: - Multi-caret selection extension

    func testOptionShiftRightSelectsAWordAtEveryCaretAndShrinksBack() {
        let textView = makeFocusedTextView(text: "ab cd\nef gh")
        textView.selectedRanges = [NSRange(location: 0, length: 0), NSRange(location: 6, length: 0)]

        send(keyEvent(keyCode: KeyCode.rightArrow, flags: [.option, .shift]), to: textView)
        XCTAssertEqual(textView.selectedRanges, [NSRange(location: 0, length: 2), NSRange(location: 6, length: 2)])

        send(keyEvent(keyCode: KeyCode.leftArrow, flags: [.option, .shift]), to: textView)
        XCTAssertEqual(textView.selectedRanges, [NSRange(location: 0, length: 0), NSRange(location: 6, length: 0)])
    }

    func testShiftRightExtendsEverySelectionFromItsOwnAnchor() {
        let textView = makeFocusedTextView(text: "abcdef\nghijkl")
        textView.selectedRanges = [NSRange(location: 2, length: 0), NSRange(location: 9, length: 0)]

        send(keyEvent(keyCode: KeyCode.rightArrow, flags: .shift), to: textView)
        send(keyEvent(keyCode: KeyCode.rightArrow, flags: .shift), to: textView)
        XCTAssertEqual(textView.selectedRanges, [NSRange(location: 2, length: 2), NSRange(location: 9, length: 2)])

        // Backwards past the anchor flips the selection to the other side.
        for _ in 0..<3 {
            send(keyEvent(keyCode: KeyCode.leftArrow, flags: .shift), to: textView)
        }
        XCTAssertEqual(textView.selectedRanges, [NSRange(location: 1, length: 1), NSRange(location: 8, length: 1)])
    }

    func testCommandShiftRightSelectsToEveryLineEndAndTypingReplacesAll() {
        let textView = makeFocusedTextView(text: "ab cd\nef gh")
        textView.selectedRanges = [NSRange(location: 0, length: 0), NSRange(location: 6, length: 0)]

        send(keyEvent(keyCode: KeyCode.rightArrow, flags: [.command, .shift]), to: textView)
        XCTAssertEqual(textView.selectedRanges, [NSRange(location: 0, length: 5), NSRange(location: 6, length: 5)])
        textView.insertText("X")
        XCTAssertEqual(textView.text as String, "X\nX")
    }

    func testShiftEndExtendsEveryCaretToItsLineEnd() {
        let textView = makeFocusedTextView(text: "ab cd\nef gh")
        textView.selectedRanges = [NSRange(location: 1, length: 0), NSRange(location: 7, length: 0)]

        send(keyEvent(keyCode: 0x77, flags: .shift), to: textView)
        XCTAssertEqual(textView.selectedRanges, [NSRange(location: 1, length: 4), NSRange(location: 7, length: 4)])
    }

    func testEndMovesEveryCaretToItsLineEnd() {
        let textView = makeFocusedTextView(text: "ab cd\nef gh")
        textView.selectedRanges = [NSRange(location: 1, length: 0), NSRange(location: 7, length: 0)]

        send(keyEvent(keyCode: 0x77), to: textView)
        XCTAssertEqual(textView.selectedRanges, [NSRange(location: 5, length: 0), NSRange(location: 11, length: 0)])
    }

    func testShiftRightMergesSelectionsThatGrowIntoEachOther() {
        let textView = makeFocusedTextView(text: "abcd")
        textView.selectedRanges = [NSRange(location: 0, length: 0), NSRange(location: 2, length: 0)]

        send(keyEvent(keyCode: KeyCode.rightArrow, flags: .shift), to: textView)
        send(keyEvent(keyCode: KeyCode.rightArrow, flags: .shift), to: textView)
        XCTAssertEqual(textView.selectedRanges, [NSRange(location: 0, length: 4)])
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
