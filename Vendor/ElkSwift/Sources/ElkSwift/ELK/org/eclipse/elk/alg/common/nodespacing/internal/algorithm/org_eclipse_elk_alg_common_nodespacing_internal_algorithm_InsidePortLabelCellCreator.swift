import Foundation

/**
 * Sets up the inside port label cells.
 */
package final class InsidePortLabelCellCreator {

    private init() {}

    // MARK: - Public Methods

    package static func createInsidePortLabelCells(_ nodeContext: NodeContext) {
        createInsidePortLabelCell(nodeContext, nodeContext.nodeContainer, .begin, .NORTH)
        createInsidePortLabelCell(nodeContext, nodeContext.nodeContainer, .end, .SOUTH)

        createInsidePortLabelCell(nodeContext, nodeContext.nodeContainerMiddleRow, .begin, .WEST)
        createInsidePortLabelCell(nodeContext, nodeContext.nodeContainerMiddleRow, .end, .EAST)

        setupNorthOrSouthPortLabelCell(nodeContext, .NORTH)
        setupNorthOrSouthPortLabelCell(nodeContext, .SOUTH)
        setupEastOrWestPortLabelCell(nodeContext, .EAST)
        setupEastOrWestPortLabelCell(nodeContext, .WEST)
    }

    // MARK: - Private Methods

    package static func createInsidePortLabelCell(_ nodeContext: NodeContext,
                                                   _ container: StripContainerCell,
                                                   _ containerArea: ContainerArea,
                                                   _ portSide: PortSide) {
        let portLabelCell = AtomicCell()
        container.setCell(containerArea, cell: portLabelCell)
        nodeContext.insidePortLabelCells[portSide] = portLabelCell
    }

    // MARK: - North or South

    package static func setupNorthOrSouthPortLabelCell(_ nodeContext: NodeContext, _ portSide: PortSide) {
        guard let cell = nodeContext.insidePortLabelCells[portSide] else { return }
        let padding = cell.padding

        switch portSide {
        case .NORTH:
            if nodeContext.portLabelSpacingVertical >= 0 {
                padding.top = nodeContext.portLabelSpacingVertical
            }
        case .SOUTH:
            if nodeContext.portLabelSpacingVertical >= 0 {
                padding.bottom = nodeContext.portLabelSpacingVertical
            }
        default:
            break
        }

        let surroundingPortMargins = nodeContext.surroundingPortMargins
        padding.left = surroundingPortMargins.left
        padding.right = surroundingPortMargins.right
    }

    // MARK: - East or West

    package static func setupEastOrWestPortLabelCell(_ nodeContext: NodeContext, _ portSide: PortSide) {
        if nodeContext.portLabelsPlacement.contains(.inside) {
            calculateWidthDueToLabels(nodeContext, portSide)
        }
        setupTopAndBottomPadding(nodeContext, portSide)
    }

    package static func calculateWidthDueToLabels(_ nodeContext: NodeContext, _ portSide: PortSide) {
        guard let theAppropriateCell = nodeContext.insidePortLabelCells[portSide] else { return }
        let minCellSize = theAppropriateCell.minimumContentAreaSize

        for portContext in nodeContext.portContexts[portSide] ?? [] {
            if let portLabelCell = portContext.portLabelCell {
                minCellSize.x = max(minCellSize.x, portLabelCell.getMinimumWidth())
            }
        }

        if minCellSize.x > 0 {
            switch portSide {
            case .EAST:
                theAppropriateCell.padding.right = nodeContext.portLabelSpacingHorizontal
            case .WEST:
                theAppropriateCell.padding.left = nodeContext.portLabelSpacingHorizontal
            default:
                break
            }
        }
    }

    package static func setupTopAndBottomPadding(_ nodeContext: NodeContext, _ portSide: PortSide) {
        let surroundingPortMargins = nodeContext.surroundingPortMargins
        guard let cell = nodeContext.insidePortLabelCells[portSide] else { return }
        let padding = cell.padding
        padding.top = surroundingPortMargins.top
        padding.bottom = surroundingPortMargins.bottom
    }
}
