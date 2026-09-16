import Foundation

/**
 * A container cell that lays its children out along a strip.
 */
package class StripContainerCell: ContainerCell {

    // MARK: - Properties

    /** Whether we lay children out in rows or columns. */
    package let containerMode: Strip
    /** Whether the outer cells should be the same width or height. */
    package let symmetrical: Bool
    /** A container cell can include gaps between its children when calculating its preferred size. */
    package let gap: Double
    /** A container cell consists of a number of cells that make up its content. */
    package var cells: [Cell?]

    // MARK: - Computed properties for min width/height (instance-level wrappers)

    package var minimumWidth: Double { return getMinimumWidth() }
    package var minimumHeight: Double { return getMinimumHeight() }

    // MARK: - Constructors

    package init(mode: Strip, symmetrical: Bool, gap: Double) {
        self.containerMode = mode
        self.symmetrical = symmetrical
        self.gap = gap
        self.cells = Array(repeating: nil, count: ContainerArea.allCases.count)
        super.init()
    }

    // MARK: - Getters / Setters

    package func getContainerMode() -> Strip {
        return containerMode
    }

    package func getGap() -> Double {
        return gap
    }

    package func getCell(_ area: ContainerArea) -> Cell? {
        return cells[area.rawValue]
    }

    package func setCell(_ area: ContainerArea, cell: Cell?) {
        cells[area.rawValue] = cell
    }

    /// Convenience: setCell(area, cell) without label
    package func setCell(_ area: ContainerArea, _ cell: Cell?) {
        cells[area.rawValue] = cell
    }

    // MARK: - (Container) Cell Methods

    package override func getMinimumWidth() -> Double {
        var width: Double = 0

        if containerMode == .VERTICAL {
            width = cells.compactMap { $0 }
                .filter { $0.isContributingToMinimumWidth() }
                .map { $0.getMinimumWidth() }
                .max() ?? 0
        } else {
            let cellWidths = minCellWidths(respectContributionFlag: true)

            var activeCells = 0
            for cellWidth in cellWidths {
                if cellWidth > 0 {
                    width += cellWidth
                    activeCells += 1
                }
            }

            if activeCells > 1 {
                width += gap * Double(activeCells - 1)
            }
        }

        return width > 0
            ? width + getPadding().left + getPadding().right
            : 0
    }

    package override func getMinimumHeight() -> Double {
        var height: Double = 0

        if containerMode == .VERTICAL {
            let cellHeights = minCellHeights(respectContributionFlag: true)

            var activeCells = 0
            for cellHeight in cellHeights {
                if cellHeight > 0 {
                    height += cellHeight
                    activeCells += 1
                }
            }

            if activeCells > 1 {
                height += gap * Double(activeCells - 1)
            }
        } else {
            height = cells.compactMap { $0 }
                .filter { $0.isContributingToMinimumHeight() }
                .map { $0.getMinimumHeight() }
                .max() ?? 0
        }

        return height > 0
            ? height + getPadding().top + getPadding().bottom
            : 0
    }

    package override func layoutChildrenHorizontally() {
        let cellRectangle = getCellRectangle()
        let cellPadding = getPadding()

        if containerMode == .VERTICAL {
            let xPos = cellRectangle.x + cellPadding.left
            let width = cellRectangle.width - cellPadding.left - cellPadding.right

            for childCell in cells.compactMap({ $0 }) {
                applyHorizontalLayout(childCell, x: xPos, width: width)
            }
        } else {
            let cellWidths = minCellWidths(respectContributionFlag: false)

            if let c0 = cells[0] {
                applyHorizontalLayout(c0, x: cellRectangle.x + cellPadding.left, width: cellWidths[0])
            }
            if let c2 = cells[2] {
                applyHorizontalLayout(c2, x: cellRectangle.x + cellRectangle.width - cellPadding.right - cellWidths[2], width: cellWidths[2])
            }

            var freeContentAreaWidth = cellRectangle.width - cellPadding.left - cellPadding.right

            var adjustedCellWidths = cellWidths

            if adjustedCellWidths[0] > 0 {
                freeContentAreaWidth -= adjustedCellWidths[0] + gap
                adjustedCellWidths[0] += gap
            }

            if adjustedCellWidths[2] > 0 {
                freeContentAreaWidth -= adjustedCellWidths[2] + gap
            }

            adjustedCellWidths[1] = max(adjustedCellWidths[1], freeContentAreaWidth)

            let xOffset = (adjustedCellWidths[1] - freeContentAreaWidth) / 2
            if let c1 = cells[1] {
                applyHorizontalLayout(c1,
                                      x: cellRectangle.x + cellPadding.left + adjustedCellWidths[0] - xOffset,
                                      width: adjustedCellWidths[1])
            }
        }

        // Layout container cells recursively
        for childCell in cells.compactMap({ $0 }) {
            if let containerCell = childCell as? ContainerCell {
                containerCell.layoutChildrenHorizontally()
            }
        }
    }

    package override func layoutChildrenVertically() {
        let cellRectangle = getCellRectangle()
        let cellPadding = getPadding()

        if containerMode == .VERTICAL {
            let cellHeights = minCellHeights(respectContributionFlag: false)

            if let c0 = cells[0] {
                applyVerticalLayout(c0, y: cellRectangle.y + cellPadding.top, height: cellHeights[0])
            }
            if let c2 = cells[2] {
                applyVerticalLayout(c2, y: cellRectangle.y + cellRectangle.height - cellPadding.bottom - cellHeights[2], height: cellHeights[2])
            }

            let contentAreaHeight = cellRectangle.height - cellPadding.top - cellPadding.bottom
            var contentAreaFreeHeight = contentAreaHeight

            var adjustedCellHeights = cellHeights

            if adjustedCellHeights[0] > 0 {
                adjustedCellHeights[0] += gap
                contentAreaFreeHeight -= adjustedCellHeights[0]
            }

            if adjustedCellHeights[2] > 0 {
                contentAreaFreeHeight -= adjustedCellHeights[2] + gap
            }

            adjustedCellHeights[1] = max(adjustedCellHeights[1], contentAreaFreeHeight)

            let yOffset = (adjustedCellHeights[1] - contentAreaFreeHeight) / 2
            if let c1 = cells[1] {
                applyVerticalLayout(c1,
                                    y: cellRectangle.y + cellPadding.top + adjustedCellHeights[0] - yOffset,
                                    height: adjustedCellHeights[1])
            }
        } else {
            let yPos = cellRectangle.y + cellPadding.top
            let height = cellRectangle.height - cellPadding.top - cellPadding.bottom

            for childCell in cells.compactMap({ $0 }) {
                applyVerticalLayout(childCell, y: yPos, height: height)
            }
        }

        // Layout container cells recursively
        for childCell in cells.compactMap({ $0 }) {
            if let containerCell = childCell as? ContainerCell {
                containerCell.layoutChildrenVertically()
            }
        }
    }

    // MARK: - Utilities

    package func minCellWidths(respectContributionFlag: Bool) -> [Double] {
        var cellWidths: [Double] = [
            ContainerCell.minWidthOfCell(cells[0], respectContributionFlag: respectContributionFlag),
            ContainerCell.minWidthOfCell(cells[1], respectContributionFlag: respectContributionFlag),
            ContainerCell.minWidthOfCell(cells[2], respectContributionFlag: respectContributionFlag)
        ]

        if symmetrical {
            cellWidths[0] = max(cellWidths[0], cellWidths[2])
            cellWidths[2] = cellWidths[0]
        }

        return cellWidths
    }

    package func minCellHeights(respectContributionFlag: Bool) -> [Double] {
        var cellHeights: [Double] = [
            ContainerCell.minHeightOfCell(cells[0], respectContributionFlag: respectContributionFlag),
            ContainerCell.minHeightOfCell(cells[1], respectContributionFlag: respectContributionFlag),
            ContainerCell.minHeightOfCell(cells[2], respectContributionFlag: respectContributionFlag)
        ]

        if symmetrical {
            cellHeights[0] = max(cellHeights[0], cellHeights[2])
            cellHeights[2] = cellHeights[0]
        }

        return cellHeights
    }

    // MARK: - Strip Enum

    package enum Strip: Int, CaseIterable {
        case VERTICAL = 0
        case HORIZONTAL = 1
    }

    /// Convenience: setPadding for compatibility
    package func setPadding(_ newPadding: ElkPadding) {
        padding = newPadding
    }
}
