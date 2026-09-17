import AppKit
import XCTest
@testable import Penumbra

/// Sticky column (block) selection mode: ⌘⇧8 keeps the rectangle alive across ordinary
/// selection assignment and grows it with plain arrows until toggled off.
@MainActor
final class ColumnSelectionModeTests: XCTestCase {
    func testToggleTurnsModeOnAndOff() {
        let textView = makeFocusedTextView(text: "aaaa\nbbbb\ncccc")
        textView.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertFalse(textView.isColumnSelectionModeEnabled)

        textView.toggleColumnSelectionMode()
        XCTAssertTrue(textView.isColumnSelectionModeEnabled)
        XCTAssertTrue(textView.isBlockSelectionActive)

        textView.toggleColumnSelectionMode()
        XCTAssertFalse(textView.isColumnSelectionModeEnabled)
        XCTAssertFalse(textView.isBlockSelectionActive)
    }

    func testRectangleSurvivesOrdinarySelectionAssignment() {
        let textView = makeFocusedTextView(text: "aaaa\nbbbb\ncccc")
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.toggleColumnSelectionMode()
        XCTAssertTrue(textView.isBlockSelectionActive)

        // Without sticky mode this assignment would call blockSelectionController.end().
        textView.selectedRange = NSRange(location: 2, length: 0)
        XCTAssertTrue(textView.isBlockSelectionActive, "Sticky mode keeps the rectangle")
        XCTAssertTrue(textView.isColumnSelectionModeEnabled)
    }

    func testEscapeExitsMode() {
        let textView = makeFocusedTextView(text: "aaaa\nbbbb")
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.toggleColumnSelectionMode()
        send(keyEvent(keyCode: TestKeyCode.escape), to: textView)
        XCTAssertFalse(textView.isBlockSelectionActive)
        XCTAssertFalse(textView.isColumnSelectionModeEnabled)
    }

    func testArrowKeysGrowTheRectangleInStickyMode() {
        let textView = makeFocusedTextView(text: "aaaa\nbbbb\ncccc")
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.toggleColumnSelectionMode()

        send(keyEvent(keyCode: TestKeyCode.downArrow, flags: []), to: textView)
        send(keyEvent(keyCode: TestKeyCode.downArrow, flags: []), to: textView)
        XCTAssertTrue(textView.isBlockSelectionActive)
        XCTAssertGreaterThanOrEqual(textView.selectedRanges.count, 2, "One caret per covered row")
    }
}
