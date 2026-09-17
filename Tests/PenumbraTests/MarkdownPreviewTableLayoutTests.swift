import AppKit
import XCTest
@testable import Penumbra

/// Device-free geometry tests for `MarkdownPreviewTableLayout`, in the same spirit as
/// `MarkdownPreviewTileGridTests` — pure layout math, no `NSView`/window required.
final class MarkdownPreviewTableLayoutTests: XCTestCase {
    private func table(columns: Int, header: [String], rows: [[String]]) -> MarkdownPreviewTable {
        MarkdownPreviewTable(
            columns: Array(repeating: MarkdownPreviewTable.Column(alignment: .leading), count: columns),
            header: header.map { AttributedString($0) },
            rows: rows.map { row in row.map { AttributedString($0) } }
        )
    }

    func testColumnWidthsUseNaturalSizeWhenTheyFit() {
        let style = MarkdownPreviewStyle()
        let source = table(columns: 3, header: ["A", "B", "C"], rows: [["1", "2", "3"]])
        let geometry = MarkdownPreviewTableLayout.geometry(for: source, style: style, width: 2000)

        XCTAssertEqual(geometry.columnFrames.count, 3)
        // Short single-character cells should not be stretched to consume all 2000pt of width.
        XCTAssertLessThan(geometry.totalSize.width, 600)
        for frame in geometry.columnFrames {
            XCTAssertGreaterThanOrEqual(frame.width, style.tableMinColumnWidth)
        }
    }

    func testColumnWidthsShrinkProportionallyWithFloorWhenTheyDoNotFit() {
        let style = MarkdownPreviewStyle()
        let longCell = String(repeating: "a very long cell value ", count: 6)
        let source = table(
            columns: 3,
            header: ["One", "Two", "Three"],
            rows: [[longCell, longCell, longCell]]
        )
        let availableWidth: CGFloat = 200 // far narrower than three long, equal-content columns need
        let geometry = MarkdownPreviewTableLayout.geometry(for: source, style: style, width: availableWidth)

        XCTAssertEqual(geometry.columnFrames.count, 3)
        for frame in geometry.columnFrames {
            XCTAssertGreaterThanOrEqual(
                frame.width, style.tableMinColumnWidth - 0.5,
                "No column should shrink below the configured floor"
            )
        }
        XCTAssertLessThanOrEqual(
            geometry.totalSize.width, availableWidth + 1,
            "Shrunk columns should fit within the available width (equal-content columns leave no overflow to redistribute)"
        )
    }

    func testEmptyTableProducesZeroGeometry() {
        let style = MarkdownPreviewStyle()
        let empty = MarkdownPreviewTable(columns: [], header: [], rows: [])
        let geometry = MarkdownPreviewTableLayout.geometry(for: empty, style: style, width: 400)
        XCTAssertEqual(geometry.totalSize, .zero)
        XCTAssertTrue(geometry.columnFrames.isEmpty)
    }
}
