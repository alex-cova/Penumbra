import Foundation

/**
 * Configures constraints of the cell system such that the various cells contribute properly to the node size
 * calculation.
 */
package final class CellSystemConfigurator {

    private init() {}

    // MARK: - Size Contribution Configuration

    package static func configureCellSystemSizeContributions(_ nodeContext: NodeContext) {
        if nodeContext.sizeConstraints.isEmpty {
            return
        }

        if nodeContext.sizeConstraints.contains(.ports) {
            nodeContext.insidePortLabelCells[.NORTH]?.contributesToMinimumWidth = true
            nodeContext.insidePortLabelCells[.SOUTH]?.contributesToMinimumWidth = true

            let freePortPlacement = nodeContext.portConstraints != .fixedRatio &&
                                    nodeContext.portConstraints != .fixedPos

            nodeContext.insidePortLabelCells[.EAST]?.contributesToMinimumHeight = freePortPlacement
            nodeContext.insidePortLabelCells[.WEST]?.contributesToMinimumHeight = freePortPlacement

            nodeContext.nodeContainerMiddleRow.contributesToMinimumHeight = freePortPlacement

            if nodeContext.sizeConstraints.contains(.portLabels) {
                nodeContext.insidePortLabelCells[.NORTH]?.contributesToMinimumHeight = true
                nodeContext.insidePortLabelCells[.SOUTH]?.contributesToMinimumHeight = true
                nodeContext.insidePortLabelCells[.EAST]?.contributesToMinimumWidth = true
                nodeContext.insidePortLabelCells[.WEST]?.contributesToMinimumWidth = true

                nodeContext.nodeContainerMiddleRow.contributesToMinimumWidth = true
            }
        }

        if nodeContext.sizeConstraints.contains(.nodeLabels) {
            if let container = nodeContext.insideNodeLabelContainer {
                container.contributesToMinimumHeight = true
                container.contributesToMinimumWidth = true
            }

            nodeContext.nodeContainerMiddleRow.contributesToMinimumHeight = true
            nodeContext.nodeContainerMiddleRow.contributesToMinimumWidth = true

            let overhang = nodeContext.sizeOptions.contains(.outsideNodeLabelsOverhang)
            for location in NodeLabelLocation.allCases {
                guard let labelCell = nodeContext.nodeLabelCells[location] else { continue }
                if location.isInsideLocation() {
                    labelCell.contributesToMinimumHeight = true
                    labelCell.contributesToMinimumWidth = true
                } else {
                    labelCell.contributesToMinimumHeight = !overhang
                    labelCell.contributesToMinimumWidth = !overhang
                }
            }
        }

        if nodeContext.sizeConstraints.contains(.minimumSize) &&
           nodeContext.sizeOptions.contains(.minimumSizeAccountsForPadding) {

            nodeContext.nodeContainerMiddleRow.contributesToMinimumHeight = true
            nodeContext.nodeContainerMiddleRow.contributesToMinimumWidth = true

            if let container = nodeContext.insideNodeLabelContainer {
                if !container.contributesToMinimumHeight {
                    container.contributesToMinimumHeight = true
                    container.contributesToMinimumWidth = true
                    container.onlyCenterCellContributesToMinimumSize = true
                }
            }
        }
    }

    // MARK: - Update East and West Inside Port Label Cells

    package static func updateVerticalInsidePortLabelCellPadding(_ nodeContext: NodeContext) {
        if nodeContext.portConstraints == .fixedRatio ||
           nodeContext.portConstraints == .fixedPos {
            return
        }

        let topBorderOffset = nodeContext.nodeContainer.padding.top +
                              (nodeContext.insidePortLabelCells[.NORTH]?.getMinimumHeight() ?? 0) +
                              nodeContext.labelCellSpacing
        let bottomBorderOffset = nodeContext.nodeContainer.padding.bottom +
                                 (nodeContext.insidePortLabelCells[.SOUTH]?.getMinimumHeight() ?? 0) +
                                 nodeContext.labelCellSpacing

        guard let eastCell = nodeContext.insidePortLabelCells[.EAST],
              let westCell = nodeContext.insidePortLabelCells[.WEST] else { return }

        var topPadding = max(0, eastCell.padding.top - topBorderOffset)
        topPadding = max(topPadding, westCell.padding.top - topBorderOffset)
        var bottomPadding = max(0, eastCell.padding.bottom - bottomBorderOffset)
        bottomPadding = max(bottomPadding, westCell.padding.bottom - bottomBorderOffset)

        eastCell.padding.top = topPadding
        westCell.padding.top = topPadding
        eastCell.padding.bottom = bottomPadding
        westCell.padding.bottom = bottomPadding
    }
}
