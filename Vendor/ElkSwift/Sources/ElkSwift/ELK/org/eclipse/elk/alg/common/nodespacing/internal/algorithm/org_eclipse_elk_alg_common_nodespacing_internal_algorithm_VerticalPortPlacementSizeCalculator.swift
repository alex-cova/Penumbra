import Foundation

/**
 * Calculates the space required to setup port labels.
 */
package final class VerticalPortPlacementSizeCalculator {

    private init() {}

    package static func calculateVerticalPortPlacementSize(_ nodeContext: NodeContext) {
        switch nodeContext.portConstraints {
        case .fixedPos:
            calculateVerticalNodeSizeRequiredByFixedPosPorts(nodeContext, .EAST)
            calculateVerticalNodeSizeRequiredByFixedPosPorts(nodeContext, .WEST)

        case .fixedRatio:
            calculateVerticalNodeSizeRequiredByFixedRatioPorts(nodeContext, .EAST)
            calculateVerticalNodeSizeRequiredByFixedRatioPorts(nodeContext, .WEST)

        default:
            calculateVerticalNodeSizeRequiredByFreePorts(nodeContext, .EAST)
            calculateVerticalNodeSizeRequiredByFreePorts(nodeContext, .WEST)
        }
    }


    // MARK: - Fixed Position

    package static func calculateVerticalNodeSizeRequiredByFixedPosPorts(_ nodeContext: NodeContext, _ portSide: PortSide) {

        var bottommostPortBorder: Double = 0.0

        for portContext in nodeContext.portContexts[portSide] ?? [] {
            let portY = portContext.portPosition.y
            let portHeight = portContext.port.getSize().y
            bottommostPortBorder = max(bottommostPortBorder, portY + portHeight)
        }

        guard let cell = nodeContext.insidePortLabelCells[portSide] else { return }
        cell.padding.top = 0
        cell.minimumContentAreaSize.y = bottommostPortBorder
    }


    // MARK: - Fixed Ratio

    package static func calculateVerticalNodeSizeRequiredByFixedRatioPorts(_ nodeContext: NodeContext, _ portSide: PortSide) {

        guard let cell = nodeContext.insidePortLabelCells[portSide] else { return }

        guard let portContexts = nodeContext.portContexts[portSide], !portContexts.isEmpty else {
            cell.padding.top = 0
            cell.padding.bottom = 0
            return
        }

        let portLabelsInside = nodeContext.portLabelsPlacement.contains(.inside)
        var minHeight: Double = 0

        if nodeContext.sizeConstraints.contains(.portLabels) {
            setupPortMargins(nodeContext, portSide)
        }

        var previousPortContext: PortContext?
        var previousPortRatio: Double = 0
        var previousPortHeight: Double = 0

        for currentPortContext in portContexts {
            let currentPortRatio: Double = currentPortContext.port.getProperty(PortPlacementCalculator.PORT_RATIO_OR_POSITION) ?? 0.0
            let currentPortHeight = currentPortContext.port.getSize().y

            if let prev = previousPortContext {
                let requiredSpace = previousPortHeight + prev.portMargin.bottom
                        + nodeContext.portPortSpacing + currentPortContext.portMargin.top
                minHeight = max(
                        minHeight,
                        HorizontalPortPlacementSizeCalculator.minSizeRequiredToRespectSpacing(
                                requiredSpace,
                                previousPortRatio,
                                currentPortRatio))
            } else {
                let surroundingPortMargins = nodeContext.surroundingPortMargins
                if surroundingPortMargins.top > 0 {
                    let requiredSpace = surroundingPortMargins.top + currentPortContext.portMargin.top
                    minHeight = max(
                        minHeight,
                        HorizontalPortPlacementSizeCalculator.minSizeRequiredToRespectSpacing(
                            requiredSpace,
                            0,
                            currentPortRatio))
                }
            }

            previousPortContext = currentPortContext
            previousPortRatio = currentPortRatio
            previousPortHeight = currentPortHeight
        }

        let surroundingPortMargins = nodeContext.surroundingPortMargins
        if surroundingPortMargins.bottom > 0 {
            var requiredSpace = previousPortHeight + surroundingPortMargins.bottom

            if portLabelsInside {
                requiredSpace += previousPortContext?.portMargin.bottom ?? 0
            }

            minHeight = max(
                    minHeight,
                    HorizontalPortPlacementSizeCalculator.minSizeRequiredToRespectSpacing(
                            requiredSpace,
                            previousPortRatio,
                            1))
        }

        cell.padding.top = 0
        cell.minimumContentAreaSize.y = minHeight
    }


    // MARK: - Free

    package static func calculateVerticalNodeSizeRequiredByFreePorts(_ nodeContext: NodeContext, _ portSide: PortSide) {

        guard let cell = nodeContext.insidePortLabelCells[portSide] else { return }

        guard let portContexts = nodeContext.portContexts[portSide], !portContexts.isEmpty else {
            cell.padding.top = 0
            cell.padding.bottom = 0
            return
        }

        cell.padding.top = nodeContext.surroundingPortMargins.top
        cell.padding.bottom = nodeContext.surroundingPortMargins.bottom

        if nodeContext.sizeConstraints.contains(.portLabels) {
            setupPortMargins(nodeContext, portSide)
        }

        var height = portHeightPlusPortPortSpacing(nodeContext, portSide)

        if nodeContext.getPortAlignment(portSide: portSide) == .distributed {
            height += 2 * nodeContext.portPortSpacing
        }

        cell.minimumContentAreaSize.y = height
    }

    package static func setupPortMargins(_ nodeContext: NodeContext, _ portSide: PortSide) {
        guard let portContexts = nodeContext.portContexts[portSide] else { return }

        let portLabelsOutside = nodeContext.portLabelsPlacement.contains(.outside)
        let alwaysSameSide = nodeContext.portLabelsPlacement.contains(.alwaysSameSide)
        let alwaysSameSideAbove = nodeContext.portLabelsPlacement.contains(.alwaysOtherSameSide)
        let spaceEfficient = nodeContext.portLabelsPlacement.contains(.spaceEfficient)
        let uniformPortSpacing = nodeContext.sizeOptions.contains(.uniformPortSpacing)

        let spaceEfficientPortLabels = !alwaysSameSide && !alwaysSameSideAbove
                && (spaceEfficient || portContexts.count == 2)

        computeVerticalPortMargins(nodeContext, portSide, portLabelsOutside)

        var topmostPortContext: PortContext?
        var bottommostPortContext: PortContext?

        if portLabelsOutside {
            var iter = portContexts.makeIterator()
            topmostPortContext = iter.next()
            bottommostPortContext = topmostPortContext

            while let current = iter.next() {
                bottommostPortContext = current
            }

            topmostPortContext?.portMargin.top = 0
            bottommostPortContext?.portMargin.bottom = 0

            if spaceEfficientPortLabels && !(topmostPortContext?.labelsNextToPort ?? false) {
                topmostPortContext?.portMargin.bottom = 0
            }
        }

        if uniformPortSpacing {
            unifyPortMargins(portContexts)

            if portLabelsOutside {
                topmostPortContext?.portMargin.top = 0
                bottommostPortContext?.portMargin.bottom = 0
            }
        }
    }

    package static func computeVerticalPortMargins(_ nodeContext: NodeContext, _ portSide: PortSide,
            _ portLabelsOutside: Bool) {

        guard let portContexts = nodeContext.portContexts[portSide] else { return }

        for portContext in portContexts {
            let labelHeight = portContext.portLabelCell?.getMinimumHeight() ?? 0

            if labelHeight > 0 {
                if portContext.labelsNextToPort {
                    let portHeight = portContext.port.getSize().y
                    if labelHeight > portHeight {
                        if nodeContext.portLabelsTreatAsGroup || (portContext.portLabelCell?.labels.count ?? 0) == 1 {
                            let overhang = (labelHeight - portHeight) / 2
                            portContext.portMargin.top = overhang
                            portContext.portMargin.bottom = overhang

                        } else {
                            let firstLabelHeight = portContext.portLabelCell?.labels.first?.getSize().y ?? 0
                            let firstLabelOverhang = (firstLabelHeight - portHeight) / 2

                            portContext.portMargin.top = max(0, firstLabelOverhang)
                            portContext.portMargin.bottom = labelHeight - firstLabelOverhang - portHeight
                        }
                    }

                } else {
                    portContext.portMargin.bottom = nodeContext.portLabelSpacingVertical + labelHeight
                }
            } else if PortLabelPlacement.isFixed(nodeContext.portLabelsPlacement) {
                let labelsBounds = ElkUtil.getLabelsBounds(portContext.port)
                if labelsBounds.y < 0 {
                    portContext.portMargin.top = -labelsBounds.y
                }
                if labelsBounds.y + labelsBounds.height > portContext.port.getSize().y {
                    portContext.portMargin.bottom = labelsBounds.y + labelsBounds.height - portContext.port.getSize().y
                }
            }
        }
    }

    package static func unifyPortMargins(_ portContexts: [PortContext]) {
        var maxTop: Double = 0
        var maxBottom: Double = 0

        for portContext in portContexts {
            maxTop = max(maxTop, portContext.portMargin.top)
            maxBottom = max(maxBottom, portContext.portMargin.bottom)
        }

        for portContext in portContexts {
            portContext.portMargin.top = maxTop
            portContext.portMargin.bottom = maxBottom
        }
    }

    package static func portHeightPlusPortPortSpacing(_ nodeContext: NodeContext, _ portSide: PortSide) -> Double {
        var result: Double = 0

        guard let portContexts = nodeContext.portContexts[portSide] else { return result }

        let count = portContexts.count
        for (index, portContext) in portContexts.enumerated() {
            result += portContext.portMargin.top + portContext.port.getSize().y + portContext.portMargin.bottom
            if index < count - 1 {
                result += nodeContext.portPortSpacing
            }
        }

        return result
    }
}
