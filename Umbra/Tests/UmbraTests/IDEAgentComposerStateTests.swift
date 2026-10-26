import Foundation
import XCTest

@testable import Umbra

@MainActor
final class IDEAgentComposerStateTests: XCTestCase {
    private func rows(_ names: String...) -> [IDEAgentSuggestion] {
        names.map { IDEAgentSuggestion(id: $0, icon: "slash.circle", title: $0, detail: nil, insertion: "/\($0) ") }
    }

    private let slash = IDEAgentComposerTrigger.slash(query: "r", range: NSRange(location: 0, length: 2))

    func testRowsShowWhileATriggerIsActive() {
        let state = IDEAgentComposerState()
        state.update(trigger: slash, suggestions: rows("resume", "rewind"))
        XCTAssertTrue(state.isShowingSuggestions)
        XCTAssertEqual(state.selected?.id, "resume")

        state.update(trigger: .none, suggestions: rows("resume"))
        XCTAssertFalse(state.isShowingSuggestions, "no trigger, no list")
    }

    func testTheHighlightWrapsAndResetsWhenTheTriggerChanges() {
        let state = IDEAgentComposerState()
        state.update(trigger: slash, suggestions: rows("a", "b", "c"))
        state.move(by: -1)
        XCTAssertEqual(state.selected?.id, "c")
        state.move(by: 1)
        XCTAssertEqual(state.selected?.id, "a")
        state.move(by: 1)
        XCTAssertEqual(state.selected?.id, "b")

        state.update(trigger: .slash(query: "re", range: NSRange(location: 0, length: 3)), suggestions: rows("a", "b"))
        XCTAssertEqual(state.selected?.id, "a", "a new query starts at the top")
    }

    func testTheHighlightStaysInRangeWhenTheListShrinks() {
        let state = IDEAgentComposerState()
        state.update(trigger: slash, suggestions: rows("a", "b", "c"))
        state.move(by: 1)
        state.move(by: 1)
        state.update(trigger: slash, suggestions: rows("a"))
        XCTAssertEqual(state.selected?.id, "a")
    }

    func testEscapeKeepsTheListClosedUntilTheTriggerChanges() {
        let state = IDEAgentComposerState()
        state.update(trigger: slash, suggestions: rows("resume"))
        state.dismiss()
        XCTAssertFalse(state.isShowingSuggestions)

        state.update(trigger: slash, suggestions: rows("resume"))
        XCTAssertFalse(state.isShowingSuggestions, "the same trigger stays dismissed")

        state.update(trigger: .slash(query: "re", range: NSRange(location: 0, length: 3)), suggestions: rows("resume"))
        XCTAssertTrue(state.isShowingSuggestions, "typing on reopens it")
    }

    func testAnEmptyListMovesNowhere() {
        let state = IDEAgentComposerState()
        state.move(by: 1)
        XCTAssertNil(state.selected)
    }
}
