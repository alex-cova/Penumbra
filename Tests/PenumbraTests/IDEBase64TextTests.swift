import AppKit
import Penumbra
import XCTest

@testable import Umbra

final class IDEBase64TextTests: XCTestCase {
    func testRoundTrip() {
        for text in ["hello", "héllo wörld 🎉 日本語", "line one\nline two\n"] {
            XCTAssertEqual(IDEBase64Text.decode(IDEBase64Text.encode(text)), text)
        }
        XCTAssertEqual(IDEBase64Text.encode("hello"), "aGVsbG8=")
    }

    func testDecodeIsLenient() {
        XCTAssertEqual(IDEBase64Text.decode("aGVs\nbG8="), "hello")
        XCTAssertEqual(IDEBase64Text.decode("aGVsbG8"), "hello")
        // "??>" encodes to "Pz8+" in the standard alphabet and "Pz8-" in the URL-safe one.
        XCTAssertEqual(IDEBase64Text.decode("Pz8-"), "??>")
    }

    func testDecodeRejectsInvalidInput() {
        XCTAssertNil(IDEBase64Text.decode("not base64!"))
        XCTAssertNil(IDEBase64Text.decode(""))
        XCTAssertNil(IDEBase64Text.decode("/w=="), "0xFF is not UTF-8")
    }
}

@MainActor
final class IDEBase64MenuTests: XCTestCase {
    private var window: NSWindow!

    private func makeTextView(_ text: String) -> TextView {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        textView.theme = DefaultTheme()
        textView.text = text
        window.contentView = textView
        return textView
    }

    private func toolsItem(_ title: String, in items: [NSMenuItem]) throws -> NSMenuItem {
        let tools = try XCTUnwrap(items.first { $0.title == "Tools" })
        return try XCTUnwrap(tools.submenu?.items.first { $0.title == title })
    }

    private func fire(_ item: NSMenuItem) throws {
        let action = try XCTUnwrap(item.action)
        NSApp.sendAction(action, to: item.target, from: item)
    }

    func testNoToolsMenuWithoutSelection() {
        let textView = makeTextView("hello")
        textView.selectedRange = NSRange(location: 2, length: 0)
        let items = IDEWorkspace().textToolsContextMenuItems(
            context: EditorContextMenuContext(location: 2, selectedRange: nil), textView: textView)
        XCTAssertTrue(items.isEmpty)
    }

    func testEncodeAndDecodeEverySelectionInOneUndoStep() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        let textView = makeTextView("one two three")
        textView.selectedRanges = [NSRange(location: 0, length: 3), NSRange(location: 8, length: 5)]
        let workspace = IDEWorkspace()
        let context = EditorContextMenuContext(location: 0, selectedRange: NSRange(location: 0, length: 3))

        try fire(toolsItem("Encode Base64", in: workspace.textToolsContextMenuItems(context: context, textView: textView)))
        XCTAssertEqual(textView.text, "b25l two dGhyZWU=")
        XCTAssertEqual(textView.selectedRanges, [NSRange(location: 0, length: 4), NSRange(location: 9, length: 8)])

        try fire(toolsItem("Decode Base64", in: workspace.textToolsContextMenuItems(context: context, textView: textView)))
        XCTAssertEqual(textView.text, "one two three")

        textView.undoManager?.undo()
        XCTAssertEqual(textView.text, "b25l two dGhyZWU=")
    }

    func testInvalidBase64ChangesNothing() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        let textView = makeTextView("not base64!")
        textView.selectedRange = NSRange(location: 0, length: 11)
        let context = EditorContextMenuContext(location: 0, selectedRange: textView.selectedRange)
        try fire(toolsItem("Decode Base64", in: IDEWorkspace().textToolsContextMenuItems(context: context, textView: textView)))
        XCTAssertEqual(textView.text, "not base64!")
    }
}
