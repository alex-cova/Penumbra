import AppKit
import XCTest
@testable import Penumbra

/// While a find/replace field is being edited the window's field editor is first responder, so
/// Escape and Return arrive as commands on the field's delegate, not as `keyDown` on the field.
@MainActor
final class FindPanelEscapeTests: XCTestCase {
    func testCancelOperationInFindFieldClosesTheBar() {
        let bar = FindPanelBarView()
        var closed = 0
        bar.onClose = { closed += 1 }

        let handled = bar.control(bar.findField, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))

        XCTAssertTrue(handled)
        XCTAssertEqual(closed, 1)
    }

    func testCancelOperationInReplaceFieldClosesTheBar() {
        let bar = FindPanelBarView()
        var closed = 0
        bar.onClose = { closed += 1 }

        let handled = bar.control(bar.replaceField, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))

        XCTAssertTrue(handled)
        XCTAssertEqual(closed, 1)
    }

    func testReturnInFindFieldSelectsNextMatch() {
        let bar = FindPanelBarView()
        var next = 0
        bar.onNext = { next += 1 }

        let handled = bar.control(bar.findField, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertTrue(handled)
        XCTAssertEqual(next, 1)
    }

    func testFieldsUseTheBarAsDelegate() {
        let bar = FindPanelBarView()
        XCTAssertTrue(bar.findField.delegate === bar)
        XCTAssertTrue(bar.replaceField.delegate === bar)
    }
}
