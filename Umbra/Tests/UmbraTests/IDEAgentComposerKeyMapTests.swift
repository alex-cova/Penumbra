import AppKit
import XCTest

@testable import Umbra

final class IDEAgentComposerKeyMapTests: XCTestCase {
    private typealias Keys = IDEAgentComposerKeyMap.KeyCode

    private func action(
        _ key: UInt16, _ modifiers: NSEvent.ModifierFlags = [], suggestions: Bool = false, first: Bool = true,
        last: Bool = true, marked: Bool = false, empty: Bool = true
    ) -> IDEAgentComposerAction {
        IDEAgentComposerKeyMap.action(
            keyCode: key, modifiers: modifiers,
            context: .init(
                suggestionsVisible: suggestions, caretOnFirstLine: first, caretOnLastLine: last, hasMarkedText: marked,
                selectionIsEmpty: empty))
    }

    func testReturnSendsAndShiftOrOptionReturnInsertsANewline() {
        XCTAssertEqual(action(Keys.returnKey), .send)
        XCTAssertEqual(action(Keys.keypadEnter), .send)
        XCTAssertEqual(action(Keys.returnKey, .shift), .newline)
        XCTAssertEqual(action(Keys.returnKey, .option), .newline)
        XCTAssertEqual(action(Keys.returnKey, .command), .passThrough, "⌘↩ stays with the approval card shortcut")
    }

    func testReturnAndTabAcceptTheHighlightedSuggestion() {
        XCTAssertEqual(action(Keys.returnKey, suggestions: true), .acceptSuggestion)
        XCTAssertEqual(action(Keys.tab, suggestions: true), .acceptSuggestion)
        XCTAssertEqual(action(Keys.tab), .passThrough, "Tab without a list is left to the field")
    }

    func testShiftTabCyclesTheModeWhetherOrNotAListIsOpen() {
        XCTAssertEqual(action(Keys.tab, .shift), .cycleMode)
        XCTAssertEqual(action(Keys.tab, .shift, suggestions: true), .cycleMode)
    }

    func testEscapeClosesTheListFirstAndThenStopsTheRun() {
        XCTAssertEqual(action(Keys.escape, suggestions: true), .dismissSuggestions)
        XCTAssertEqual(action(Keys.escape), .stop)
    }

    func testArrowsMoveTheListWhileItIsOpen() {
        XCTAssertEqual(action(Keys.upArrow, suggestions: true, first: false), .previousSuggestion)
        XCTAssertEqual(action(Keys.downArrow, suggestions: true, last: false), .nextSuggestion)
    }

    func testArrowsWalkPromptHistoryOnlyAtTheEdgesOfTheText() {
        XCTAssertEqual(action(Keys.upArrow), .historyPrevious)
        XCTAssertEqual(action(Keys.upArrow, first: false), .passThrough, "inside a multi-line draft ↑ moves the caret")
        XCTAssertEqual(action(Keys.downArrow), .historyNext)
        XCTAssertEqual(action(Keys.downArrow, last: false), .passThrough)
        XCTAssertEqual(action(Keys.upArrow, empty: false), .passThrough, "a selection is not replaced by history")
        XCTAssertEqual(action(Keys.upArrow, .option), .passThrough)
    }

    func testControlRStartsASearchOfEarlierPrompts() {
        XCTAssertEqual(action(15, .control), .searchHistory)
        XCTAssertEqual(action(15, .control, suggestions: true), .searchHistory, "it also leaves the search")
        XCTAssertEqual(action(15), .passThrough, "a plain r is a letter")
        XCTAssertEqual(action(15, .command), .passThrough)
        XCTAssertEqual(action(15, [.control, .shift]), .passThrough)
        XCTAssertEqual(action(15, .control, marked: true), .passThrough)
    }

    func testAnInputMethodKeepsEveryKey() {
        XCTAssertEqual(action(Keys.returnKey, marked: true), .passThrough)
        XCTAssertEqual(action(Keys.escape, marked: true), .passThrough)
        XCTAssertEqual(action(Keys.upArrow, suggestions: true, marked: true), .passThrough)
    }

    func testOtherKeysPassThrough() {
        XCTAssertEqual(action(0), .passThrough)
        XCTAssertEqual(action(49), .passThrough)
    }
}
