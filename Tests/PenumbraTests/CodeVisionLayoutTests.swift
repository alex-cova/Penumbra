@preconcurrency import AppKit
import EditorIntelligence
import XCTest
@testable import Penumbra

/// A lens is a line of labels above a declaration. Its room is part of the declaration's line, so
/// the text below moves down by that much, the lens follows its line through edits, and the labels
/// only appear once they have entries.
@MainActor
final class CodeVisionLayoutTests: XCTestCase {
    private let source = (0 ..< 40).map { "line \($0)" }.joined(separator: "\n")

    private func offset(ofRow row: Int) -> Int {
        source.components(separatedBy: "\n").prefix(row).reduce(0) { $0 + $1.utf16.count + 1 }
    }

    private func lens(row: Int, column: Int = 5, entries: [CodeVisionEntry] = []) -> CodeVisionLens {
        CodeVisionLens(utf16Offset: offset(ofRow: row) + column, entries: entries)
    }

    private func rowHeight(_ textView: TextView) -> CGFloat {
        textView.stickyLinesInput.codeVisionStore.rowHeight
    }

    /// Top of `row`'s text now, read from the live line index (offsets shift as the text is edited).
    private func textTop(ofRow row: Int, in textView: TextView) -> CGFloat {
        textView.caretRectInViewport(at: textView.stickyLinesInput.lineManager.location(ofRow: row)).minY
    }

    private let usages = [CodeVisionEntry(id: "usages", text: "3 usages")]

    func testTheDeclarationAndEverythingBelowMoveDownByTheRoomOfTheLens() {
        let textView = makeFocusedTextView(text: source)
        let before = (0 ..< 8).map { textTop(ofRow: $0, in: textView) }

        textView.codeVisionLenses = [lens(row: 3)]
        textView.layoutIfNeeded()

        let room = rowHeight(textView)
        XCTAssertGreaterThan(room, 0)
        for row in 0 ..< 3 {
            XCTAssertEqual(textTop(ofRow: row, in: textView), before[row], accuracy: 0.5, "rows above stay")
        }
        for row in 3 ..< 8 {
            XCTAssertEqual(textTop(ofRow: row, in: textView), before[row] + room, accuracy: 0.5, "row \(row) moves down")
        }
    }

    func testRemovingTheLensRestoresTheLayout() {
        let textView = makeFocusedTextView(text: source)
        let before = textTop(ofRow: 6, in: textView)
        textView.codeVisionLenses = [lens(row: 3, entries: usages)]
        textView.layoutIfNeeded()
        XCTAssertNotEqual(textTop(ofRow: 6, in: textView), before)

        textView.codeVisionLenses = []
        textView.layoutIfNeeded()
        XCTAssertEqual(textTop(ofRow: 6, in: textView), before, accuracy: 0.5)
    }

    func testAnEmptyLensKeepsTheRoomAndShowsNothingUntilItHasEntries() {
        let textView = makeFocusedTextView(text: source)
        textView.codeVisionLenses = [lens(row: 3)]
        textView.layoutIfNeeded()
        let reserved = textTop(ofRow: 6, in: textView)
        XCTAssertEqual(textView.codeVisionShownRowsForTesting, [])

        textView.codeVisionLenses = [lens(row: 3, entries: usages)]
        textView.layoutIfNeeded()

        XCTAssertEqual(textTop(ofRow: 6, in: textView), reserved, accuracy: 0.5, "the text does not move when the numbers arrive")
        XCTAssertEqual(textView.codeVisionShownRowsForTesting, [3])
    }

    func testLensLabelsSitAboveTheirLine() throws {
        let textView = makeFocusedTextView(text: source)
        textView.codeVisionLenses = [lens(row: 3, entries: usages)]
        textView.layoutIfNeeded()

        let label = try XCTUnwrap(textView.codeVisionViewForTesting.visibleLabelViews.first)
        let lensTop = textView.stickyLinesInput.yPosition(ofRow: 3) - textView.contentOffset.y
        XCTAssertEqual(label.frame.minY, lensTop, accuracy: 0.5)
        XCTAssertEqual(label.frame.height, rowHeight(textView), accuracy: 0.5)
        XCTAssertLessThanOrEqual(label.frame.maxY, textTop(ofRow: 3, in: textView) + 0.5, "above the declaration's text")
    }

    func testLensesFollowTheirLineThroughEdits() {
        let textView = makeFocusedTextView(text: source)
        textView.codeVisionLenses = [lens(row: 10, entries: usages)]
        textView.layoutIfNeeded()

        textView.selectedRange = NSRange(location: offset(ofRow: 2), length: 0)
        textView.insertText("new line\n")
        XCTAssertEqual(textView.codeVisionLenses.map { textView.textLocation(at: $0.utf16Offset)?.lineNumber }, [11])

        // A line break removed above moves it back up.
        textView.replace(NSRange(location: offset(ofRow: 2), length: "new line\n".utf16.count), withText: "")
        XCTAssertEqual(textView.codeVisionLenses.map { textView.textLocation(at: $0.utf16Offset)?.lineNumber }, [10])
    }

    func testTypingInTheDeclarationsLineKeepsItsLens() {
        let textView = makeFocusedTextView(text: source)
        textView.codeVisionLenses = [lens(row: 4, entries: usages)]
        textView.layoutIfNeeded()
        let below = textTop(ofRow: 6, in: textView)

        textView.selectedRange = NSRange(location: offset(ofRow: 4) + 2, length: 0)
        textView.insertText("xyz")
        textView.layoutIfNeeded()

        XCTAssertEqual(textView.codeVisionLenses.count, 1)
        XCTAssertEqual(textTop(ofRow: 6, in: textView), below, accuracy: 0.5)
    }

    func testDeletingTheDeclarationsLineDropsItsLens() {
        let textView = makeFocusedTextView(text: source)
        textView.codeVisionLenses = [lens(row: 4, entries: usages), lens(row: 8, entries: usages)]
        textView.layoutIfNeeded()

        let start = offset(ofRow: 4)
        textView.replace(NSRange(location: start, length: offset(ofRow: 5) - start), withText: "")

        XCTAssertEqual(textView.codeVisionLenses.map { textView.textLocation(at: $0.utf16Offset)?.lineNumber }, [7])
    }

    func testReplacingTheDocumentClearsTheLenses() {
        let textView = makeFocusedTextView(text: source)
        textView.codeVisionLenses = [lens(row: 4, entries: usages)]
        textView.setState(TextViewState(text: "other\ntext", theme: DefaultTheme()))
        XCTAssertEqual(textView.codeVisionLenses, [])
    }

    func testClickingALabelReportsItAndTheDeclarationOffset() throws {
        let textView = makeFocusedTextView(text: source)
        var clicked: [(String, Int)] = []
        textView.codeVisionHandler = { entry, offset in clicked.append((entry.id, offset)) }
        textView.codeVisionLenses = [lens(row: 3, column: 5, entries: usages)]
        textView.layoutIfNeeded()

        let label = try XCTUnwrap(textView.codeVisionViewForTesting.visibleLabelViews.first)
        label.onClick?(usages[0])

        XCTAssertEqual(clicked.count, 1)
        XCTAssertEqual(clicked.first?.0, "usages")
        XCTAssertEqual(clicked.first?.1, offset(ofRow: 3) + 5)
    }

    func testCaretAndClicksOnALensLineUseTheShiftedText() throws {
        let textView = makeFocusedTextView(text: source)
        textView.codeVisionLenses = [lens(row: 3, entries: usages)]
        textView.layoutIfNeeded()

        let rect = textView.caretRectInViewport(at: offset(ofRow: 3) + 2)
        let index = try XCTUnwrap(textView.characterIndex(at: CGPoint(x: rect.minX + 1, y: rect.midY)))
        XCTAssertEqual(index, offset(ofRow: 3) + 2)
    }

    // MARK: - Gutter

    private func lineNumberView(showing number: Int, in view: NSView) -> LineNumberView? {
        if let label = view as? LineNumberView, label.text == "\(number)", !label.isHidden { return label }
        return view.subviews.lazy.compactMap { self.lineNumberView(showing: number, in: $0) }.first
    }

    func testTheLineNumberFollowsTheTextNotTheLens() throws {
        let textView = makeFocusedTextView(text: source)
        textView.showLineNumbers = true
        textView.layoutIfNeeded()
        let plain = try XCTUnwrap(lineNumberView(showing: 4, in: textView))
        let plainOffset = textView.convert(plain.bounds, from: plain).midY - textTop(ofRow: 3, in: textView)

        textView.codeVisionLenses = [lens(row: 3, entries: usages)]
        textView.layoutIfNeeded()
        let withLens = try XCTUnwrap(lineNumberView(showing: 4, in: textView))
        let lensOffset = textView.convert(withLens.bounds, from: withLens).midY - textTop(ofRow: 3, in: textView)

        XCTAssertEqual(lensOffset, plainOffset, accuracy: 0.5, "the number stays level with the declaration's text")
    }

    func testTheCurrentLineBarStartsAtTheTextNotAtTheLens() throws {
        let textView = makeFocusedTextView(text: source)
        textView.lineSelectionDisplayType = .line
        textView.codeVisionLenses = [lens(row: 3, entries: usages)]
        textView.layoutIfNeeded()
        textView.selectedRange = NSRange(location: textView.stickyLinesInput.lineManager.location(ofRow: 3) + 1, length: 0)
        textView.layoutIfNeeded()

        let bar = try XCTUnwrap(textView.stickyLinesInput.lineSelectionRectForTesting)
        let text = textView.stickyLinesInput.yPosition(ofRow: 3) + rowHeight(textView)
        XCTAssertEqual(bar.minY, text, accuracy: 0.5)
    }
}
