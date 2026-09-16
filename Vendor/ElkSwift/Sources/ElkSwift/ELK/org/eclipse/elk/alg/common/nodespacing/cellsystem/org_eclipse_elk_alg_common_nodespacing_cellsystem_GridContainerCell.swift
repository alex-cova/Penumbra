/*******************************************************************************
 * Copyright (c) 2017 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 *******************************************************************************/

/**
 * A container that lays out its child cells in three rows.
 */
package class GridContainerCell: ContainerCell {

    // MARK: - Constants

    package static let ROWS = ContainerArea.count
    package static let COLUMNS = ROWS

    // MARK: - Properties

    package let gap: Double
    package let tabular: Bool
    package let symmetrical: Bool
    package var cells: [[Cell?]] = Array(repeating: Array(repeating: nil, count: 3), count: 3)

    package var centerCellMinimumSize: KVector?
    package var onlyCenterCellContributesToMinimumSize = false
    package var centerCellRect = ElkRectangle()

    // Computed properties for min width/height
    package var minimumWidth: Double { return getMinimumWidth() }
    package var minimumHeight: Double { return getMinimumHeight() }

    // MARK: - Initializers

    package init(tabular: Bool, symmetrical: Bool, gap: Double) {
        self.tabular = tabular
        self.symmetrical = symmetrical
        self.gap = gap
        super.init()
    }

    /// Convenience initializer for code that passes positional args
    package convenience init(_ tabular: Bool, _ symmetrical: Bool, _ gap: Double) {
        self.init(tabular: tabular, symmetrical: symmetrical, gap: gap)
    }

    // MARK: - Getters / Setters

    package func getGap() -> Double {
        return gap
    }

    package func getCell(row: ContainerArea, col: ContainerArea) -> Cell? {
        return cells[row.ordinal][col.ordinal]
    }

    /// Convenience: getCell(.BEGIN, .END)
    package func getCell(_ row: ContainerArea, _ col: ContainerArea) -> Cell? {
        return cells[row.ordinal][col.ordinal]
    }

    package func setCell(row: ContainerArea, col: ContainerArea, cell: Cell?) {
        cells[row.ordinal][col.ordinal] = cell
    }

    /// Convenience: setCell(row, col, cell) positional
    package func setCell(_ row: ContainerArea, _ col: ContainerArea, _ cell: Cell?) {
        cells[row.ordinal][col.ordinal] = cell
    }

    package func setCenterCellMinimumSize(_ minimumSize: KVector) {
        self.centerCellMinimumSize = KVector(x: minimumSize.x, y: minimumSize.y)
    }

    package func setOnlyCenterCellContributesToMinimumSize(_ contribution: Bool) {
        self.onlyCenterCellContributesToMinimumSize = contribution
    }

    package func getCenterCellRectangle() -> ElkRectangle {
        return ElkRectangle(x: centerCellRect.x, y: centerCellRect.y, width: centerCellRect.width, height: centerCellRect.height)
    }

    // MARK: - Cell Methods

    package override func getMinimumWidth() -> Double {
        var width = 0.0

        if onlyCenterCellContributesToMinimumSize {
            if let size = centerCellMinimumSize {
                width = size.x
            } else if let centerCell = cells[1][1] {
                width = centerCell.getMinimumWidth()
            }
        } else if tabular {
            width = sumWithGaps(minColumnWidths(row: nil, respectContributionFlag: true))
        } else {
            for area in ContainerArea.allCases {
                width = max(width, sumWithGaps(minColumnWidths(row: area, respectContributionFlag: true)))
            }
        }

        return width > 0 ? width + getPadding().left + getPadding().right : 0
    }

    package override func getMinimumHeight() -> Double {
        var height = 0.0

        if onlyCenterCellContributesToMinimumSize {
            if let size = centerCellMinimumSize {
                height = size.y
            } else if let centerCell = cells[1][1] {
                height = centerCell.getMinimumHeight()
            }
        } else {
            height = sumWithGaps(minRowHeights(respectContributionFlag: true))
        }

        return height > 0 ? height + getPadding().top + getPadding().bottom : 0
    }

    package override func layoutChildrenHorizontally() {
        if tabular {
            let colWidths = minColumnWidths(row: nil, respectContributionFlag: false)
            for area in ContainerArea.allCases {
                applyWidthsToRow(row: area, colWidths: colWidths)
            }
        } else {
            for area in ContainerArea.allCases {
                let colWidths = minColumnWidths(row: area, respectContributionFlag: false)
                applyWidthsToRow(row: area, colWidths: colWidths)
            }
        }
    }

    package override func layoutChildrenVertically() {
        let cellRectangle = getCellRectangle()
        let cellPadding = getPadding()

        let rowHeights = minRowHeights(respectContributionFlag: false)

        applyHeightToRow(row: .begin, y: cellRectangle.y + cellPadding.top, rowHeights: rowHeights)
        applyHeightToRow(row: .end, y: cellRectangle.y + cellRectangle.height - cellPadding.bottom - rowHeights[2], rowHeights: rowHeights)

        var freeContentAreaHeight = cellRectangle.height - cellPadding.top - cellPadding.bottom

        var adjustedRowHeights = rowHeights
        if adjustedRowHeights[0] > 0 {
            adjustedRowHeights[0] += gap
            freeContentAreaHeight -= adjustedRowHeights[0]
        }

        if adjustedRowHeights[2] > 0 {
            adjustedRowHeights[2] += gap
            freeContentAreaHeight -= adjustedRowHeights[2]
        }

        centerCellRect.height = max(0, freeContentAreaHeight)
        centerCellRect.y = cellRectangle.y + cellPadding.top + (centerCellRect.height - freeContentAreaHeight) / 2

        adjustedRowHeights[1] = max(adjustedRowHeights[1], freeContentAreaHeight)

        applyHeightToRow(row: .center,
                         y: cellRectangle.y + cellPadding.top + adjustedRowHeights[0] - (adjustedRowHeights[1] - freeContentAreaHeight) / 2,
                         rowHeights: adjustedRowHeights)
    }

    // MARK: - Width and Height Calculations

    package func minColumnWidths(row: ContainerArea?, respectContributionFlag: Bool) -> [Double] {
        var colWidths = [
            minWidthOfColumn(column: .begin, row: row, respectContributionFlag: respectContributionFlag),
            minWidthOfColumn(column: .center, row: row, respectContributionFlag: respectContributionFlag),
            minWidthOfColumn(column: .end, row: row, respectContributionFlag: respectContributionFlag)
        ]

        if symmetrical {
            colWidths[0] = max(colWidths[0], colWidths[2])
            colWidths[2] = colWidths[0]
        }

        return colWidths
    }

    package func minWidthOfColumn(column: ContainerArea, row: ContainerArea?, respectContributionFlag: Bool) -> Double {
        var maxMinWidth = 0.0

        if row == nil {
            for rowIndex in 0..<GridContainerCell.ROWS {
                maxMinWidth = max(maxMinWidth, ContainerCell.minWidthOfCell(cells[rowIndex][column.ordinal], respectContributionFlag: respectContributionFlag))
            }
        } else {
            guard let row = row else { return maxMinWidth }
            maxMinWidth = ContainerCell.minWidthOfCell(cells[row.ordinal][column.ordinal], respectContributionFlag: respectContributionFlag)
        }

        if column == .center, let size = centerCellMinimumSize {
            maxMinWidth = max(maxMinWidth, size.x)
        }

        return maxMinWidth
    }

    package func minRowHeights(respectContributionFlag: Bool) -> [Double] {
        var rowHeights = [
            minHeightOfRow(row: .begin, respectContributionFlag: respectContributionFlag),
            minHeightOfRow(row: .center, respectContributionFlag: respectContributionFlag),
            minHeightOfRow(row: .end, respectContributionFlag: respectContributionFlag)
        ]

        if symmetrical {
            rowHeights[0] = max(rowHeights[0], rowHeights[2])
            rowHeights[2] = rowHeights[0]
        }

        return rowHeights
    }

    package func minHeightOfRow(row: ContainerArea, respectContributionFlag: Bool) -> Double {
        var maxMinHeight = 0.0
        for column in 0..<GridContainerCell.COLUMNS {
            maxMinHeight = max(maxMinHeight, ContainerCell.minHeightOfCell(cells[row.ordinal][column], respectContributionFlag: respectContributionFlag))
        }

        if row == .center, let size = centerCellMinimumSize {
            maxMinHeight = max(maxMinHeight, size.y)
        }

        return maxMinHeight
    }

    package func sumWithGaps(_ values: [Double]) -> Double {
        var sum = 0.0
        var activeComponents = 0

        for val in values {
            if val > 0 {
                sum += val
                activeComponents += 1
            }
        }

        if activeComponents > 1 {
            sum += gap * Double(activeComponents - 1)
        }

        return sum
    }

    // MARK: - Layout Application

    package func applyWidthsToRow(row: ContainerArea, colWidths: [Double]) {
        let cellRectangle = getCellRectangle()
        let cellPadding = getPadding()

        applyWidthToColumn(column: .begin, x: cellRectangle.x + cellPadding.left, colWidths: colWidths)
        applyWidthToColumn(column: .end, x: cellRectangle.x + cellRectangle.width - cellPadding.right - colWidths[2], colWidths: colWidths)

        var freeContentAreaWidth = cellRectangle.width - cellPadding.left - cellPadding.right

        var adjustedColWidths = colWidths
        if adjustedColWidths[0] > 0 {
            adjustedColWidths[0] += gap
            freeContentAreaWidth -= adjustedColWidths[0]
        }

        if adjustedColWidths[2] > 0 {
            adjustedColWidths[2] += gap
            freeContentAreaWidth -= adjustedColWidths[2]
        }

        let centerWidth = max(0, freeContentAreaWidth)
        adjustedColWidths[1] = max(adjustedColWidths[1], freeContentAreaWidth)

        applyWidthToColumn(column: .center,
                           x: cellRectangle.x + cellPadding.left + adjustedColWidths[0] - (adjustedColWidths[1] - freeContentAreaWidth) / 2,
                           colWidths: adjustedColWidths)

        if row == .center {
            centerCellRect.width = centerWidth
            centerCellRect.x = cellRectangle.x + cellPadding.left + (centerWidth - freeContentAreaWidth) / 2
        }
    }

    package func applyWidthToColumn(column: ContainerArea, x: Double, colWidths: [Double]) {
        for row in 0..<GridContainerCell.ROWS {
            applyHorizontalLayout(cells[row][column.ordinal], x: x, width: colWidths[column.ordinal])
        }
    }

    package func applyHeightToRow(row: ContainerArea, y: Double, rowHeights: [Double]) {
        for column in 0..<GridContainerCell.COLUMNS {
            applyVerticalLayout(cells[row.ordinal][column], y: y, height: rowHeights[row.ordinal])
        }
    }
}
