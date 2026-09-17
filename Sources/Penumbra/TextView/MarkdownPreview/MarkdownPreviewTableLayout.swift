import CoreText
@preconcurrency import AppKit

/// Column/row/cell geometry for one table block, in the block's local coordinate space (origin at
/// the table frame's top-left; `MarkdownPreviewLayout` offsets it into document coordinates).
struct MarkdownPreviewTableGeometry: Equatable {
    var columnFrames: [CGRect] // full-height column bands, for vertical hairlines
    var headerFrame: CGRect?
    var rowFrames: [CGRect]
    var cellFrames: [[CGRect]] // [row][column], header excluded
    var headerCellFrames: [CGRect]
    var totalSize: CGSize
}

enum MarkdownPreviewTableLayout {
    /// Lays out `table` within `width`: natural (unwrapped) column widths when they fit, otherwise
    /// shrunk proportionally down to `style.tableMinColumnWidth`, with any remaining overflow
    /// absorbed by the widest column so narrower columns never fall below the floor.
    static func geometry(for table: MarkdownPreviewTable, style: MarkdownPreviewStyle, width: CGFloat) -> MarkdownPreviewTableGeometry {
        let columnCount = table.columns.count
        guard columnCount > 0 else {
            return MarkdownPreviewTableGeometry(
                columnFrames: [], headerFrame: nil, rowFrames: [], cellFrames: [], headerCellFrames: [],
                totalSize: .zero
            )
        }

        let padding = style.tableCellPadding
        var naturalWidths = [CGFloat](repeating: style.tableMinColumnWidth, count: columnCount)
        for (index, header) in table.header.enumerated() where index < columnCount {
            naturalWidths[index] = max(naturalWidths[index], naturalCellWidth(header, font: style.bodyFont, style: style) + padding * 2)
        }
        for row in table.rows {
            for (index, cell) in row.enumerated() where index < columnCount {
                naturalWidths[index] = max(naturalWidths[index], naturalCellWidth(cell, font: style.bodyFont, style: style) + padding * 2)
            }
        }

        let naturalTotal = naturalWidths.reduce(0, +)
        let columnWidths: [CGFloat]
        if naturalTotal <= width || naturalTotal <= 0 {
            columnWidths = naturalWidths
        } else {
            columnWidths = shrink(naturalWidths, toFit: width, floor: style.tableMinColumnWidth)
        }

        var columnX: [CGFloat] = []
        var x: CGFloat = 0
        for w in columnWidths {
            columnX.append(x)
            x += w
        }
        let tableWidth = x

        // Row heights: measure each cell wrapped at its assigned column width.
        func rowHeight(_ cells: [AttributedString]) -> CGFloat {
            var height: CGFloat = 0
            for index in 0..<columnCount {
                let cell = index < cells.count ? cells[index] : AttributedString()
                let cellWidth = max(columnWidths[index] - padding * 2, 1)
                height = max(height, measure(cell, font: style.bodyFont, style: style, width: cellWidth))
            }
            return height + padding * 2
        }

        var y: CGFloat = 0
        var headerFrame: CGRect?
        var headerCellFrames: [CGRect] = []
        if !table.header.isEmpty {
            let height = rowHeight(table.header)
            headerFrame = CGRect(x: 0, y: y, width: tableWidth, height: height)
            for index in 0..<columnCount {
                headerCellFrames.append(CGRect(x: columnX[index], y: y, width: columnWidths[index], height: height))
            }
            y += height
        }

        var rowFrames: [CGRect] = []
        var cellFrames: [[CGRect]] = []
        for row in table.rows {
            let height = rowHeight(row)
            rowFrames.append(CGRect(x: 0, y: y, width: tableWidth, height: height))
            var frames: [CGRect] = []
            for index in 0..<columnCount {
                frames.append(CGRect(x: columnX[index], y: y, width: columnWidths[index], height: height))
            }
            cellFrames.append(frames)
            y += height
        }

        var columnFrames: [CGRect] = []
        for index in 0..<columnCount {
            columnFrames.append(CGRect(x: columnX[index], y: 0, width: columnWidths[index], height: y))
        }

        return MarkdownPreviewTableGeometry(
            columnFrames: columnFrames,
            headerFrame: headerFrame,
            rowFrames: rowFrames,
            cellFrames: cellFrames,
            headerCellFrames: headerCellFrames,
            totalSize: CGSize(width: tableWidth, height: y)
        )
    }

    /// Scales `widths` down proportionally to fit `width`, never below `floor`; any shortfall from
    /// hitting the floor is absorbed by the widest remaining column so the total still fits.
    private static func shrink(_ widths: [CGFloat], toFit width: CGFloat, floor: CGFloat) -> [CGFloat] {
        var result = widths
        let total = widths.reduce(0, +)
        guard total > 0 else { return result }
        let scale = width / total
        for index in result.indices {
            result[index] = max(floor, (widths[index] * scale).rounded(.down))
        }
        let overflow = result.reduce(0, +) - width
        if overflow > 0, let widest = result.indices.max(by: { result[$0] < result[$1] }) {
            result[widest] = max(floor, result[widest] - overflow)
        }
        return result
    }

    private static func naturalCellWidth(_ text: AttributedString, font: NSFont, style: MarkdownPreviewStyle) -> CGFloat {
        let attributed = MarkdownPreviewInlineStyler.attributedString(text, baseFont: font, color: .labelColor, style: style)
        guard attributed.length > 0 else { return 0 }
        let line = CTLineCreateWithAttributedString(attributed)
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    private static func measure(_ text: AttributedString, font: NSFont, style: MarkdownPreviewStyle, width: CGFloat) -> CGFloat {
        let attributed = MarkdownPreviewInlineStyler.attributedString(text, baseFont: font, color: .labelColor, style: style)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let constraints = CGSize(width: width, height: .greatestFiniteMagnitude)
        var fitRange = CFRange()
        let size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, constraints, &fitRange)
        return max(size.height, font.ascender - font.descender)
    }
}
