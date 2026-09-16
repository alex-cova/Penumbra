import Foundation

/**
 * Knows how to properly size and position outer node label containers and to place node and port labels.
 */
package final class LabelPlacer {

    private init() {}

    /**
     * Places outer node label containers as well as all labels.
     */
    package static func placeLabels(_ nodeContext: NodeContext) {
        placeOuterNodeLabelContainers(nodeContext)

        for (_, labelCell) in nodeContext.nodeLabelCells {
            labelCell.applyLabelLayout()
        }

        for (_, portContextList) in nodeContext.portContexts {
            for pc in portContextList {
                if let portLabelCell = pc.portLabelCell {
                    portLabelCell.applyLabelLayout()
                }
            }
        }
    }

    package static func placeOuterNodeLabelContainers(_ nodeContext: NodeContext) {
        let outerNodeLabelsOverhang = nodeContext.sizeOptions.contains(.outsideNodeLabelsOverhang)

        placeHorizontalOuterNodeLabelContainer(nodeContext, outerNodeLabelsOverhang: outerNodeLabelsOverhang, portSide: .NORTH)
        placeHorizontalOuterNodeLabelContainer(nodeContext, outerNodeLabelsOverhang: outerNodeLabelsOverhang, portSide: .SOUTH)
        placeVerticalOuterNodeLabelContainer(nodeContext, outerNodeLabelsOverhang: outerNodeLabelsOverhang, portSide: .EAST)
        placeVerticalOuterNodeLabelContainer(nodeContext, outerNodeLabelsOverhang: outerNodeLabelsOverhang, portSide: .WEST)
    }

    package static func placeHorizontalOuterNodeLabelContainer(_ nodeContext: NodeContext,
            outerNodeLabelsOverhang: Bool, portSide: PortSide) {

        let nodeSize = nodeContext.nodeSize
        guard let nodeLabelContainer = nodeContext.outsideNodeLabelContainers[portSide] else { return }
        let nodeLabelContainerRect = nodeLabelContainer.cellRectangle

        nodeLabelContainerRect.width = nodeLabelContainer.getMinimumWidth()
        nodeLabelContainerRect.height = nodeLabelContainer.getMinimumHeight()

        nodeLabelContainerRect.width = max(nodeLabelContainerRect.width, nodeSize.x)

        if nodeLabelContainerRect.width > nodeSize.x && !outerNodeLabelsOverhang {
            nodeLabelContainerRect.width = nodeSize.x
        }

        nodeLabelContainerRect.x = -(nodeLabelContainerRect.width - nodeSize.x) / 2.0

        switch portSide {
        case .NORTH:
            nodeLabelContainerRect.y = -nodeLabelContainerRect.height
        case .SOUTH:
            nodeLabelContainerRect.y = nodeSize.y
        default:
            break
        }

        nodeLabelContainer.layoutChildrenHorizontally()
        nodeLabelContainer.layoutChildrenVertically()
    }

    package static func placeVerticalOuterNodeLabelContainer(_ nodeContext: NodeContext,
            outerNodeLabelsOverhang: Bool, portSide: PortSide) {

        let nodeSize = nodeContext.nodeSize
        guard let nodeLabelContainer = nodeContext.outsideNodeLabelContainers[portSide] else { return }
        let nodeLabelContainerRect = nodeLabelContainer.cellRectangle

        nodeLabelContainerRect.width = nodeLabelContainer.getMinimumWidth()
        nodeLabelContainerRect.height = nodeLabelContainer.getMinimumHeight()

        nodeLabelContainerRect.height = max(nodeLabelContainerRect.height, nodeSize.y)

        if nodeLabelContainerRect.height > nodeSize.y && !outerNodeLabelsOverhang {
            nodeLabelContainerRect.height = nodeSize.y
        }

        nodeLabelContainerRect.y = -(nodeLabelContainerRect.height - nodeSize.y) / 2.0

        switch portSide {
        case .WEST:
            nodeLabelContainerRect.x = -nodeLabelContainerRect.width
        case .EAST:
            nodeLabelContainerRect.x = nodeSize.x
        default:
            break
        }

        nodeLabelContainer.layoutChildrenHorizontally()
        nodeLabelContainer.layoutChildrenVertically()
    }
}
