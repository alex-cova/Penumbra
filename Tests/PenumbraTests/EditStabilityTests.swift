import PenumbraLanguages
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

    // MARK: Whole-line inserts and removals (item 1)

    private let coloredWatched = ["Quoted line"]

    func testDuplicateHeading() throws {
        try forEachMode(metal: true, anchor: "## First section heading") { textView, focusMode in
            assertEditIsStable("duplicate a title (focus \(focusMode))", in: textView,
                               watching: watched, focused: "Tight paragraph", unfocused: "Final paragraph", colored: coloredWatched) {
                textView.duplicateSelectedLines()
            }
        }
    }

    func testDuplicateHeadingAboveAnotherHeading() throws {
        for focusMode in [false, true] {
            let textView = try makeMarkdownProbeView(document: EditStabilityDocuments.adjacentTitles,
                                                     metal: focusMode, focusMode: focusMode, caretAfter: "# First title")
            assertEditIsStable("duplicate a title above a title (focus \(focusMode))", in: textView,
                               watching: ["Second title", "Third title", "Body paragraph"], colored: ["Second title"]) {
                textView.duplicateSelectedLines()
            }
        }
    }

    func testDuplicateBodyLineAboveAHeading() throws {
        for focusMode in [false, true] {
            let textView = try makeMarkdownProbeView(document: EditStabilityDocuments.readme,
                                                     metal: focusMode, focusMode: focusMode, caretAfter: "Intro paragraph")
            // The line below the inserted copy is blank here; put the caret where a title follows.
            textView.selectedRange = NSRange(location: (textView.text as NSString).range(of: "Tight paragraph").upperBound, length: 0)
            assertEditIsStable("duplicate the line under a title (focus \(focusMode))", in: textView,
                               watching: watched, colored: coloredWatched) {
                textView.duplicateSelectedLines()
            }
        }
    }

    /// The quote below the blank line is pushed into a new node by the copy; it must keep its color.
    func testDuplicateBlankLineAboveAColoredLine() throws {
        try forEachMode(metal: true, anchor: "Second list item\n") { textView, focusMode in
            assertEditIsStable("duplicate a blank line above a quote (focus \(focusMode))", in: textView,
                               watching: watched + ["Quoted line"], colored: coloredWatched + ["Second list item"]) {
                textView.duplicateSelectedLines()
            }
        }
    }

    func testMoveHeadingUp() throws {
        try forEachMode(metal: true, anchor: "## First section heading") { textView, focusMode in
            // The title lands directly under the intro paragraph, so that is the caret's paragraph.
            assertEditIsStable("move a title up (focus \(focusMode))", in: textView,
                               watching: watched, focused: "Intro paragraph", unfocused: "Final paragraph", colored: coloredWatched) {
                textView.moveSelectedLinesUp()
            }
        }
    }

    func testMoveHeadingDown() throws {
        try forEachMode(metal: true, anchor: "## First section heading") { textView, focusMode in
            assertEditIsStable("move a title down (focus \(focusMode))", in: textView,
                               watching: watched, focused: "Tight paragraph", unfocused: "Final paragraph", colored: coloredWatched) {
                textView.moveSelectedLinesDown()
            }
        }
    }

    func testTypingTheFirstHashOfANewTitle() throws {
        try forEachMode(metal: true, anchor: "Final paragraph") { textView, focusMode in
            let start = (textView.text as NSString).range(of: "Final paragraph").location
            textView.selectedRange = NSRange(location: start, length: 0)
            assertEditIsStable("type '# ' before a body line (focus \(focusMode))", in: textView,
                               watching: ["Second section heading", "Final paragraph"], colored: coloredWatched) {
                textView.insertText("#")
                textView.insertText(" ")
            }
        }
    }

    func testUndoOfADeletedHeadingLine() throws {
        try forEachMode(metal: true, anchor: "Intro") { textView, focusMode in
            select("## First section heading\n", in: textView)
            textView.deleteBackward()
            waitForParse(in: textView)
            assertEditIsStable("undo of a deleted title (focus \(focusMode))", in: textView,
                               watching: watched, focused: "Tight paragraph", unfocused: "Final paragraph", colored: coloredWatched) {
                textView.undoManager?.undo()
            }
        }
    }

    // MARK: A `#` that is not a heading

    /// `#` starts a comment in shell. A palette theme scales Markdown headings, so a `# comment`
    /// that is predicted to be a title would show up as a taller line.
    func testHashCommentsInShellAreNeverScaled() throws {
        let document = "# install the tool\necho one\n# another comment\necho two\n"
        for focusMode in [false, true] {
            let textView = try makeProbeView(document: document, language: .bash, focusMode: focusMode,
                                             caretAfter: "# install the tool")
            let text = textView.text as NSString
            let bodyHeight = textView.caretRect(at: text.range(of: "echo one").location).height
            let watchedLines = ["echo one", "another comment", "echo two"]
            assertEditIsStable("duplicate a shell comment (focus \(focusMode))", in: textView, watching: watchedLines) {
                textView.duplicateSelectedLines()
            }
            XCTAssertEqual(textView.caretRect(at: textView.selectedRange.location).height, bodyHeight, accuracy: 0.5,
                           "the copied comment was scaled like a title")

            let start = (textView.text as NSString).range(of: "echo two").location
            textView.selectedRange = NSRange(location: start, length: 0)
            assertEditIsStable("type '# ' before a shell line (focus \(focusMode))", in: textView, watching: watchedLines) {
                textView.insertText("#")
                textView.insertText(" ")
            }
            XCTAssertEqual(textView.caretRect(at: textView.selectedRange.location).height, bodyHeight, accuracy: 0.5,
                           "the typed '# ' scaled the line")
        }
    }
}
