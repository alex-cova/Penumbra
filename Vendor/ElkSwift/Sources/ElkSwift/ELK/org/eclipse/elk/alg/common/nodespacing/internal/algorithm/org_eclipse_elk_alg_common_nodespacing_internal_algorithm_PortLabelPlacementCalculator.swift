import Foundation

/**
 * Knows how to place port labels.
 */
package final class PortLabelPlacementCalculator {

    private init() {}

    package static func placeHorizontalPortLabels(_ nodeContext: NodeContext) {
        placePortLabels(nodeContext, .NORTH)
        placePortLabels(nodeContext, .SOUTH)
    }

    package static func placeVerticalPortLabels(_ nodeContext: NodeContext) {
        placePortLabels(nodeContext, .EAST)
        placePortLabels(nodeContext, .WEST)
    }

    package static func placePortLabels(_ nodeContext: NodeContext, _ portSide: PortSide) {
        let constrainedPlacement = !nodeContext.sizeConstraints.contains(.portLabels)
                || nodeContext.portConstraints == .fixedPos

        if nodeContext.portLabelsPlacement.contains(.inside) {
            if constrainedPlacement {
                constrainedInsidePortLabelPlacement(nodeContext, portSide)
            } else {
                simpleInsidePortLabelPlacement(nodeContext, portSide)
            }
        } else if nodeContext.portLabelsPlacement.contains(.outside) {
            if constrainedPlacement {
                constrainedOutsidePortLabelPlacement(nodeContext, portSide)
            } else {
                simpleOutsidePortLabelPlacement(nodeContext, portSide)
            }
        }
    }

    // MARK: - Simple Inside Port Labels

    package static func simpleInsidePortLabelPlacement(_ nodeContext: NodeContext, _ portSide: PortSide) {
        var insideNorthOrSouthPortLabelAreaHeight: Double = 0

        let labelBorderOffset = portLabelBorderOffsetForPortSide(nodeContext, portSide)
        let portLabelSpacingHorizontal = nodeContext.portLabelSpacingHorizontal
        let portLabelSpacingVertical = nodeContext.portLabelSpacingVertical

        for portContext in nodeContext.portContexts[portSide] ?? [] {
            guard let portLabelCell = portContext.portLabelCell, portLabelCell.hasLabels() else {
                continue
            }

            let portSize = portContext.port.getSize()
            let portBorderOffset: Double = portContext.port.hasProperty(CoreOptions.PORT_BORDER_OFFSET)
                    ? (portContext.port.getProperty(CoreOptions.PORT_BORDER_OFFSET) ?? 0)
                    : 0

            let portLabelCellRect = portLabelCell.cellRectangle
            portLabelCellRect.width = portLabelCell.getMinimumWidth()
            portLabelCellRect.height = portLabelCell.getMinimumHeight()

            switch portSide {
            case .NORTH:
                portLabelCellRect.x = portContext.labelsNextToPort
                        ? (portSize.x - portLabelCellRect.width) / 2
                        : portSize.x + portLabelSpacingHorizontal
                portLabelCellRect.y = portSize.y + portBorderOffset + labelBorderOffset
                portLabelCell.setHorizontalAlignment(.center)
                portLabelCell.setVerticalAlignment(.top)

            case .SOUTH:
                portLabelCellRect.x = portContext.labelsNextToPort
                        ? (portSize.x - portLabelCellRect.width) / 2
                        : portSize.x + portLabelSpacingHorizontal
                portLabelCellRect.y = -portBorderOffset - labelBorderOffset - portLabelCellRect.height
                portLabelCell.setHorizontalAlignment(.center)
                portLabelCell.setVerticalAlignment(.bottom)

            case .EAST:
                portLabelCellRect.x = -portBorderOffset - labelBorderOffset - portLabelCellRect.width
                if portContext.labelsNextToPort {
                    let labelHeight = nodeContext.portLabelsTreatAsGroup
                            ? portLabelCellRect.height
                            : portLabelCell.labels.first?.getSize().y ?? 0
                    portLabelCellRect.y = (portSize.y - labelHeight) / 2
                } else {
                    portLabelCellRect.y = portSize.y + portLabelSpacingVertical
                }
                portLabelCell.setHorizontalAlignment(.right)
                portLabelCell.setVerticalAlignment(.center)

            case .WEST:
                portLabelCellRect.x = portSize.x + portBorderOffset + labelBorderOffset
                if portContext.labelsNextToPort {
                    let labelHeight = nodeContext.portLabelsTreatAsGroup
                            ? portLabelCellRect.height
                            : portLabelCell.labels.first?.getSize().y ?? 0
                    portLabelCellRect.y = (portSize.y - labelHeight) / 2
                } else {
                    portLabelCellRect.y = portSize.y + portLabelSpacingVertical
                }
                portLabelCell.setHorizontalAlignment(.left)
                portLabelCell.setVerticalAlignment(.center)
            default: break
            }

            if portSide == .NORTH || portSide == .SOUTH {
                insideNorthOrSouthPortLabelAreaHeight = max(
                        insideNorthOrSouthPortLabelAreaHeight,
                        portLabelCellRect.height)
            }
        }

        if insideNorthOrSouthPortLabelAreaHeight > 0 {
            nodeContext.insidePortLabelCells[portSide]?.minimumContentAreaSize.y = insideNorthOrSouthPortLabelAreaHeight
        }
    }

    package static func portLabelBorderOffsetForPortSide(_ nodeContext: NodeContext, _ portSide: PortSide) -> Double {
        switch portSide {
        case .NORTH:
            return nodeContext.nodeContainer.padding.top + nodeContext.portLabelSpacingVertical
        case .SOUTH:
            return nodeContext.nodeContainer.padding.bottom + nodeContext.portLabelSpacingVertical
        case .EAST:
            return nodeContext.nodeContainer.padding.right + nodeContext.portLabelSpacingHorizontal
        case .WEST:
            return nodeContext.nodeContainer.padding.left + nodeContext.portLabelSpacingHorizontal
        default:
            return 0
        }
    }

    // MARK: - Constrained Inside Port Labels

    package static func constrainedInsidePortLabelPlacement(_ nodeContext: NodeContext, _ portSide: PortSide) {
        guard let portContexts = nodeContext.portContexts[portSide] else { return }

        if portSide == .EAST || portSide == .WEST {
            simpleInsidePortLabelPlacement(nodeContext, portSide)
            return
        }

        let overlapRemovalDirection: RectangleStripOverlapRemover.OverlapRemovalDirection = portSide == .NORTH
                ? .down
                : .up
        let verticalLabelAlignment: VerticalLabelAlignment = portSide == .NORTH
                ? .top
                : .bottom

        guard let insidePortLabelContainer = nodeContext.insidePortLabelCells[portSide] else { return }
        let labelContainerRect = insidePortLabelContainer.cellRectangle
        let leftBorder = labelContainerRect.x + max(
                insidePortLabelContainer.padding.left,
                nodeContext.surroundingPortMargins.left,
                nodeContext.nodeLabelSpacing)
        let rightBorder = labelContainerRect.x + labelContainerRect.width - max(
                insidePortLabelContainer.padding.right,
                nodeContext.surroundingPortMargins.right,
                nodeContext.nodeLabelSpacing)

        let overlapRemover = RectangleStripOverlapRemover.create(for: overlapRemovalDirection)
                .withGap(nodeContext.portLabelSpacingHorizontal, nodeContext.portLabelSpacingVertical)

        let startCoordinate: Double = portSide == .NORTH
                ? -Double.greatestFiniteMagnitude
                : Double.greatestFiniteMagnitude

        var currentStartCoordinate = startCoordinate

        for portContext in portContexts {
            guard let portLabelCell = portContext.portLabelCell, portLabelCell.hasLabels() else {
                continue
            }

            let portSize = portContext.port.getSize()
            let portPosition = portContext.portPosition
            let portLabelCellRect = portLabelCell.cellRectangle
            portLabelCellRect.width = portLabelCell.getMinimumWidth()
            portLabelCellRect.height = portLabelCell.getMinimumHeight()

            portLabelCell.setVerticalAlignment(verticalLabelAlignment)
            portLabelCell.setHorizontalAlignment(.right)

            centerPortLabel(portLabelCellRect, portPosition, portSize, leftBorder, rightBorder)

            overlapRemover.addRectangle(portLabelCellRect)

            currentStartCoordinate = portSide == .NORTH
                    ? max(currentStartCoordinate, portPosition.y + portContext.port.getSize().y)
                    : min(currentStartCoordinate, portPosition.y)
        }

        let adjustedStartCoordinate = currentStartCoordinate + (portSide == .NORTH
                ? nodeContext.portLabelSpacingVertical
                : -nodeContext.portLabelSpacingVertical)

        let stripHeight = overlapRemover
            .withStartCoordinate(adjustedStartCoordinate)
            .removeOverlaps()

        if stripHeight > 0 {
            nodeContext.insidePortLabelCells[portSide]?.minimumContentAreaSize.y = stripHeight
        }

        for portContext in portContexts {
            guard let portLabelCell = portContext.portLabelCell, portLabelCell.hasLabels() else {
                continue
            }

            let rect = portLabelCell.cellRectangle
            rect.x -= portContext.portPosition.x
            rect.y -= portContext.portPosition.y
        }
    }

    package static func centerPortLabel(_ portLabelCellRect: ElkRectangle, _ portPosition: KVector,
            _ portSize: KVector, _ minX: Double, _ maxX: Double) {

        portLabelCellRect.x = portPosition.x - (portLabelCellRect.width - portSize.x) / 2

        let actualMinX = min(minX, portPosition.x)
        let actualMaxX = max(maxX, portPosition.x + portSize.x)

        if portLabelCellRect.x < actualMinX {
            portLabelCellRect.x = actualMinX
        } else if portLabelCellRect.x + portLabelCellRect.width > actualMaxX {
            portLabelCellRect.x = actualMaxX - portLabelCellRect.width
        }
    }

    // MARK: - Simple Outside Port Labels

    package static func simpleOutsidePortLabelPlacement(_ nodeContext: NodeContext, _ portSide: PortSide) {
        guard let portContexts = nodeContext.portContexts[portSide] else { return }

        let placeFirstPortDifferently = NodeLabelAndSizeUtilities.isFirstOutsidePortLabelPlacedDifferently(
                nodeContext, portSide)

        let alwaysAbove = nodeContext.portLabelsPlacement.contains(.alwaysOtherSameSide)

        var shouldPlaceFirstPortDifferently = placeFirstPortDifferently

        for portContext in portContexts {
            guard let portLabelCell = portContext.portLabelCell, portLabelCell.hasLabels() else {
                continue
            }

            let portSize = portContext.port.getSize()

            let portLabelCellRect = portLabelCell.cellRectangle
            portLabelCellRect.width = portLabelCell.getMinimumWidth()
            portLabelCellRect.height = portLabelCell.getMinimumHeight()

            switch portSide {
            case .NORTH:
                if portContext.labelsNextToPort {
                    portLabelCellRect.x = (portSize.x - portLabelCellRect.width) / 2
                    portLabelCell.setHorizontalAlignment(.center)
                } else if shouldPlaceFirstPortDifferently || alwaysAbove {
                    portLabelCellRect.x = -portLabelCellRect.width - nodeContext.portLabelSpacingHorizontal
                    portLabelCell.setHorizontalAlignment(.right)
                } else {
                    portLabelCellRect.x = portSize.x + nodeContext.portLabelSpacingHorizontal
                    portLabelCell.setHorizontalAlignment(.left)
                }
                portLabelCellRect.y = -portLabelCellRect.height - nodeContext.portLabelSpacingVertical
                portLabelCell.setVerticalAlignment(.bottom)

            case .SOUTH:
                if portContext.labelsNextToPort {
                    portLabelCellRect.x = (portSize.x - portLabelCellRect.width) / 2
                    portLabelCell.setHorizontalAlignment(.center)
                } else if shouldPlaceFirstPortDifferently || alwaysAbove {
                    portLabelCellRect.x = -portLabelCellRect.width - nodeContext.portLabelSpacingHorizontal
                    portLabelCell.setHorizontalAlignment(.right)
                } else {
                    portLabelCellRect.x = portSize.x + nodeContext.portLabelSpacingHorizontal
                    portLabelCell.setHorizontalAlignment(.left)
                }
                portLabelCellRect.y = portSize.y + nodeContext.portLabelSpacingVertical
                portLabelCell.setVerticalAlignment(.top)

            case .EAST:
                if portContext.labelsNextToPort {
                    let labelHeight = nodeContext.portLabelsTreatAsGroup
                            ? portLabelCellRect.height
                            : portLabelCell.labels.first?.getSize().y ?? 0
                    portLabelCellRect.y = (portSize.y - labelHeight) / 2
                    portLabelCell.setVerticalAlignment(.center)
                } else if shouldPlaceFirstPortDifferently || alwaysAbove {
                    portLabelCellRect.y = -portLabelCellRect.height - nodeContext.portLabelSpacingVertical
                    portLabelCell.setVerticalAlignment(.bottom)
                } else {
                    portLabelCellRect.y = portSize.y + nodeContext.portLabelSpacingVertical
                    portLabelCell.setVerticalAlignment(.top)
                }
                portLabelCellRect.x = portSize.x + nodeContext.portLabelSpacingHorizontal
                portLabelCell.setHorizontalAlignment(.left)

            case .WEST:
                if portContext.labelsNextToPort {
                    let labelHeight = nodeContext.portLabelsTreatAsGroup
                            ? portLabelCellRect.height
                            : portLabelCell.labels.first?.getSize().y ?? 0
                    portLabelCellRect.y = (portSize.y - labelHeight) / 2
                    portLabelCell.setVerticalAlignment(.center)
                } else if shouldPlaceFirstPortDifferently || alwaysAbove {
                    portLabelCellRect.y = -portLabelCellRect.height - nodeContext.portLabelSpacingVertical
                    portLabelCell.setVerticalAlignment(.bottom)
                } else {
                    portLabelCellRect.y = portSize.y + nodeContext.portLabelSpacingVertical
                    portLabelCell.setVerticalAlignment(.top)
                }
                portLabelCellRect.x = -portLabelCellRect.width - nodeContext.portLabelSpacingHorizontal
                portLabelCell.setHorizontalAlignment(.right)
            default: break
            }

            shouldPlaceFirstPortDifferently = false
        }
    }

    // MARK: - Constrained Outside Port Labels

    package static func constrainedOutsidePortLabelPlacement(_ nodeContext: NodeContext, _ portSide: PortSide) {
        guard let portContexts = nodeContext.portContexts[portSide] else { return }

        if portContexts.count <= 2 || portSide == .EAST || portSide == .WEST {
            simpleOutsidePortLabelPlacement(nodeContext, portSide)
            return
        }

        let portWithSpecialNeeds = nodeContext.portLabelsPlacement.contains(.spaceEfficient)

        let overlapRemovalDirection: RectangleStripOverlapRemover.OverlapRemovalDirection = portSide == .NORTH
                ? .up
                : .down
        let verticalLabelAlignment: VerticalLabelAlignment = portSide == .NORTH
                ? .bottom
                : .top

        let overlapRemover = RectangleStripOverlapRemover.create(for: overlapRemovalDirection)
                .withGap(nodeContext.portLabelSpacingVertical, nodeContext.portLabelSpacingHorizontal)

        let startCoordinate: Double = portSide == .NORTH
                ? Double.greatestFiniteMagnitude
                : -Double.greatestFiniteMagnitude

        var currentStartCoordinate = startCoordinate
        var hasSpecialNeedsPort = portWithSpecialNeeds

        for portContext in portContexts {
            guard let portLabelCell = portContext.portLabelCell, portLabelCell.hasLabels() else {
                continue
            }

            let portSize = portContext.port.getSize()
            let portPosition = portContext.portPosition
            let portLabelCellRect = portLabelCell.cellRectangle
            portLabelCellRect.width = portLabelCell.getMinimumWidth()
            portLabelCellRect.height = portLabelCell.getMinimumHeight()

            if hasSpecialNeedsPort {
                portLabelCellRect.x =
                        portPosition.x - portLabelCell.getMinimumWidth() - nodeContext.portLabelSpacingHorizontal
                hasSpecialNeedsPort = false
            } else {
                portLabelCellRect.x = portPosition.x + portSize.x + nodeContext.portLabelSpacingHorizontal
            }

            portLabelCell.setVerticalAlignment(verticalLabelAlignment)
            portLabelCell.setHorizontalAlignment(.right)

            overlapRemover.addRectangle(portLabelCellRect)

            currentStartCoordinate = portSide == .NORTH
                    ? min(currentStartCoordinate, portPosition.y)
                    : max(currentStartCoordinate, portPosition.y + portContext.port.getSize().y)
        }

        let adjustedStartCoordinate = currentStartCoordinate + (portSide == .NORTH
                ? -nodeContext.portLabelSpacingVertical
                : nodeContext.portLabelSpacingVertical)

        overlapRemover
            .withStartCoordinate(adjustedStartCoordinate)
            .removeOverlaps()

        for portContext in portContexts {
            guard let portLabelCell = portContext.portLabelCell, portLabelCell.hasLabels() else {
                continue
            }

            let rect = portLabelCell.cellRectangle
            rect.x -= portContext.portPosition.x
            rect.y -= portContext.portPosition.y
        }
    }
}
