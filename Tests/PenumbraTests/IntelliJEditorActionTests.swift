import AppKit
import XCTest
@testable import Penumbra

/// Editor actions bound in the IntelliJ preset: Find Next/Previous, Move Caret to Matching Brace,
/// Unselect Last Occurrence, and the ⌥⌘↵ / ⇧↵ line inserts.
@MainActor
final class IntelliJEditorActionTests: XCTestCase {
    // MARK: Keymap

    func testIntelliJKeymapBindsTheNewActions() {
        let map = Keymap.intelliJ
        XCTAssertEqual(map.action(for: KeyStroke(KeyChord("g", .command))), .findNext)
        XCTAssertEqual(map.action(for: KeyStroke(KeyChord("g", [.command, .shift]))), .findPrevious)
        XCTAssertEqual(map.action(for: KeyStroke(KeyChord("m", .control))), .goToMatchingBracket)
        XCTAssertEqual(map.action(for: KeyStroke(KeyChord("g", [.control, .shift]))), .unselectLastOccurrence)
        XCTAssertEqual(map.action(for: KeyStroke(KeyChord(code: 0x24, [.command, .option]))), .insertLineAbove)
        XCTAssertEqual(map.action(for: KeyStroke(KeyChord(code: 0x24, .shift))), .startNewLine)
    }

    func testIntelliJKeymapFreesTheDefaultLineInsertKeys() {
        XCTAssertNil(Keymap.intelliJ.action(for: KeyStroke(KeyChord(code: 0x24, .command))))
        XCTAssertEqual(Keymap.intelliJ.action(for: KeyStroke(KeyChord(code: 0x24, [.command, .shift]))),
                       .completeStatement, "⇧⌘↵ is Complete Current Statement, not Insert Line Above")
        XCTAssertEqual(Keymap.default_.action(for: KeyStroke(KeyChord(code: 0x24, .command))), .insertLineBelow)
        XCTAssertEqual(Keymap.default_.action(for: KeyStroke(KeyChord(code: 0x24, [.command, .shift]))), .insertLineAbove)
    }

    func testOtherPresetsKeepTheirFindKeys() {
        XCTAssertEqual(Keymap.sublime.action(for: KeyStroke(KeyChord("g", .command))), .goToLine)
        XCTAssertNil(Keymap.default_.action(for: KeyStroke(KeyChord("g", .command))))
    }

    // MARK: Move Caret to Matching Brace

    func testMatchingBraceTogglesBetweenTheTwoEnds() {
        let textView = makeFocusedTextView(text: "foo(bar)")
        textView.selectedRange = NSRange(location: 8, length: 0)

        textView.perform(.goToMatchingBracket)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 0))

        textView.perform(.goToMatchingBracket)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 8, length: 0))
    }

    func testMatchingBraceMovesEveryCaret() {
        let textView = makeFocusedTextView(text: "(a) (b)")
        textView.selectedRanges = [NSRange(location: 3, length: 0), NSRange(location: 7, length: 0)]

        textView.perform(.goToMatchingBracket)

        XCTAssertEqual(textView.selectedRanges, [NSRange(location: 1, length: 0), NSRange(location: 5, length: 0)])
    }

    func testMatchingBraceCollapsesASelectionToItsTarget() {
        let textView = makeFocusedTextView(text: "foo(bar)")
        textView.selectedRange = NSRange(location: 4, length: 4) // "bar)" — ends right after )

        textView.perform(.goToMatchingBracket)

        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 0))
    }

    func testMatchingBraceWithNoBracketLeavesTheCaret() {
        let textView = makeFocusedTextView(text: "plain text")
        textView.selectedRange = NSRange(location: 3, length: 0)

        textView.perform(.goToMatchingBracket)

        XCTAssertEqual(textView.selectedRange, NSRange(location: 3, length: 0))
    }

    func testControlMRoutesToMatchingBraceUnderTheIntelliJKeymap() {
        let textView = makeFocusedTextView(text: "foo(bar)")
        textView.keymap = .intelliJ
        textView.selectedRange = NSRange(location: 8, length: 0)

        send(keyEvent(keyCode: 0x2E, characters: "m", flags: .control), to: textView)

        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 0))
    }

    // MARK: Unselect Last Occurrence

    func testUnselectLastOccurrenceDropsTheNewestSelection() {
        let textView = makeFocusedTextView(text: "foo foo foo")
        textView.selectedRange = NSRange(location: 1, length: 0)
        textView.perform(.selectNextOccurrence)  // word at caret
        textView.perform(.selectNextOccurrence)  // second foo
        textView.perform(.selectNextOccurrence)  // third foo
        XCTAssertEqual(textView.selectedRanges.count, 3)

        textView.perform(.unselectLastOccurrence)

        XCTAssertEqual(textView.selectedRanges.sorted { $0.location < $1.location },
                       [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)])
    }

    func testUnselectLastOccurrenceIsANoOpWithASingleSelection() {
        let textView = makeFocusedTextView(text: "foo foo")
        textView.selectedRange = NSRange(location: 0, length: 3)

        textView.perform(.unselectLastOccurrence)

        XCTAssertEqual(textView.selectedRanges, [NSRange(location: 0, length: 3)])
    }

    // MARK: Find Next / Previous through the text view

    func testFindNextWithNoQueryOpensTheFindPanel() {
        let textView = makeFocusedTextView(text: "a b a")
        XCTAssertFalse(textView.isFindPanelVisible)

        textView.perform(.findNext)

        XCTAssertTrue(textView.isFindPanelVisible)
    }

    func testCommandGRoutesToFindNextUnderTheIntelliJKeymap() {
        let textView = makeFocusedTextView(text: "a b a")
        textView.keymap = .intelliJ

        send(keyEvent(keyCode: 0x05, characters: "g", flags: .command), to: textView)

        XCTAssertTrue(textView.isFindPanelVisible)
    }

    // MARK: Line inserts

    func testOptionCommandReturnInsertsALineAboveUnderTheIntelliJKeymap() {
        let textView = makeFocusedTextView(text: "one\ntwo")
        textView.keymap = .intelliJ
        textView.selectedRange = NSRange(location: 5, length: 0)

        send(keyEvent(keyCode: 0x24, flags: [.command, .option]), to: textView)

        XCTAssertEqual(textView.text, "one\n\ntwo")
    }
}

extension IntelliJEditorActionTests {
    func testF2AndShiftF2StepThroughProblemsUnderTheIntelliJKeymap() {
        XCTAssertEqual(Keymap.intelliJ.action(for: KeyStroke(KeyChord(code: 0x78))), .goToNextProblem)
        XCTAssertEqual(Keymap.intelliJ.action(for: KeyStroke(KeyChord(code: 0x78, .shift))), .goToPreviousProblem)
        XCTAssertNil(Keymap.default_.action(for: KeyStroke(KeyChord(code: 0x78))))
    }

    func testProblemActionsFallThroughWhenTheHostDoesNotHandleThem() {
        // Core doesn't own the problem list, so without a host handler the key is not consumed.
        let textView = makeFocusedTextView(text: "a")
        XCTAssertFalse(textView.perform(.goToNextProblem))
    }

    func testTheHostHandlerReceivesTheProblemActions() {
        let textView = makeFocusedTextView(text: "a")
        var received: [EditorActionID] = []
        textView.editorActionHandler = { action in
            received.append(action)
            return true
        }
        XCTAssertTrue(textView.perform(.goToNextProblem))
        XCTAssertTrue(textView.perform(.goToPreviousProblem))
        XCTAssertEqual(received, [.goToNextProblem, .goToPreviousProblem])
    }
}
