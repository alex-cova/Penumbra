import XCTest
import EditorIntelligence

final class SnippetSessionTests: XCTestCase {
    private let engine = SnippetEngine()

    func testNilWhenOnlyFinalStopExists() {
        let expansion = engine.expand(body: "(${TM_SELECTED_TEXT})$0", context: SnippetExpansionContext(selectedText: "value"))
        XCTAssertNil(SnippetSession(expansion: expansion, origin: 0))
    }

    func testNumberedStopsThenFinal() throws {
        let expansion = engine.expand(
            body: "func ${1:name}(${2:arg}) {\n$0\n}",
            context: SnippetExpansionContext()
        )
        var session = try XCTUnwrap(SnippetSession(expansion: expansion, origin: 10))
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.currentRanges, [NSRange(location: 15, length: 4)])

        if case .select(let ranges) = session.advance() {
            XCTAssertEqual(ranges, [NSRange(location: 20, length: 3)])
        } else {
            XCTFail("Expected second numbered stop")
        }

        if case .finished(let caret) = session.advance() {
            XCTAssertEqual(caret, 10 + (expansion.finalCursorOffset ?? 0))
        } else {
            XCTFail("Tab off last numbered stop should land on $0 and end")
        }
        XCTAssertFalse(session.isActive)
    }

    func testLinkedStopsShareAnIndex() throws {
        let expansion = engine.expand(body: "${1:x} + ${1:x}$0", context: SnippetExpansionContext())
        var session = try XCTUnwrap(SnippetSession(expansion: expansion, origin: 0))
        XCTAssertEqual(session.currentRanges.count, 2)
        XCTAssertEqual(session.currentRanges[0], NSRange(location: 0, length: 1))
        if case .finished = session.advance() {
            // $0 is last; advancing from the only numbered stop ends the session.
        } else {
            XCTFail("Expected finish at $0")
        }
    }

    func testTypingInsideStopGrowsItAndShiftsLaterStops() throws {
        let expansion = engine.expand(body: "${1:ab}${2:cd}", context: SnippetExpansionContext())
        var session = try XCTUnwrap(SnippetSession(expansion: expansion, origin: 0))
        XCTAssertTrue(session.applyEdit(range: NSRange(location: 2, length: 0), replacementLength: 3))
        XCTAssertEqual(session.currentRanges, [NSRange(location: 0, length: 5)])
        if case .select(let ranges) = session.advance() {
            XCTAssertEqual(ranges, [NSRange(location: 5, length: 2)])
        } else {
            XCTFail("Expected shifted second stop")
        }
    }

    func testEditOutsideStopsEndsSession() throws {
        let expansion = engine.expand(body: "pre ${1:x} post", context: SnippetExpansionContext())
        var session = try XCTUnwrap(SnippetSession(expansion: expansion, origin: 0))
        XCTAssertFalse(session.applyEdit(range: NSRange(location: 0, length: 3), replacementLength: 1))
    }

    func testIndentMappingShiftsOffsets() throws {
        let expansion = engine.expand(body: "{\n${1:body}\n}$0", context: SnippetExpansionContext())
        let session = try XCTUnwrap(SnippetSession(expansion: expansion, origin: 4, extraIndentPerNewline: 4))
        // Two newlines before/around $1, each contributing 4 extra UTF-16 units.
        XCTAssertEqual(session.currentRanges, [NSRange(location: 4 + 2 + 4, length: 4)])
    }

    func testRetreatStaysOnFirstStop() throws {
        let expansion = engine.expand(body: "${1:a}${2:b}", context: SnippetExpansionContext())
        var session = try XCTUnwrap(SnippetSession(expansion: expansion, origin: 0))
        if case .select(let ranges) = session.retreat() {
            XCTAssertEqual(ranges, [NSRange(location: 0, length: 1)])
        } else {
            XCTFail("Retreat on first stop should re-select it")
        }
        _ = session.advance()
        if case .select(let ranges) = session.retreat() {
            XCTAssertEqual(ranges, [NSRange(location: 0, length: 1)])
        } else {
            XCTFail("Expected return to first stop")
        }
    }
}
