import XCTest
import AppKit
@testable import Penumbra

final class SemanticHighlightStoreTests: XCTestCase {
    private func highlight(_ location: Int, _ length: Int, _ name: String = "type") -> SyntaxHighlightRange {
        SyntaxHighlightRange(range: NSRange(location: location, length: length), highlightName: name)
    }

    func testQueriesReturnOnlyIntersectingHighlightsInOrder() {
        let store = SemanticHighlightStore()
        store.set([highlight(20, 3), highlight(0, 4), highlight(10, 5)])
        XCTAssertEqual(store.highlights(intersecting: NSRange(location: 0, length: 100)).map(\.range.location), [0, 10, 20])
        XCTAssertEqual(store.highlights(intersecting: NSRange(location: 4, length: 6)).map(\.range.location), [])
        XCTAssertEqual(store.highlights(intersecting: NSRange(location: 12, length: 10)).map(\.range.location), [10, 20])
        XCTAssertFalse(store.isEmpty)
    }

    func testEditsShiftLaterHighlightsAndDropOverlappingOnes() {
        let store = SemanticHighlightStore()
        store.set([highlight(0, 4), highlight(10, 5), highlight(20, 3)])
        // Replace 2 characters at 8..<10 with 5: highlights after it move by +3.
        store.applyEdit(range: NSRange(location: 8, length: 2), newLength: 5)
        XCTAssertEqual(store.highlights(intersecting: NSRange(location: 0, length: 100)).map(\.range.location), [0, 13, 23])
        // An edit inside a highlight drops it.
        store.applyEdit(range: NSRange(location: 14, length: 1), newLength: 1)
        XCTAssertEqual(store.highlights(intersecting: NSRange(location: 0, length: 100)).map(\.range.location), [0, 23])
        // A deletion before the rest moves them back.
        store.applyEdit(range: NSRange(location: 5, length: 10), newLength: 0)
        XCTAssertEqual(store.highlights(intersecting: NSRange(location: 0, length: 100)).map(\.range.location), [0, 13])
    }

    func testAnEditTouchingTheEdgeOfAHighlightKeepsIt() {
        let store = SemanticHighlightStore()
        store.set([highlight(5, 3)])
        store.applyEdit(range: NSRange(location: 8, length: 0), newLength: 2) // typed right after it
        store.applyEdit(range: NSRange(location: 5, length: 0), newLength: 1) // typed right before it
        XCTAssertEqual(store.highlights(intersecting: NSRange(location: 0, length: 100)).map(\.range), [NSRange(location: 6, length: 3)])
    }

    func testEmptyStoreAndReplacement() {
        let store = SemanticHighlightStore()
        XCTAssertTrue(store.isEmpty)
        store.applyEdit(range: NSRange(location: 0, length: 1), newLength: 1)
        store.set([highlight(1, 1)])
        store.set([])
        XCTAssertTrue(store.isEmpty)
    }

    func testLineRangesAffectedByReplacingDetectsAddedAndRemovedHighlights() {
        let store = SemanticHighlightStore()
        store.set([highlight(0, 4, "type.class"), highlight(10, 3, "property")])
        let affected = store.lineRanges(affectedByReplacing: [
            highlight(0, 4, "type.class"),
            highlight(20, 2, "method")
        ])
        XCTAssertTrue(affected.contains(NSRange(location: 10, length: 3)))
        XCTAssertTrue(affected.contains(NSRange(location: 20, length: 2)))
        XCTAssertFalse(affected.contains(NSRange(location: 0, length: 4)))
    }

    func testLineRangesAffectedByReplacingIsEmptyWhenUnchanged() {
        let store = SemanticHighlightStore()
        let highlights = [highlight(0, 4), highlight(10, 3)]
        store.set(highlights)
        XCTAssertTrue(store.lineRanges(affectedByReplacing: highlights).isEmpty)
    }

    @MainActor
    func testTextViewAcceptsSemanticHighlightsAndSurvivesEdits() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = "class A { int n; }"
        textView.setSemanticHighlights([highlight(6, 1, "type.class"), highlight(14, 1, "property")])
        textView.replace(NSRange(location: 0, length: 0), withText: "// x\n")
        textView.setSemanticHighlights([])
        XCTAssertEqual(textView.text as String, "// x\nclass A { int n; }")
    }
}
