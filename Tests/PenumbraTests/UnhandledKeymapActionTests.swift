import AppKit
import XCTest
@testable import Penumbra

/// A key bound to an action that nothing handles is swallowed (it must not become text), and
/// `onUnhandledKeymapAction` is the trace of it (F21: "silently swallowing unhandled keys").
@MainActor
final class UnhandledKeymapActionTests: XCTestCase {
    private func makeFocusedTextView(text: String) -> TextView {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.isEditable = true
        textView.isSelectable = true
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        textView.setState(TextViewState(text: text, theme: DefaultTheme()))
        textView.layoutIfNeeded()
        XCTAssertTrue(textView.focusTextInput())
        addTeardownBlock { window.close() }
        return textView
    }

    /// ⌃⌥⇧F9, a key nothing else uses; `characters` are what it would type.
    private func event(_ characters: String = "q", keyCode: UInt16 = 0x65) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control, .option, .shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!
    }

    func testABoundKeyNothingHandlesIsReportedAndStillNotTyped() {
        let textView = makeFocusedTextView(text: "hello")
        let key = event()
        textView.keymap = Keymap(bindings: [KeyStroke(KeyChord(event: key)): .rename])
        var reported: [EditorActionID] = []
        textView.onUnhandledKeymapAction = { reported.append($0) }

        textView.window?.sendEvent(key)

        XCTAssertEqual(reported, [.rename])
        XCTAssertEqual(textView.text, "hello", "the key is swallowed, not typed")
    }

    func testAHandledActionIsNotReported() {
        let textView = makeFocusedTextView(text: "hello")
        let key = event()
        textView.keymap = Keymap(bindings: [KeyStroke(KeyChord(event: key)): .rename])
        var handled: [EditorActionID] = []
        var reported: [EditorActionID] = []
        textView.editorActionHandler = { action in handled.append(action); return true }
        textView.onUnhandledKeymapAction = { reported.append($0) }

        textView.window?.sendEvent(key)

        XCTAssertEqual(handled, [.rename])
        XCTAssertTrue(reported.isEmpty)
    }

    func testAnUnboundKeyIsNotReported() {
        let textView = makeFocusedTextView(text: "hello")
        textView.keymap = Keymap(bindings: [:])
        var reported: [EditorActionID] = []
        textView.onUnhandledKeymapAction = { reported.append($0) }

        let key = event()
        textView.window?.sendEvent(key)

        XCTAssertTrue(reported.isEmpty, "an unbound key is not an unhandled action")
    }
}
