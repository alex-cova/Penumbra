import AppKit
import XCTest
@testable import Penumbra

/// Deleting a selection leaves a caret, and nothing keeps describing the deleted text.
@MainActor
final class DeleteSelectionCollapseTests: XCTestCase {
    private static let request = "GET https://api.sicarx.com/stock/v1/medications?sku=7501125103049"

    private func makeView(text: String, language: TreeSitterLanguage) -> TextView {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        textView.isEditable = true
        textView.isSelectable = true
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        textView.setState(TextViewState(text: text, theme: DefaultTheme(), language: language))
        textView.layoutIfNeeded()
        XCTAssertTrue(textView.focusTextInput())
        return textView
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    private func occurrenceRanges(_ textView: TextView) -> [NSRange] {
        textView.emphasisManager.getEmphases(for: EmphasisGroup.occurrences).map(\.range)
    }

    func testDeletingSelectedMethodCollapsesToCaret() async throws {
        let language = try XCTUnwrap(TreeSitterLanguage.bundled(forIdentifier: "http"))
        let text = Self.request + "\nAccept: application/json\n"
        let textView = makeView(text: text, language: language)
        try await settle()

        textView.selectedRange = NSRange(location: 0, length: 3)
        send(keyEvent(keyCode: TestKeyCode.delete), to: textView)
        XCTAssertEqual(textView.text as String, String(text.dropFirst(3)))
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 0))
        XCTAssertTrue(textView.selectionRectsForTesting.isEmpty)

        try await settle()
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 0))
        XCTAssertTrue(textView.selectionRectsForTesting.isEmpty)
    }

    func testDeletingSelectionDropsOccurrenceHighlightsOfTheDeletedText() async throws {
        let language = try XCTUnwrap(TreeSitterLanguage.bundled(forIdentifier: "http"))
        let text = Self.request + "\n\n###\n" + Self.request + "\n\n###\nGET https://api.sicarx.com/other\n"
        let textView = makeView(text: text, language: language)
        textView.highlightsOccurrencesOfSelection = true
        try await settle()

        textView.selectedRange = NSRange(location: 0, length: 3)
        try await settle()
        XCTAssertEqual(occurrenceRanges(textView).count, 3, "precondition: every GET is highlighted")

        send(keyEvent(keyCode: TestKeyCode.delete), to: textView)
        try await settle()
        XCTAssertEqual(occurrenceRanges(textView), [], "the caret no longer sits on GET")
    }
}
