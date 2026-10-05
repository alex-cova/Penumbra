import AppKit
import XCTest
@testable import Penumbra

@MainActor
final class GutterChangeTests: XCTestCase {
    nonisolated(unsafe) private var windows: [NSWindow] = []

    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    private func store(_ changes: [GutterChange]) -> GutterChangeStore {
        let store = GutterChangeStore()
        store.replace(with: changes)
        return store
    }

    private func edit(
        startRow: Int,
        removedRows: Int = 0,
        lineDelta: Int,
        startsAtLineStart: Bool = false,
        endsAtLineStart: Bool = false,
        isInsertion: Bool = false,
        insertedTextEndsWithLineBreak: Bool = false
    ) -> GutterLineMarkerEdit {
        GutterLineMarkerEdit(
            startRow: startRow,
            removedRows: removedRows,
            lineDelta: lineDelta,
            startsAtLineStart: startsAtLineStart,
            endsAtLineStart: endsAtLineStart,
            isInsertion: isInsertion,
            insertedTextEndsWithLineBreak: insertedTextEndsWithLineBreak
        )
    }

    private func insertedLine(at startRow: Int, count: Int = 1) -> GutterLineMarkerEdit {
        edit(startRow: startRow, lineDelta: count, startsAtLineStart: true, isInsertion: true, insertedTextEndsWithLineBreak: true)
    }

    private func makeTextView(_ text: String) -> TextView {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 500, height: 280))
        textView.theme = DefaultTheme()
        textView.text = text
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 280),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        windows.append(window)
        textView.layoutSubtreeIfNeeded()
        return textView
    }

    private func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        for subview in view.subviews {
            if let match = subview as? T ?? firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    // MARK: - Model

    func testDeletionClampsToABoundaryAndTooltipsNameTheKind() {
        let deleted = GutterChange(line: 0, lineCount: 5, kind: .deleted, deletedLineCount: 0)
        XCTAssertEqual(deleted.line, 1)
        XCTAssertEqual(deleted.lineCount, 0)
        XCTAssertEqual(deleted.deletedLineCount, 1)
        XCTAssertEqual(deleted.tooltip, "1 line deleted")
        XCTAssertEqual(GutterChange(line: 4, lineCount: 0, kind: .deleted, deletedLineCount: 3).tooltip, "3 lines deleted")
        XCTAssertEqual(GutterChange(line: 2, lineCount: 4, kind: .added).tooltip, "Added")
        XCTAssertEqual(GutterChange(line: 2, lineCount: 4, kind: .modified).tooltip, "Modified")
        XCTAssertEqual(GutterChange(line: 2, lineCount: 4, kind: .added).deletedLineCount, 0)
    }

    func testAdjacentSpansOfOneKindBecomeOneBar() {
        let merged = store([
            GutterChange(line: 1, lineCount: 2, kind: .added),
            GutterChange(line: 3, lineCount: 2, kind: .added),
            GutterChange(line: 8, lineCount: 0, kind: .deleted, deletedLineCount: 1),
            GutterChange(line: 8, lineCount: 0, kind: .deleted, deletedLineCount: 2),
        ])
        XCTAssertEqual(merged.changes, [
            GutterChange(line: 1, lineCount: 4, kind: .added),
            GutterChange(line: 8, lineCount: 0, kind: .deleted, deletedLineCount: 3),
        ])
    }

    func testInsertingALineAboveMovesALaterSpanAndMarksTheNewLine() {
        let changes = store([GutterChange(line: 2, lineCount: 2, kind: .added)])
        changes.applyEdit(insertedLine(at: 0))
        XCTAssertEqual(changes.changes, [
            GutterChange(line: 1, lineCount: 1, kind: .added),
            GutterChange(line: 3, lineCount: 2, kind: .added),
        ])
    }

    func testInsertingALineAtTheStartOfAnAddedSpanStaysOneAddedSpan() {
        let changes = store([GutterChange(line: 1, lineCount: 3, kind: .added)])
        changes.applyEdit(insertedLine(at: 0))
        XCTAssertEqual(changes.changes, [GutterChange(line: 1, lineCount: 4, kind: .added)])
    }

    func testInsertingALineAboveAModifiedSpanMarksOnlyTheNewLineAdded() {
        let changes = store([GutterChange(line: 1, lineCount: 3, kind: .modified)])
        changes.applyEdit(insertedLine(at: 0))
        XCTAssertEqual(changes.changes, [
            GutterChange(line: 1, lineCount: 1, kind: .added),
            GutterChange(line: 2, lineCount: 3, kind: .modified),
        ])
    }

    func testTypingInsideAnAddedLineKeepsItAdded() {
        let changes = store([GutterChange(line: 1, lineCount: 3, kind: .added)])
        changes.applyEdit(edit(startRow: 1, lineDelta: 0, isInsertion: true))
        XCTAssertEqual(changes.changes, [GutterChange(line: 1, lineCount: 3, kind: .added)])
    }

    func testTypingOnACleanLineMarksItModifiedAndANewLineMarksItAdded() {
        let typed = store([])
        typed.applyEdit(edit(startRow: 0, lineDelta: 0, isInsertion: true))
        XCTAssertEqual(typed.changes, [GutterChange(line: 1, lineCount: 1, kind: .modified)])

        let broken = store([])
        broken.applyEdit(insertedLine(at: 0))
        XCTAssertEqual(broken.changes, [GutterChange(line: 1, lineCount: 1, kind: .added)])
    }

    func testDeletingASpanOutrightDropsItAndLeavesADeletionMark() {
        let changes = store([GutterChange(line: 2, lineCount: 2, kind: .modified)])
        changes.applyEdit(edit(startRow: 1, removedRows: 2, lineDelta: -2, startsAtLineStart: true, endsAtLineStart: true))
        XCTAssertEqual(changes.changes, [GutterChange(line: 2, lineCount: 0, kind: .deleted, deletedLineCount: 2)])
    }

    func testDeletingLinesInsideASpanClosesTheGapInsteadOfLeavingARemnant() {
        let changes = store([GutterChange(line: 1, lineCount: 10, kind: .modified)])
        changes.applyEdit(edit(startRow: 3, removedRows: 2, lineDelta: -2, startsAtLineStart: true, endsAtLineStart: true))
        XCTAssertEqual(changes.changes, [
            GutterChange(line: 1, lineCount: 8, kind: .modified),
            GutterChange(line: 4, lineCount: 0, kind: .deleted, deletedLineCount: 2),
        ])
    }

    func testShiftingOneLongSpanDoesNotDependOnWalkingItsRows() {
        let changes = store([GutterChange(line: 10, lineCount: 120_000, kind: .modified)])
        changes.applyEdit(insertedLine(at: 0))
        XCTAssertEqual(changes.changes, [
            GutterChange(line: 1, lineCount: 1, kind: .added),
            GutterChange(line: 11, lineCount: 120_000, kind: .modified),
        ])
    }

    func testADeletionOnTheBoundaryAfterTheLastQueriedLineIsIncluded() {
        let changes = store([
            GutterChange(line: 5, lineCount: 3, kind: .added),
            GutterChange(line: 10, lineCount: 0, kind: .deleted, deletedLineCount: 1),
        ])
        XCTAssertTrue(changes.changes(touchingLines: 1, 4).isEmpty)
        XCTAssertEqual(Array(changes.changes(touchingLines: 6, 6)).map(\.kind), [.added])
        XCTAssertEqual(Array(changes.changes(touchingLines: 8, 9)).map(\.line), [10])
        XCTAssertTrue(changes.changes(touchingLines: 8, 8).isEmpty)
    }

    // MARK: - Editor

    func testAKeystrokeMarksTheStripeBeforeADiffArrives() {
        let textView = makeTextView("hello")
        textView.showsGutterChangeStripe = true
        textView.replace(NSRange(location: 5, length: 0), withText: "!")
        XCTAssertEqual(textView.gutterChanges, [GutterChange(line: 1, lineCount: 1, kind: .modified)])

        textView.setGutterChanges([GutterChange(line: 1, lineCount: 1, kind: .added)])
        textView.replace(NSRange(location: 0, length: 0), withText: "\n")
        XCTAssertEqual(textView.gutterChanges, [GutterChange(line: 1, lineCount: 2, kind: .added)])
    }

    func testSetStateClearsTheSpansAndKeepsTheColumn() {
        let textView = makeTextView("hello")
        textView.showsGutterChangeStripe = true
        textView.setGutterChanges([GutterChange(line: 1, lineCount: 1, kind: .added)])
        textView.setState(TextViewState(text: "next"))
        XCTAssertTrue(textView.showsGutterChangeStripe)
        XCTAssertTrue(textView.gutterChanges.isEmpty)
    }

    func testTheColumnReservesFourPointsEvenWithLineNumbersOff() {
        let textView = makeTextView("hello")
        let before = textView.gutterWidth
        textView.showsGutterChangeStripe = true
        XCTAssertEqual(textView.gutterWidth, before + 4)
        textView.showLineNumbers = false
        let withoutNumbers = textView.gutterWidth
        XCTAssertGreaterThanOrEqual(withoutNumbers, 4)
        textView.showsGutterChangeStripe = false
        XCTAssertEqual(textView.gutterWidth, withoutNumbers - 4)
    }

    func testPaintingDoesNotCreateLineHandles() {
        let text = (0 ..< 2_000).map { "line \($0)" }.joined(separator: "\n")
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let handlesAfterRebuild = lineManager.handleCount
        let materialized = stringView.materializeCount

        let stripe = GutterChangeView(frame: CGRect(x: 0, y: 0, width: 4, height: 240))
        stripe.lineManager = lineManager
        stripe.store.replace(with: [GutterChange(line: 1, lineCount: 2_000, kind: .added)])
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 4, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = stripe
        windows.append(window)
        stripe.display()

        XCTAssertEqual(lineManager.handleCount, handlesAfterRebuild)
        XCTAssertEqual(stringView.materializeCount, materialized)
    }

    func testPaintingInTheEditorDoesNotMaterializeTheBufferOrAHandlePerLine() {
        let text = (0 ..< 400).map { "line \($0)" }.joined(separator: "\n")
        let textView = makeTextView(text)
        let handles = textView.lineManagerForTesting.handleCount
        let materialized = textView.pieceTreeMaterializeCount
        textView.showsGutterChangeStripe = true
        textView.setGutterChanges([GutterChange(line: 1, lineCount: 400, kind: .modified)])
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        textView.layoutSubtreeIfNeeded()
        textView.display()
        XCTAssertEqual(textView.pieceTreeMaterializeCount, materialized)
        XCTAssertLessThan(textView.lineManagerForTesting.handleCount, 80)
        XCTAssertLessThanOrEqual(textView.lineManagerForTesting.handleCount, handles + 8)
    }

    func testAClickOnTheStripeIsNotALineNumberClick() throws {
        let textView = makeTextView("one\ntwo\nthree")
        var clicks: [Int] = []
        textView.gutterLineClickHandler = { clicks.append($0.line); return true }
        textView.showsGutterChangeStripe = true
        textView.setGutterChanges([GutterChange(line: 2, lineCount: 1, kind: .added)])
        // A gutter-width change lays out on the next turn.
        let deadline = Date().addingTimeInterval(1)
        var laidOut: GutterChangeView?
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            textView.layoutSubtreeIfNeeded()
            laidOut = firstSubview(of: GutterChangeView.self, in: textView)
            if laidOut?.frame.width == 4 { break }
        }
        let stripe = try XCTUnwrap(laidOut)
        XCTAssertFalse(stripe.isHidden)
        XCTAssertEqual(stripe.frame.width, 4)
        let point = stripe.convert(CGPoint(x: stripe.bounds.midX, y: stripe.bounds.midY), to: nil)
        let frameView = try XCTUnwrap(textView.window?.contentView?.superview)
        let hit = try XCTUnwrap(frameView.hitTest(frameView.convert(point, from: nil)))
        XCTAssertTrue(hit === stripe)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: textView.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: textView.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        hit.mouseDown(with: down)
        hit.mouseUp(with: up)
        XCTAssertTrue(clicks.isEmpty)
    }
}
