@testable import Penumbra
import XCTest

/// `MinimapRowBuilder` turns one line's UTF-16 units + syntax-color spans into drawn segments.
/// Pure — no strings fetched, no tree-sitter — so tab expansion, run merging, the column budget
/// (requirement 3, asserted rather than eyeballed), and the trailing fade are all checked here.
final class MinimapRowBuilderTests: XCTestCase {
    private func builder(maxColumns: Int = 20, characterWidth: CGFloat = 1, leadingInset: CGFloat = 4, tabLength: Int = 4) -> MinimapRowBuilder {
        MinimapRowBuilder(maxColumns: maxColumns, characterWidth: characterWidth, leadingInset: leadingInset, tabLength: tabLength)
    }

    private func units(_ string: String) -> ArraySlice<unichar> {
        let array = Array(string.utf16)
        return array[array.startIndex ..< array.endIndex]
    }

    func testLeadingTabStartsBarAtTheTabStop() {
        let row = builder().makeRow(utf16: units("\tfoo"), colorSpans: [])
        XCTAssertEqual(row.segments.count, 1)
        XCTAssertEqual(row.segments[0].x, 4 + 4, accuracy: 0.001, "leadingInset (4) + one 4-wide tab stop")
        XCTAssertEqual(row.segments[0].width, 3, accuracy: 0.001)
    }

    func testLeadingSpacesShiftTheStartColumn() {
        let row = builder().makeRow(utf16: units("   x"), colorSpans: [])
        XCTAssertEqual(row.segments.count, 1)
        XCTAssertEqual(row.segments[0].x, 4 + 3, accuracy: 0.001)
        XCTAssertEqual(row.segments[0].width, 1, accuracy: 0.001)
    }

    func testWhitespaceOnlyLineProducesNoSegments() {
        XCTAssertTrue(builder().makeRow(utf16: units("     "), colorSpans: []).segments.isEmpty)
        XCTAssertTrue(builder().makeRow(utf16: units("\t\t"), colorSpans: []).segments.isEmpty)
    }

    func testAdjacentRunsWithTheSameColorMerge() {
        let row = builder().makeRow(utf16: units("abcd"), colorSpans: [(0 ..< 4, 2)])
        XCTAssertEqual(row.segments.count, 1)
        XCTAssertEqual(row.segments[0].colorIndex, 2)
        XCTAssertEqual(row.segments[0].width, 4, accuracy: 0.001)
    }

    func testDifferentColorsDoNotMerge() {
        let row = builder().makeRow(utf16: units("abcd"), colorSpans: [(0 ..< 2, 2), (2 ..< 4, 3)])
        XCTAssertEqual(row.segments.map(\.colorIndex), [2, 3])
        XCTAssertEqual(row.segments[0].x, 4, accuracy: 0.001)
        XCTAssertEqual(row.segments[1].x, 6, accuracy: 0.001)
    }

    func testWhitespaceBreaksARunEvenAtTheSameColor() {
        let row = builder().makeRow(utf16: units("ab cd"), colorSpans: [(0 ..< 5, 2)])
        XCTAssertEqual(row.segments.count, 2)
        XCTAssertEqual(row.segments[0].width, 2, accuracy: 0.001)
        XCTAssertEqual(row.segments[1].x, 4 + 3, accuracy: 0.001)
    }

    func testTruncatesAtMaxColumnsAndClipsRatherThanDropsAStraddlingCapture() {
        let row = builder(maxColumns: 5).makeRow(utf16: units("abcdefghij"), colorSpans: [(0 ..< 10, 2)])
        XCTAssertFalse(row.segments.isEmpty)
        XCTAssertTrue(row.segments.allSatisfy { $0.colorIndex == 2 }, "the capture is clipped to the budget, not discarded")
        XCTAssertEqual(row.segments.map(\.width).reduce(0, +), 5, accuracy: 0.001, "exactly the 5-column budget is drawn")
        XCTAssertEqual(row.segments.map { $0.x + $0.width }.max() ?? 0, 4 + 5, accuracy: 0.001, "never past the column budget")
    }

    func testTrailingColumnsFadeInDescendingSteps() {
        let row = builder(maxColumns: 20).makeRow(utf16: units(String(repeating: "a", count: 20)), colorSpans: [])
        XCTAssertEqual(row.segments.map(\.fadeStep), [0, 1, 2, 3, 4])
        let alphas = row.segments.map { MinimapFade.alpha(forStep: $0.fadeStep) }
        XCTAssertEqual(alphas, alphas.sorted(by: >), "alpha steps down toward the edge")
        XCTAssertEqual(alphas.first, 1)
        XCTAssertLessThan(alphas.last!, 1)
    }

    func testSurrogatePairCountsAsOneColumn() {
        let row = builder().makeRow(utf16: units("\u{1D54F}ab"), colorSpans: [])
        XCTAssertEqual(row.segments.count, 1)
        XCTAssertEqual(row.segments[0].width, 3, accuracy: 0.001, "𝕏 + a + b = three columns, not four")
    }

    func testFlatRowColorsEveryNonWhitespaceColumnWithTheBaseColor() {
        let row = builder().makeFlatRow(utf16: units("  a b  cd"))
        XCTAssertFalse(row.segments.isEmpty)
        XCTAssertTrue(row.segments.allSatisfy { $0.colorIndex == 0 })
    }
}
