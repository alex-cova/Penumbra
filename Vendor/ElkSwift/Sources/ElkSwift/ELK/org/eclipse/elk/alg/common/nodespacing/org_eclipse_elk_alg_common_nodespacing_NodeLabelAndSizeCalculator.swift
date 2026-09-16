import Foundation

/**
 * Knows how to calculate the size of a node and how to place its ports.
 */
package final class NodeLabelAndSizeCalculator {

    private init() {}

    /**
     * Processes all direct children of the given graph.
     */
    package static func process(_ graph: GraphAdapter) {
        graph.getNodes().forEach { node in
            let _ = process(graph, node, true, false)
        }
    }

    /**
     * Processes the given node which is assumed to be a child of the given graph.
     */
    @discardableResult
    package static func process(_ graph: GraphAdapter, _ node: NodeAdapter, _ applyStuff: Bool,
            _ ignoreInsidePortLabels: Bool) -> KVector {

        let nodeContext = NodeContext(parentGraph: graph, node: node)

        PortContextCreator.createPortContexts(nodeContext, ignoreInsidePortLabels: ignoreInsidePortLabels)

        // PHASE 1: Setup All Cells
        var horizontalLayoutMode = true
        let layoutDirection: Direction? = graph.getProperty(CoreOptions.DIRECTION)
        if let dir = layoutDirection {
            horizontalLayoutMode = (dir == .UNDEFINED) || dir.isHorizontal()
        }

        NodeLabelCellCreator.createNodeLabelCells(nodeContext, false, horizontalLayoutMode)
        InsidePortLabelCellCreator.createInsidePortLabelCells(nodeContext)

        // PHASE 2: Setup Client Area Space and Node Cell Padding
        NodeLabelAndSizeUtilities.setupMinimumClientAreaSize(nodeContext)
        NodeLabelAndSizeUtilities.setupNodePaddingForPortsWithOffset(nodeContext)

        // PHASE 3: Minimum Space Required to Place Ports
        HorizontalPortPlacementSizeCalculator.calculateHorizontalPortPlacementSize(nodeContext)
        VerticalPortPlacementSizeCalculator.calculateVerticalPortPlacementSize(nodeContext)

        // PHASE 4: Setup Cell System Size Contribution Flags
        CellSystemConfigurator.configureCellSystemSizeContributions(nodeContext)

        // PHASE 5: Set Node Width and Place Horizontal Ports
        NodeSizeCalculator.setNodeWidth(nodeContext)
        PortPlacementCalculator.placeHorizontalPorts(nodeContext)
        PortLabelPlacementCalculator.placeHorizontalPortLabels(nodeContext)

        // PHASE 6: Set Node Height and Place Vertical Ports
        CellSystemConfigurator.updateVerticalInsidePortLabelCellPadding(nodeContext)
        NodeSizeCalculator.setNodeHeight(nodeContext)

        if !applyStuff {
            return nodeContext.nodeSize
        }

        NodeLabelAndSizeUtilities.offsetSouthernPortsByNodeSize(nodeContext)
        PortPlacementCalculator.placeVerticalPorts(nodeContext)
        PortLabelPlacementCalculator.placeVerticalPortLabels(nodeContext)

        // PHASE 7: Place Labels and Apply Stuff
        LabelPlacer.placeLabels(nodeContext)
        NodeLabelAndSizeUtilities.setNodePadding(nodeContext)
        NodeLabelAndSizeUtilities.applyStuff(nodeContext)

        return nodeContext.nodeSize
    }

    /**
     * Computes the padding required to place inside non-center node labels.
     */
    package static func computeInsideNodeLabelPadding(_ graph: GraphAdapter, _ node: NodeAdapter,
            _ layoutDirection: Direction) -> ElkPadding {

        let nodeContext = NodeContext(parentGraph: graph, node: node)
        NodeLabelCellCreator.createNodeLabelCells(nodeContext, true, !layoutDirection.isVertical())

        guard let labelCellContainer = nodeContext.insideNodeLabelContainer else {
            return ElkPadding()
        }
        var padding = ElkPadding()

        // Top
        for col in ContainerArea.values {
            if let labelCell = labelCellContainer.getCell(.begin, col) {
                padding.top = max(padding.top, labelCell.getMinimumHeight())
            }
        }

        // Bottom
        for col in ContainerArea.values {
            if let labelCell = labelCellContainer.getCell(.end, col) {
                padding.bottom = max(padding.bottom, labelCell.getMinimumHeight())
            }
        }

        // Left
        for row in ContainerArea.values {
            if let labelCell = labelCellContainer.getCell(row, .begin) {
                padding.left = max(padding.left, labelCell.getMinimumWidth())
            }
        }

        // Right
        for row in ContainerArea.values {
            if let labelCell = labelCellContainer.getCell(row, .end) {
                padding.right = max(padding.right, labelCell.getMinimumWidth())
            }
        }

        // Apply insets and gap where necessary
        if padding.top > 0 {
            padding.top += labelCellContainer.getPadding().top
            padding.top += labelCellContainer.getGap()
        }

        if padding.bottom > 0 {
            padding.bottom += labelCellContainer.getPadding().bottom
            padding.bottom += labelCellContainer.getGap()
        }

        if padding.left > 0 {
            padding.left += labelCellContainer.getPadding().left
            padding.left += labelCellContainer.getGap()
        }

        if padding.right > 0 {
            padding.right += labelCellContainer.getPadding().right
            padding.right += labelCellContainer.getGap()
        }

        return padding
    }
}
