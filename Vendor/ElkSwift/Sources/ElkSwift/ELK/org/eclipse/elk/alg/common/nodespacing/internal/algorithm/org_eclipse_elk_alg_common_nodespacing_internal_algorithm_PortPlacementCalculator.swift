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
 * Actually places ports.
 */
package final class PortPlacementCalculator {

    package static let PORT_RATIO_OR_POSITION: IProperty = Property<Double>(
            "portRatioOrPosition", 0.0)

    private init() {}


    // MARK: - Horizontal Port Placement

    package static func placeHorizontalPorts(_ nodeContext: NodeContext) {
        switch nodeContext.portConstraints {
        case .fixedPos:
            placeHorizontalFixedPosPorts(nodeContext, .NORTH)
            placeHorizontalFixedPosPorts(nodeContext, .SOUTH)

        case .fixedRatio:
            placeHorizontalFixedRatioPorts(nodeContext, .NORTH)
            placeHorizontalFixedRatioPorts(nodeContext, .SOUTH)

        default:
            placeHorizontalFreePorts(nodeContext, .NORTH)
            placeHorizontalFreePorts(nodeContext, .SOUTH)
        }
    }

    package static func placeHorizontalFixedPosPorts(_ nodeContext: NodeContext, _ portSide: PortSide) {
        for portContext in nodeContext.portContexts[portSide] ?? [] {
            portContext.portPosition.y = calculateHorizontalPortYCoordinate(portContext)
        }
    }

    package static func placeHorizontalFixedRatioPorts(_ nodeContext: NodeContext, _ portSide: PortSide) {
        let nodeWidth = nodeContext.nodeSize.x

        for portContext in nodeContext.portContexts[portSide] ?? [] {
            let ratio: Double = portContext.port.getProperty(PORT_RATIO_OR_POSITION) ?? 0.0
            portContext.portPosition.x = nodeWidth * ratio
            portContext.portPosition.y = calculateHorizontalPortYCoordinate(portContext)
        }
    }

    package static func placeHorizontalFreePorts(_ nodeContext: NodeContext, _ portSide: PortSide) {
        guard let portContexts = nodeContext.portContexts[portSide], !portContexts.isEmpty else {
            return
        }

        guard let insidePortLabelCell = nodeContext.insidePortLabelCells[portSide] else { return }
        let insidePortLabelCellRectangle = insidePortLabelCell.getCellRectangle()
        let insidePortLabelCellPadding = insidePortLabelCell.getPadding()

        var portAlignment = nodeContext.getPortAlignment(portSide: portSide)
        var availableSpace = insidePortLabelCellRectangle.width - insidePortLabelCellPadding.left
                - insidePortLabelCellPadding.right
        var calculatedPortPlacementWidth = insidePortLabelCell.getMinimumContentAreaSize().x
        var currentXPos = insidePortLabelCellRectangle.x + insidePortLabelCellPadding.left
        var spaceBetweenPorts = nodeContext.portPortSpacing

        if (portAlignment == .distributed || portAlignment == .justified)
                && portContexts.count == 1 {

            calculatedPortPlacementWidth = modifiedPortPlacementSize(
                    nodeContext, portAlignment, calculatedPortPlacementWidth)
            portAlignment = .center
        }

        if availableSpace < calculatedPortPlacementWidth
                && !nodeContext.sizeOptions.contains(.portsOverhang) {

            if portAlignment == .distributed {
                spaceBetweenPorts += (availableSpace - calculatedPortPlacementWidth)
                        / Double(portContexts.count + 1)
                currentXPos += spaceBetweenPorts

            } else {
                spaceBetweenPorts += (availableSpace - calculatedPortPlacementWidth)
                        / Double(portContexts.count - 1)
            }
        } else {
            if availableSpace < calculatedPortPlacementWidth {
                calculatedPortPlacementWidth = modifiedPortPlacementSize(
                        nodeContext, portAlignment, calculatedPortPlacementWidth)
                portAlignment = .center
            }

            switch portAlignment {
            case .begin:
                break

            case .center:
                currentXPos += (availableSpace - calculatedPortPlacementWidth) / 2

            case .end:
                currentXPos += availableSpace - calculatedPortPlacementWidth

            case .distributed:
                let additionalSpaceBetweenPorts = (availableSpace - calculatedPortPlacementWidth)
                        / Double(portContexts.count + 1)
                spaceBetweenPorts += max(0, additionalSpaceBetweenPorts)
                currentXPos += spaceBetweenPorts

            case .justified:
                let additionalSpaceBetweenPorts = (availableSpace - calculatedPortPlacementWidth)
                        / Double(portContexts.count - 1)
                spaceBetweenPorts += max(0, additionalSpaceBetweenPorts)
            }
        }

        for portContext in portContexts {
            portContext.portPosition.x = currentXPos + portContext.portMargin.left
            portContext.portPosition.y = calculateHorizontalPortYCoordinate(portContext)
            currentXPos += portContext.portMargin.left
                    + portContext.port.getSize().x
                    + portContext.portMargin.right
                    + spaceBetweenPorts
        }
    }

    package static func calculateHorizontalPortYCoordinate(_ portContext: PortContext) -> Double {
        let port = portContext.port

        if port.hasProperty(CoreOptions.PORT_BORDER_OFFSET) {
            let offset: Double = port.getProperty(CoreOptions.PORT_BORDER_OFFSET) ?? 0.0
            return port.getSide() == .NORTH
                    ? -port.getSize().y - offset
                    : offset
        } else {
            return port.getSide() == .NORTH
                    ? -port.getSize().y
                    : 0
        }
    }


    // MARK: - Vertical Port Placement

    package static func placeVerticalPorts(_ nodeContext: NodeContext) {
        switch nodeContext.portConstraints {
        case .fixedPos:
            placeVerticalFixedPosPorts(nodeContext, .EAST)
            placeVerticalFixedPosPorts(nodeContext, .WEST)

        case .fixedRatio:
            placeVerticalFixedRatioPorts(nodeContext, .EAST)
            placeVerticalFixedRatioPorts(nodeContext, .WEST)

        default:
            placeVerticalFreePorts(nodeContext, .EAST)
            placeVerticalFreePorts(nodeContext, .WEST)
        }
    }

    package static func placeVerticalFixedPosPorts(_ nodeContext: NodeContext, _ portSide: PortSide) {
        let nodeWidth = nodeContext.nodeSize.x

        for portContext in nodeContext.portContexts[portSide] ?? [] {
            portContext.portPosition.x = calculateVerticalPortXCoordinate(portContext, nodeWidth)
        }
    }

    package static func placeVerticalFixedRatioPorts(_ nodeContext: NodeContext, _ portSide: PortSide) {
        let nodeSize = nodeContext.nodeSize

        for portContext in nodeContext.portContexts[portSide] ?? [] {
            portContext.portPosition.x = calculateVerticalPortXCoordinate(portContext, nodeSize.x)
            let ratio: Double = portContext.port.getProperty(PORT_RATIO_OR_POSITION) ?? 0.0
            portContext.portPosition.y = nodeSize.y * ratio
        }
    }

    package static func placeVerticalFreePorts(_ nodeContext: NodeContext, _ portSide: PortSide) {
        guard let portContexts = nodeContext.portContexts[portSide], !portContexts.isEmpty else {
            return
        }

        guard let insidePortLabelCell = nodeContext.insidePortLabelCells[portSide] else { return }
        let insidePortLabelCellRectangle = insidePortLabelCell.getCellRectangle()
        let insidePortLabelCellPadding = insidePortLabelCell.getPadding()

        var portAlignment = nodeContext.getPortAlignment(portSide: portSide)
        var availableSpace = insidePortLabelCellRectangle.height - insidePortLabelCellPadding.top
                - insidePortLabelCellPadding.bottom
        var calculatedPortPlacementHeight = insidePortLabelCell.getMinimumContentAreaSize().y
        var currentYPos = insidePortLabelCellRectangle.y + insidePortLabelCellPadding.top
        var spaceBetweenPorts = nodeContext.portPortSpacing
        let nodeWidth = nodeContext.nodeSize.x

        if (portAlignment == .distributed || portAlignment == .justified)
                && portContexts.count == 1 {

            calculatedPortPlacementHeight = modifiedPortPlacementSize(
                    nodeContext, portAlignment, calculatedPortPlacementHeight)
            portAlignment = .center
        }

        if availableSpace < calculatedPortPlacementHeight
                && !nodeContext.sizeOptions.contains(.portsOverhang) {

            if portAlignment == .distributed {
                spaceBetweenPorts += (availableSpace - calculatedPortPlacementHeight)
                        / Double(portContexts.count + 1)
                currentYPos += spaceBetweenPorts

            } else {
                spaceBetweenPorts += (availableSpace - calculatedPortPlacementHeight)
                        / Double(portContexts.count - 1)
            }
        } else {
            if availableSpace < calculatedPortPlacementHeight {
                calculatedPortPlacementHeight = modifiedPortPlacementSize(
                        nodeContext, portAlignment, calculatedPortPlacementHeight)
                portAlignment = .center
            }

            switch portAlignment {
            case .begin:
                break

            case .center:
                currentYPos += (availableSpace - calculatedPortPlacementHeight) / 2

            case .end:
                currentYPos += availableSpace - calculatedPortPlacementHeight

            case .distributed:
                let additionalSpaceBetweenPorts = (availableSpace - calculatedPortPlacementHeight)
                        / Double(portContexts.count + 1)
                spaceBetweenPorts += max(0, additionalSpaceBetweenPorts)
                currentYPos += spaceBetweenPorts

            case .justified:
                let additionalSpaceBetweenPorts = (availableSpace - calculatedPortPlacementHeight)
                        / Double(portContexts.count - 1)
                spaceBetweenPorts += max(0, additionalSpaceBetweenPorts)
            }
        }

        for portContext in portContexts {
            portContext.portPosition.x = calculateVerticalPortXCoordinate(portContext, nodeWidth)
            portContext.portPosition.y = currentYPos + portContext.portMargin.top
            currentYPos += portContext.portMargin.top
                    + portContext.port.getSize().y
                    + portContext.portMargin.bottom
                    + spaceBetweenPorts
        }
    }

    package static func calculateVerticalPortXCoordinate(_ portContext: PortContext, _ nodeWidth: Double) -> Double {
        let port = portContext.port
        if port.hasProperty(CoreOptions.PORT_BORDER_OFFSET) {
            let offset: Double = port.getProperty(CoreOptions.PORT_BORDER_OFFSET) ?? 0.0
            return port.getSide() == .WEST
                    ? -port.getSize().x - offset
                    : nodeWidth + offset
        } else {
            return port.getSide() == .WEST
                    ? -port.getSize().x
                    : nodeWidth
        }
    }


    // MARK: - Utilities

    package static func modifiedPortPlacementSize(_ nodeContext: NodeContext,
            _ oldPortAlignment: PortAlignment, _ currentPortPlacementSize: Double) -> Double {

        if oldPortAlignment == .distributed {
            return currentPortPlacementSize - 2 * nodeContext.portPortSpacing
        } else {
            return currentPortPlacementSize
        }
    }
}
