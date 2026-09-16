import Foundation

/**
 * Various little methods that didn't quite fit into any of the other classes.
 */
package final class NodeLabelAndSizeUtilities {

    private init() {}

    // MARK: - Algorithm Phase Implementation Fragments

    package static func setupMinimumClientAreaSize(_ nodeContext: NodeContext) {
        let minSize = getMinimumClientAreaSize(nodeContext)
        if let minSize = minSize, let container = nodeContext.insideNodeLabelContainer {
            container.setCenterCellMinimumSize(minSize)
        }
    }

    package static func setupNodePaddingForPortsWithOffset(_ nodeContext: NodeContext) {
        let nodeCellPadding = nodeContext.nodeContainer.getPadding()

        for portContextList in nodeContext.portContexts.values {
            for portContext in portContextList {
                var portBorderOffset = 0.0
                if portContext.port.hasProperty(CoreOptions.PORT_BORDER_OFFSET) {
                    portBorderOffset = portContext.port.getProperty(CoreOptions.PORT_BORDER_OFFSET) ?? 0.0

                    if portBorderOffset < 0 {
                        switch portContext.port.getSide() {
                        case .NORTH:
                            nodeCellPadding.top = max(nodeCellPadding.top, -portBorderOffset)
                        case .SOUTH:
                            nodeCellPadding.bottom = max(nodeCellPadding.bottom, -portBorderOffset)
                        case .EAST:
                            nodeCellPadding.right = max(nodeCellPadding.right, -portBorderOffset)
                        case .WEST:
                            nodeCellPadding.left = max(nodeCellPadding.left, -portBorderOffset)
                        default: break
                        }
                    }
                }
                if PortLabelPlacement.isFixed(nodeContext.portLabelsPlacement) {
                    let insidePart = ElkUtil.computeInsidePart(portContext.port, portBorderOffset)
                    let sizeOpts: SizeOptions = nodeContext.node.getProperty(CoreOptions.NODE_SIZE_OPTIONS) ?? SizeOptions()
                    let symmetry = !sizeOpts.contains(.asymmetrical)
                    var insidePartIsBigger = false
                    switch portContext.port.getSide() {
                    case .NORTH:
                        insidePartIsBigger = insidePart > nodeCellPadding.top
                        nodeCellPadding.top = max(nodeCellPadding.top, insidePart)
                        if symmetry && insidePartIsBigger {
                            nodeCellPadding.top = max(nodeCellPadding.top, nodeCellPadding.bottom)
                            nodeCellPadding.bottom = nodeCellPadding.top + portBorderOffset
                        }

                    case .SOUTH:
                        insidePartIsBigger = insidePart > nodeCellPadding.bottom
                        nodeCellPadding.bottom = max(nodeCellPadding.bottom, insidePart)
                        if symmetry && insidePartIsBigger {
                            nodeCellPadding.bottom = max(nodeCellPadding.bottom, nodeCellPadding.top)
                            nodeCellPadding.top = nodeCellPadding.bottom + portBorderOffset
                        }

                    case .EAST:
                        insidePartIsBigger = insidePart > nodeCellPadding.right
                        nodeCellPadding.right = max(nodeCellPadding.right, insidePart)
                        if symmetry && insidePartIsBigger {
                            nodeCellPadding.right = max(nodeCellPadding.left, nodeCellPadding.right)
                            nodeCellPadding.left = nodeCellPadding.right + portBorderOffset
                        }

                    case .WEST:
                        insidePartIsBigger = insidePart > nodeCellPadding.left
                        nodeCellPadding.left = max(nodeCellPadding.left, insidePart)
                        if symmetry && insidePartIsBigger {
                            nodeCellPadding.left = max(nodeCellPadding.left, nodeCellPadding.right)
                            nodeCellPadding.right = nodeCellPadding.left + portBorderOffset
                        }
                    default: break
                    }
                }
            }
        }
    }

    package static func offsetSouthernPortsByNodeSize(_ nodeContext: NodeContext) {
        let nodeHeight = nodeContext.nodeSize.y

        for portContext in nodeContext.portContexts[.SOUTH] ?? [] {
            portContext.portPosition.y += nodeHeight
        }
    }

    package static func setNodePadding(_ nodeContext: NodeContext) {
        guard nodeContext.sizeOptions.contains(.computePadding) else { return }

        let nodeRect = nodeContext.nodeContainer.getCellRectangle()
        guard let container = nodeContext.insideNodeLabelContainer else { return }
        let clientArea = container.getCenterCellRectangle()
        let nodePadding = ElkPadding()

        nodePadding.left = clientArea.x - nodeRect.x
        nodePadding.top = clientArea.y - nodeRect.y
        nodePadding.right = (nodeRect.x + nodeRect.width) - (clientArea.x + clientArea.width)
        nodePadding.bottom = (nodeRect.y + nodeRect.height) - (clientArea.y + clientArea.height)

        nodeContext.node.setPadding(nodePadding)
    }

    package static func applyStuff(_ nodeContext: NodeContext) {
        nodeContext.applyNodeSize()
        for portContextList in nodeContext.portContexts.values {
            for pc in portContextList {
                pc.applyPortPosition()
            }
        }
    }

    // MARK: - Minimum Size Things

    package static func getMinimumClientAreaSize(_ nodeContext: NodeContext) -> KVector? {
        if nodeContext.sizeConstraints.contains(.minimumSize)
                && nodeContext.sizeOptions.contains(.minimumSizeAccountsForPadding) {
            return getMinimumNodeOrClientAreaSize(nodeContext)
        } else {
            return nil
        }
    }

    package static func getMinimumNodeSize(_ nodeContext: NodeContext) -> KVector? {
        if nodeContext.sizeConstraints.contains(.minimumSize) {
            if !nodeContext.sizeOptions.contains(.minimumSizeAccountsForPadding) {
                return getMinimumNodeOrClientAreaSize(nodeContext)
            }
        }
        return nil
    }

    package static func getMinimumNodeOrClientAreaSize(_ nodeContext: NodeContext) -> KVector {
        let rawMinSize: KVector? = nodeContext.node.getProperty(CoreOptions.NODE_SIZE_MINIMUM)
        var minSize = KVector(rawMinSize ?? KVector())

        if nodeContext.sizeOptions.contains(.defaultMinimumSize) {
            if minSize.x <= 0 {
                minSize.x = ElkUtil.DEFAULT_MIN_WIDTH
            }
            if minSize.y <= 0 {
                minSize.y = ElkUtil.DEFAULT_MIN_HEIGHT
            }
        }

        return minSize
    }


    // MARK: - Utilities

    package static let EFFECTIVELY_FIXED_SIZE_CONSTRAINTS: SizeConstraint = [.portLabels]

    package static func areSizeConstraintsFixed(_ nodeContext: NodeContext) -> Bool {
        return nodeContext.sizeConstraints.isEmpty
                || (nodeContext.sizeConstraints == EFFECTIVELY_FIXED_SIZE_CONSTRAINTS)
    }

    package static func isFirstOutsidePortLabelPlacedDifferently(_ nodeContext: NodeContext,
            _ portSide: PortSide) -> Bool {

        guard let portContexts = nodeContext.portContexts[portSide], portContexts.count >= 2 else {
            return false
        }

        guard let firstPort = portContexts.first else { return false }

        let alwaysSameSide = nodeContext.portLabelsPlacement.contains(.alwaysSameSide)
        let spaceEfficient = nodeContext.portLabelsPlacement.contains(.spaceEfficient)

        return !firstPort.labelsNextToPort && !alwaysSameSide
                && (portContexts.count == 2 || spaceEfficient)
    }
}
