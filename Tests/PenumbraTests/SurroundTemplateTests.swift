import AppKit
import XCTest
@testable import Penumbra

/// `SurroundTemplate` metadata + `TextView.surroundSelection(with:)` expansion / re-indentation.
@MainActor
final class SurroundTemplateTests: XCTestCase {
    func testAppliesToRespectsLanguageFilter() {
        let ifTemplate = SurroundTemplate.cFamily.first { $0.id == "if" }!
        XCTAssertTrue(ifTemplate.applies(to: "swift"))
        XCTAssertFalse(ifTemplate.applies(to: "python"))
        XCTAssertFalse(ifTemplate.applies(to: nil))

        let parens = SurroundTemplate.universal.first { $0.id == "parentheses" }!
        XCTAssertTrue(parens.applies(to: "python"))
        XCTAssertTrue(parens.applies(to: nil), "Universal templates apply everywhere")
    }

    func testApplicableSurroundTemplatesFiltersByLanguageIdentifier() {
        let textView = makeFocusedTextView(text: "x")
        textView.languageIdentifier = "python"
        let ids = Set(textView.applicableSurroundTemplates().map(\.id))
        XCTAssertTrue(ids.contains("parentheses"))
        XCTAssertTrue(ids.contains("pyIf"))
        XCTAssertFalse(ids.contains("if"), "C-family template excluded for python")
    }

    func testSurroundWrapsAndReindentsBlockBodyToTheAnchorLine() {
        let textView = makeFocusedTextView(text: "    doThing()")
        textView.selectedRange = NSRange(location: 4, length: 9) // "doThing()"
        // A space-based body so the assertion isn't muddied by tab/space mixing.
        let block = SurroundTemplate(id: "b", title: "{ }", body: "{\n  ${TM_SELECTED_TEXT}\n}$0")
        textView.surroundSelection(with: block)
        // Opening brace stays at the anchor indent; every continuation line is shifted by it.
        XCTAssertEqual(textView.text, "    {\n      doThing()\n    }")
    }

    func testSurroundPlacesCaretAtFinalStop() {
        let textView = makeFocusedTextView(text: "value")
        textView.selectedRange = NSRange(location: 0, length: 5)
        textView.surroundSelection(with: SurroundTemplate(id: "p", title: "()", body: "(${TM_SELECTED_TEXT})$0"))
        XCTAssertEqual(textView.text, "(value)")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 7, length: 0))
    }

    func testSurroundIsOneUndoStep() {
        let textView = makeFocusedTextView(text: "value")
        textView.selectedRange = NSRange(location: 0, length: 5)
        textView.surroundSelection(with: SurroundTemplate(id: "p", title: "()", body: "(${TM_SELECTED_TEXT})"))
        XCTAssertEqual(textView.text, "(value)")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.text, "value")
    }
}
