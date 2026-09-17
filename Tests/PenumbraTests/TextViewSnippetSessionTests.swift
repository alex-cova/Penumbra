import AppKit
import XCTest
import EditorIntelligence
@testable import Penumbra

@MainActor
final class TextViewSnippetSessionTests: XCTestCase {
    func testTabCyclesNumberedStopsThenEndsAtFinal() {
        let textView = makeFocusedTextView(text: "")
        let expansion = SnippetEngine().expand(
            body: "func ${1:name}(${2:arg}) {\n$0\n}",
            context: SnippetExpansionContext()
        )
        textView.insertSnippet(expansion, replacing: NSRange(location: 0, length: 0))
        XCTAssertTrue(textView.hasActiveSnippetSession)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 5, length: 4))

        XCTAssertTrue(textView.advanceSnippetSession())
        XCTAssertTrue(textView.hasActiveSnippetSession)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 10, length: 3))

        XCTAssertTrue(textView.advanceSnippetSession())
        XCTAssertFalse(textView.hasActiveSnippetSession)
        XCTAssertEqual(textView.selectedRange, NSRange(location: expansion.finalCursorOffset ?? 0, length: 0))
    }

    func testTabKeyAdvancesSession() {
        let textView = makeFocusedTextView(text: "")
        let expansion = SnippetEngine().expand(
            body: "${1:one}${2:two}$0",
            context: SnippetExpansionContext()
        )
        textView.insertSnippet(expansion, replacing: NSRange(location: 0, length: 0))
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 3))
        send(keyEvent(keyCode: TestKeyCode.tab, characters: "\t"), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 3, length: 3))
        send(keyEvent(keyCode: TestKeyCode.tab, characters: "\t"), to: textView)
        XCTAssertFalse(textView.hasActiveSnippetSession)
    }

    func testShiftTabRetreats() {
        let textView = makeFocusedTextView(text: "")
        let expansion = SnippetEngine().expand(
            body: "${1:one}${2:two}",
            context: SnippetExpansionContext()
        )
        textView.insertSnippet(expansion, replacing: NSRange(location: 0, length: 0))
        XCTAssertTrue(textView.advanceSnippetSession())
        XCTAssertEqual(textView.selectedRange, NSRange(location: 3, length: 3))
        send(keyEvent(keyCode: TestKeyCode.tab, characters: "\t", flags: .shift), to: textView)
        XCTAssertTrue(textView.hasActiveSnippetSession)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 3))
    }

    func testEscapeCancelsSession() {
        let textView = makeFocusedTextView(text: "")
        let expansion = SnippetEngine().expand(body: "${1:name}$0", context: SnippetExpansionContext())
        textView.insertSnippet(expansion, replacing: NSRange(location: 0, length: 0))
        XCTAssertTrue(textView.hasActiveSnippetSession)
        send(keyEvent(keyCode: TestKeyCode.escape), to: textView)
        XCTAssertFalse(textView.hasActiveSnippetSession)
        XCTAssertEqual(textView.text, "name")
    }

    func testOnlyFinalStopDoesNotStartSession() {
        let textView = makeFocusedTextView(text: "value")
        textView.selectedRange = NSRange(location: 0, length: 5)
        textView.surroundSelection(with: SurroundTemplate(id: "p", title: "()", body: "(${TM_SELECTED_TEXT})$0"))
        XCTAssertFalse(textView.hasActiveSnippetSession)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 7, length: 0))
    }

    func testLinkedStopsSelectAsMultipleCarets() {
        let textView = makeFocusedTextView(text: "")
        let expansion = SnippetEngine().expand(body: "${1:x} + ${1:x}", context: SnippetExpansionContext())
        textView.insertSnippet(expansion, replacing: NSRange(location: 0, length: 0))
        XCTAssertTrue(textView.hasActiveSnippetSession)
        XCTAssertEqual(textView.selectedRanges.count, 2)
        XCTAssertEqual(textView.selectedRanges[0], NSRange(location: 0, length: 1))
        XCTAssertEqual(textView.selectedRanges[1], NSRange(location: 4, length: 1))
    }

    func testMovingCaretOutsideStopsEndsSession() {
        let textView = makeFocusedTextView(text: "")
        let expansion = SnippetEngine().expand(body: "aa${1:bb}cc", context: SnippetExpansionContext())
        textView.insertSnippet(expansion, replacing: NSRange(location: 0, length: 0))
        XCTAssertTrue(textView.hasActiveSnippetSession)
        textView.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertFalse(textView.hasActiveSnippetSession)
    }
}
