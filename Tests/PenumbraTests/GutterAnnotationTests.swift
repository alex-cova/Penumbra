import XCTest
import AppKit
@testable import Penumbra

@MainActor
final class GutterAnnotationTests: XCTestCase {
    private let edited = GutterAnnotation(id: -1, text: "Not Committed Yet")

    private func annotation(_ id: Int) -> GutterAnnotation {
        GutterAnnotation(id: id, text: "author \(id)", tooltip: "commit \(id)")
    }

    private func edit(startRow: Int, removedRows: Int = 0, lineDelta: Int, startsAtLineStart: Bool = false,
                      isInsertion: Bool = false, endsWithBreak: Bool = false) -> GutterLineMarkerEdit {
        GutterLineMarkerEdit(startRow: startRow, removedRows: removedRows, lineDelta: lineDelta,
                             startsAtLineStart: startsAtLineStart, endsAtLineStart: false,
                             isInsertion: isInsertion, insertedTextEndsWithLineBreak: endsWithBreak)
    }

    private func ids(_ store: GutterAnnotationStore) -> [Int?] {
        (0..<store.rowCount).map { store.annotation(atRow: $0)?.id }
    }

    private func store(_ rows: [GutterAnnotation?]) -> GutterAnnotationStore {
        let store = GutterAnnotationStore()
        store.replace(with: rows, edited: edited)
        return store
    }

    // MARK: - Store

    func testRowsShareOneEntryPerID() {
        let store = store([annotation(1), annotation(1), annotation(2), nil])
        XCTAssertEqual(ids(store), [1, 1, 2, nil])
        XCTAssertEqual(store.distinctAnnotations.map(\.id), [1, 2, -1])
    }

    func testOnlyTheFirstRowOfABlockStartsIt() {
        let store = store([annotation(1), annotation(1), annotation(2), annotation(1)])
        XCTAssertEqual((0..<4).map(store.startsBlock(atRow:)), [true, false, true, true])
    }

    func testTypingInsideALineMarksOnlyThatLine() {
        let store = store([annotation(1), annotation(1), annotation(2)])
        XCTAssertTrue(store.applyEdit(edit(startRow: 1, lineDelta: 0, isInsertion: true)))
        XCTAssertEqual(ids(store), [1, -1, 2])
        // A second keystroke on the same line changes nothing.
        XCTAssertFalse(store.applyEdit(edit(startRow: 1, lineDelta: 0, isInsertion: true)))
    }

    func testABreakInTheMiddleOfALineEditsBothHalves() {
        let store = store([annotation(1), annotation(2), annotation(3)])
        store.applyEdit(edit(startRow: 1, lineDelta: 1, isInsertion: true))
        XCTAssertEqual(ids(store), [1, -1, -1, 3])
    }

    func testABlankLineInsertedAboveKeepsTheLineItPushedDown() {
        let store = store([annotation(1), annotation(2)])
        store.applyEdit(edit(startRow: 1, lineDelta: 1, startsAtLineStart: true, isInsertion: true, endsWithBreak: true))
        XCTAssertEqual(ids(store), [1, -1, 2])
    }

    func testDeletingLinesLeavesTheJoinedLineEdited() {
        let store = store([annotation(1), annotation(2), annotation(3), annotation(4)])
        // Rows 1 and 2 collapse into one edited row.
        store.applyEdit(edit(startRow: 1, removedRows: 1, lineDelta: -1))
        XCTAssertEqual(ids(store), [1, -1, 4])
    }

    func testAnEditPastTheEndDoesNotCrash() {
        let store = store([annotation(1)])
        store.applyEdit(edit(startRow: 5, removedRows: 2, lineDelta: 0))
        XCTAssertLessThanOrEqual(store.rowCount, 2)
    }

    func testWithoutAnEditedAnnotationTouchedRowsAreBlank() {
        let store = GutterAnnotationStore()
        store.replace(with: [annotation(1), annotation(2)], edited: nil)
        store.applyEdit(edit(startRow: 0, lineDelta: 0, isInsertion: true))
        XCTAssertEqual(ids(store), [nil, 2])
    }

    // MARK: - Text view

    private func makeTextView(_ text: String) -> TextView {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        textView.theme = DefaultTheme()
        textView.showLineNumbers = true
        textView.text = text
        textView.layoutIfNeeded()
        return textView
    }

    func testAnnotationsWidenTheGutterOnlyWhilePresent() {
        let textView = makeTextView("one\ntwo\nthree")
        let plain = textView.gutterWidth
        textView.setGutterAnnotations([annotation(1), annotation(1), annotation(2)])
        XCTAssertGreaterThan(textView.gutterWidth, plain)
        XCTAssertTrue(textView.hasGutterAnnotations)
        textView.setGutterAnnotations([])
        XCTAssertEqual(textView.gutterWidth, plain, accuracy: 0.5)
        XCTAssertFalse(textView.hasGutterAnnotations)
    }

    func testAnnotationsFollowLinesThroughEdits() {
        let textView = makeTextView("one\ntwo\nthree")
        textView.setGutterAnnotations([annotation(1), annotation(2), annotation(3)], edited: edited)
        // A new first line: everything else moves down and keeps its annotation.
        textView.replace(NSRange(location: 0, length: 0), withText: "zero\n")
        XCTAssertEqual((0..<4).map { textView.gutterAnnotationForTesting(atRow: $0)?.id }, [-1, 1, 2, 3])
        // Typing inside "two" marks just that line.
        let two = (textView.text as NSString).range(of: "two")
        textView.replace(NSRange(location: two.location, length: 0), withText: "X")
        XCTAssertEqual((0..<4).map { textView.gutterAnnotationForTesting(atRow: $0)?.id }, [-1, 1, -1, 3])
    }

    func testReplacingTheDocumentClearsTheColumn() {
        let textView = makeTextView("one\ntwo")
        textView.setGutterAnnotations([annotation(1), annotation(2)])
        textView.setState(TextViewState(text: "other", theme: DefaultTheme()))
        XCTAssertFalse(textView.hasGutterAnnotations)
    }

    /// Draws the whole text view and counts pixels that differ from the background inside the
    /// gutter's left `width` points.
    private func inkInGutter(of textView: TextView, width: CGFloat) -> Int {
        // A new gutter width reaches the layout on the next main-queue turn.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        textView.layoutIfNeeded()
        textView.layoutSubtreeIfNeeded()
        guard let rep = textView.bitmapImageRepForCachingDisplay(in: textView.bounds) else { return 0 }
        textView.cacheDisplay(in: textView.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / textView.bounds.width
        let background = rep.colorAt(x: 1, y: rep.pixelsHigh - 2)
        var ink = 0
        for x in 0..<Int(width * scale) {
            for y in 0..<Int(60 * scale) {
                if let color = rep.colorAt(x: x, y: y), color != background { ink += 1 }
            }
        }
        return ink
    }

    func testTheColumnPaintsTextOnlyWhilePresent() {
        let textView = makeTextView("one\ntwo\nthree")
        // Width of the plain gutter's leading region: annotation text is drawn left of the numbers.
        let width = textView.gutterWidth
        let before = inkInGutter(of: textView, width: width)
        textView.setGutterAnnotations([annotation(1), annotation(1), annotation(2)])
        let during = inkInGutter(of: textView, width: textView.gutterWidth)
        XCTAssertGreaterThan(during, before)
        // Control: the same column with blank text widens the gutter but paints nothing extra.
        textView.setGutterAnnotations([GutterAnnotation(id: 1, text: " ")])
        XCTAssertEqual(inkInGutter(of: textView, width: textView.gutterWidth), before)
        textView.setGutterAnnotations([annotation(1), annotation(1), annotation(2)])
        textView.clearGutterAnnotations()
        XCTAssertEqual(inkInGutter(of: textView, width: textView.gutterWidth), before)
    }
}
