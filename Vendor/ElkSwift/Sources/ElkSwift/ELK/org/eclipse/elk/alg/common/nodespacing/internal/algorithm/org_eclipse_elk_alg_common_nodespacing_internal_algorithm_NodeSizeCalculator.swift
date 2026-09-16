import Foundation

/**
 * Configures the cell system according to the node size constraints and determines the ultimate node size.
 */
package final class NodeSizeCalculator {

    private init() {}

    // MARK: - Node Width

    package static func setNodeWidth(_ nodeContext: NodeContext) {
        let nodeSize = nodeContext.nodeSize
        var width: Double

        if NodeLabelAndSizeUtilities.areSizeConstraintsFixed(nodeContext) {
            width = nodeSize.x
        } else {
            if nodeContext.topdownLayout {
                width = max(nodeSize.x, nodeContext.nodeContainer.getMinimumWidth())
            } else {
                width = nodeContext.nodeContainer.getMinimumWidth()
            }

            if nodeContext.sizeConstraints.contains(.nodeLabels),
               !nodeContext.sizeOptions.contains(.outsideNodeLabelsOverhang) {

                if let northContainer = nodeContext.outsideNodeLabelContainers[.NORTH] {
                    width = max(width, northContainer.getMinimumWidth())
                }
                if let southContainer = nodeContext.outsideNodeLabelContainers[.SOUTH] {
                    width = max(width, southContainer.getMinimumWidth())
                }
            }

            if let minNodeSize = NodeLabelAndSizeUtilities.getMinimumNodeSize(nodeContext) {
                width = max(width, minNodeSize.x)
            }
        }

        // Set the node's width
        let graph = nodeContext.node.getGraph()
        let fixedGraphSize: Bool = graph?.getProperty(CoreOptions.NODE_SIZE_FIXED_GRAPH_SIZE) ?? false
        if fixedGraphSize {
            nodeSize.x = max(nodeSize.x, width)
        } else {
            nodeSize.x = width
        }

        let nodeCellRectangle = nodeContext.nodeContainer.cellRectangle
        nodeCellRectangle.x = 0
        nodeCellRectangle.width = width

        nodeContext.nodeContainer.layoutChildrenHorizontally()
    }

    // MARK: - Node Height

    package static func setNodeHeight(_ nodeContext: NodeContext) {
        let nodeSize = nodeContext.nodeSize
        var height: Double

        if NodeLabelAndSizeUtilities.areSizeConstraintsFixed(nodeContext) {
            height = nodeSize.y
        } else {
            if nodeContext.topdownLayout {
                height = max(nodeSize.y, nodeContext.nodeContainer.getMinimumHeight())
            } else {
                height = nodeContext.nodeContainer.getMinimumHeight()
            }

            if nodeContext.sizeConstraints.contains(.nodeLabels),
               !nodeContext.sizeOptions.contains(.outsideNodeLabelsOverhang) {

                if let eastContainer = nodeContext.outsideNodeLabelContainers[.EAST] {
                    height = max(height, eastContainer.getMinimumHeight())
                }
                if let westContainer = nodeContext.outsideNodeLabelContainers[.WEST] {
                    height = max(height, westContainer.getMinimumHeight())
                }
            }

            if let minNodeSize = NodeLabelAndSizeUtilities.getMinimumNodeSize(nodeContext) {
                height = max(height, minNodeSize.y)
            }

            if nodeContext.sizeConstraints.contains(.ports) {
                if nodeContext.portConstraints == .fixedRatio || nodeContext.portConstraints == .fixedPos {
                    if let eastCell = nodeContext.insidePortLabelCells[.EAST] {
                        height = max(height, eastCell.getMinimumHeight())
                    }
                    if let westCell = nodeContext.insidePortLabelCells[.WEST] {
                        height = max(height, westCell.getMinimumHeight())
                    }
                }
            }
        }

        // Set the node's height
        let graph = nodeContext.node.getGraph()
        let fixedGraphSize: Bool = graph?.getProperty(CoreOptions.NODE_SIZE_FIXED_GRAPH_SIZE) ?? false
        if fixedGraphSize {
            nodeSize.y = max(nodeSize.y, height)
        } else {
            nodeSize.y = height
        }

        let nodeCellRectangle = nodeContext.nodeContainer.cellRectangle
        nodeCellRectangle.y = 0
        nodeCellRectangle.height = height

        nodeContext.nodeContainer.layoutChildrenVertically()
    }
}
