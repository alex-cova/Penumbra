import XCTest
@testable import Penumbra

/// Edits that used to leave the edited lines drawn from a guess until the parse landed. Each case
/// runs with Focus Mode off and on (and Metal where the dimming is checked); see
/// `assertEditIsStable` for what must not change between the first frame and the settled one.
@MainActor
final class EditStabilityTests: XCTestCase {
    private let watched = ["Intro paragraph", "First section heading", "Tight paragraph", "Second section heading", "Final paragraph"]

    private func forEachMode(metal: Bool = false,
                             anchor: String,
                             _ body: (TextView, _ focusMode: Bool) throws -> Void) throws {
        for focusMode in [false, true] {
            let textView = try makeMarkdownProbeView(document: EditStabilityDocuments.readme,
                                                     metal: metal && focusMode,
                                                     focusMode: focusMode,
                                                     caretAfter: anchor)
            try body(textView, focusMode)
        }
    }

    // MARK: Forward delete and cut (item 3)

    func testForwardDeleteInsideTitle() throws {
        try forEachMode(metal: true, anchor: "## First") { textView, focusMode in
            assertEditIsStable("forward delete inside a title (focus \(focusMode))", in: textView,
                               watching: watched, focused: "Tight paragraph", unfocused: "Final paragraph") {
                pressForwardDelete(in: textView)
                pressForwardDelete(in: textView)
            }
        }
    }

    func testForwardDeleteAtEndOfTitleJoinsTheNextLine() throws {
        try forEachMode(metal: true, anchor: "## First section heading") { textView, focusMode in
            assertEditIsStable("forward delete joins the next line (focus \(focusMode))", in: textView,
                               watching: watched, focused: "Tight paragraph", unfocused: "Final paragraph") {
                pressForwardDelete(in: textView)
            }
        }
    }

    func testCutInsideTitle() throws {
        try forEachMode(metal: true, anchor: "## First") { textView, focusMode in
            select("section", in: textView)
            assertEditIsStable("cut inside a title (focus \(focusMode))", in: textView,
                               watching: watched, focused: "Tight paragraph", unfocused: "Final paragraph") {
                performCut(in: textView)
            }
        }
    }

    func testCutWholeHeadingLine() throws {
        try forEachMode(metal: true, anchor: "## First") { textView, focusMode in
            select("## First section heading\n", in: textView)
            assertEditIsStable("cut a whole heading line (focus \(focusMode))", in: textView,
                               watching: ["Intro paragraph", "Tight paragraph", "Second section heading", "Final paragraph"],
                               focused: "Tight paragraph", unfocused: "Final paragraph") {
                performCut(in: textView)
            }
        }
    }

    func testMultiCaretCut() throws {
        try forEachMode(anchor: "Intro") { textView, focusMode in
            let text = textView.text as NSString
            let first = text.range(of: "words")
            let second = text.range(of: "list item")
            textView.selectedRanges = [first, second]
            assertEditIsStable("multi-caret cut (focus \(focusMode))", in: textView, watching: watched) {
                performCut(in: textView)
            }
        }
    }

    // MARK: Focus Mode on other edit paths (item 4)

    func testMultiCaretTypingKeepsTheEditedParagraphsFocused() throws {
        try forEachMode(metal: true, anchor: "Intro") { textView, focusMode in
            let text = textView.text as NSString
            textView.selectedRanges = [NSRange(location: text.range(of: "words").upperBound, length: 0),
                                       NSRange(location: text.range(of: "Second").location, length: 0)]
            assertEditIsStable("multi-caret typing (focus \(focusMode))", in: textView,
                               watching: watched, focused: "Intro paragraph", unfocused: "Final paragraph") {
                textView.insertText("x")
            }
        }
    }

    func testUndoAndRedoOfTypingInATitle() throws {
        try forEachMode(metal: true, anchor: "## First section heading") { textView, focusMode in
            for character in " Z" {
                textView.insertText(String(character))
            }
            waitForParse(in: textView)
            assertEditIsStable("undo of typing in a title (focus \(focusMode))", in: textView,
                               watching: watched, focused: "Tight paragraph", unfocused: "Final paragraph") {
                textView.undoManager?.undo()
            }
            assertEditIsStable("redo of typing in a title (focus \(focusMode))", in: textView,
                               watching: watched, focused: "Tight paragraph", unfocused: "Final paragraph") {
                textView.undoManager?.redo()
            }
        }
    }

    func testReplaceAllKeepsFocusAndSizes() throws {
        try forEachMode(metal: true, anchor: "Intro paragraph") { textView, focusMode in
            let text = textView.text as NSString
            let replacements = ["words", "list"].map {
                BatchReplaceSet.Replacement(range: text.range(of: $0), text: $0.uppercased())
            }
            assertEditIsStable("Replace All (focus \(focusMode))", in: textView,
                               watching: watched, focused: "Intro paragraph", unfocused: "Final paragraph") {
                textView.replaceText(in: BatchReplaceSet(replacements: replacements))
            }
        }
    }
}
