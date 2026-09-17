@preconcurrency import AppKit
import XCTest
@testable import Penumbra

/// Shared setup for building a real, laid-out, focused `TextView` in a window and driving
/// keyboard input into it via synthesized `NSEvent`s — the setup used across the multi-cursor,
/// block-selection, and keyboard-selection test suites. Extracted from what
/// `MultiSelectionTests`/`TextViewKeyboardSelectionTests` each used to duplicate verbatim.
extension XCTestCase {
    @MainActor
    func makeFocusedTextView(text: String,
                             isEditable: Bool = true,
                             file: StaticString = #filePath,
                             line: UInt = #line) -> TextView {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.isEditable = isEditable
        textView.isSelectable = true
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        textView.setState(TextViewState(text: text, theme: DefaultTheme()))
        // A real window always lays the view out before the user can type into it; do the same
        // here so line-fragment-dependent boundary math (Home/End, block selection, ⌘←/→) isn't
        // operating on unlaid-out (zero-length) line fragments.
        textView.layoutIfNeeded()
        XCTAssertTrue(textView.focusTextInput(), "focusTextInput() should install first responder", file: file, line: line)
        return textView
    }

    func keyEvent(keyCode: UInt16, characters: String = "", flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    @MainActor
    func send(_ event: NSEvent, to textView: TextView) {
        textView.window?.sendEvent(event)
    }
}

/// ANSI USB virtual keycodes used by the keyboard-driven selection/multi-cursor tests.
enum TestKeyCode {
    static let leftArrow: UInt16 = 0x7B
    static let rightArrow: UInt16 = 0x7C
    static let downArrow: UInt16 = 0x7D
    static let upArrow: UInt16 = 0x7E
    static let escape: UInt16 = 0x35
    static let delete: UInt16 = 0x33
    static let letterA: UInt16 = 0x00
    static let letterD: UInt16 = 0x02
    static let letterK: UInt16 = 0x28
    static let letterL: UInt16 = 0x25
    static let letterU: UInt16 = 0x20
    static let returnKey: UInt16 = 0x24
    static let letterB: UInt16 = 0x0B
    static let letterG: UInt16 = 0x05
    static let letterJ: UInt16 = 0x26
    static let letterT: UInt16 = 0x11
    static let letterE: UInt16 = 0x0E
    static let letterO: UInt16 = 0x1F
    static let tab: UInt16 = 0x30
    static let digit8: UInt16 = 0x1C
    static let leftBracket: UInt16 = 0x21
    static let rightBracket: UInt16 = 0x1E
}
