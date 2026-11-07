import AppKit
import EditorIntelligence
import XCTest
@testable import Penumbra

/// Escape that the editor itself does not consume (no block selection, extra carets or snippet)
/// is offered to the host so a covering tool window can take the keyboard back.
@MainActor
final class UnhandledEscapeTests: XCTestCase {
    func testEscapeWithNothingToCancelIsOfferedToTheHost() {
        let textView = makeFocusedTextView(text: "hello")
        var offered = 0
        textView.onUnhandledEscape = {
            offered += 1
            return true
        }

        send(keyEvent(keyCode: TestKeyCode.escape), to: textView)

        XCTAssertEqual(offered, 1)
        XCTAssertEqual(textView.text, "hello")
    }

    func testEscapeCancelsASnippetBeforeTheHostSeesIt() {
        let textView = makeFocusedTextView(text: "")
        var offered = 0
        textView.onUnhandledEscape = {
            offered += 1
            return true
        }
        let expansion = SnippetEngine().expand(body: "${1:name}$0", context: SnippetExpansionContext())
        textView.insertSnippet(expansion, replacing: NSRange(location: 0, length: 0))
        XCTAssertTrue(textView.hasActiveSnippetSession)

        send(keyEvent(keyCode: TestKeyCode.escape), to: textView)

        XCTAssertFalse(textView.hasActiveSnippetSession)
        XCTAssertEqual(offered, 0)
    }

    func testHostDecliningEscapeDoesNotInsertText() {
        let textView = makeFocusedTextView(text: "hello")
        textView.onUnhandledEscape = { false }

        send(keyEvent(keyCode: TestKeyCode.escape), to: textView)

        XCTAssertEqual(textView.text, "hello")
    }
}
