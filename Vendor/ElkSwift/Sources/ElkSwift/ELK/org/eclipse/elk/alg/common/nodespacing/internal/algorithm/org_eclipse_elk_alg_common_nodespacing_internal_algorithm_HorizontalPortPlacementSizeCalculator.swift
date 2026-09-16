import Foundation

/**
 * Calculates the space required to setup port labels.
 */
package final class HorizontalPortPlacementSizeCalculator {

    private init() {}

    package static func calculateHorizontalPortPlacementSize(_ nodeContext: NodeContext) {
        switch nodeContext.portConstraints {
        case .fixedPos:
            calculateHorizontalNodeSizeRequiredByFixedPosPorts(nodeContext, .NORTH)
            calculateHorizontalNodeSizeRequiredByFixedPosPorts(nodeContext, .SOUTH)
        case .fixedRatio:
            calculateHorizontalNodeSizeRequiredByFixedRatioPorts(nodeContext, .NORTH)
            calculateHorizontalNodeSizeRequiredByFixedRatioPorts(nodeContext, .SOUTH)
        default:
            calculateHorizontalNodeSizeRequiredByFreePorts(nodeContext, .NORTH)
            calculateHorizontalNodeSizeRequiredByFreePorts(nodeContext, .SOUTH)
        }
    }

    // MARK: - Fixed Position

    package static func calculateHorizontalNodeSizeRequiredByFixedPosPorts(_ nodeContext: NodeContext, _ portSide: PortSide) {
        var rightmostPortBorder: Double = 0.0

        for portContext in nodeContext.portContexts[portSide] ?? [] {
            rightmostPortBorder = max(
                rightmostPortBorder,
                portContext.portPosition.x + portContext.port.getSize().x
            )
        }

        if let cell = nodeContext.insidePortLabelCells[portSide] {
            cell.padding.left = 0
            cell.minimumContentAreaSize.x = rightmostPortBorder
        }
    }

    // MARK: - Fixed Ratio

    package static func calculateHorizontalNodeSizeRequiredByFixedRatioPorts(_ nodeContext: NodeContext, _ portSide: PortSide) {
        guard let cell = nodeContext.insidePortLabelCells[portSide] else { return }

        let portContexts = nodeContext.portContexts[portSide] ?? []
        if portContexts.isEmpty {
            cell.padding.left = 0
            cell.padding.right = 0
            return
        }

        let portLabelsInside = nodeContext.portLabelsPlacement.contains(.inside)
        var minWidth: Double = 0

        if nodeContext.sizeConstraints.contains(.portLabels) {
            setupPortMargins(nodeContext, portSide)
        }

        var previousPortContext: PortContext?
        var previousPortRatio: Double = 0
        var previousPortWidth: Double = 0

        for currentPortContext in portContexts {
            let currentPortRatio: Double = currentPortContext.port.getProperty(PortPlacementCalculator.PORT_RATIO_OR_POSITION) ?? 0.0
            let currentPortWidth = currentPortContext.port.getSize().x

            if previousPortContext == nil {
                let surroundingPortMargins = nodeContext.surroundingPortMargins
                if surroundingPortMargins.left > 0 {
                    minWidth = max(
                        minWidth,
                        minSizeRequiredToRespectSpacing(
                            surroundingPortMargins.left + currentPortContext.portMargin.left,
                            0,
                            currentPortRatio
                        )
                    )
                }
            } else if let prevPortContext = previousPortContext {
                let requiredSpace = previousPortWidth + prevPortContext.portMargin.right
                    + nodeContext.portPortSpacing + currentPortContext.portMargin.left
                minWidth = max(
                    minWidth,
                    minSizeRequiredToRespectSpacing(
                        requiredSpace,
                        previousPortRatio,
                        currentPortRatio
                    )
                )
            }

            previousPortContext = currentPortContext
            previousPortRatio = currentPortRatio
            previousPortWidth = currentPortWidth
        }

        let surroundingPortMargins = nodeContext.surroundingPortMargins
        if surroundingPortMargins.right > 0 {
            var requiredSpace = previousPortWidth + surroundingPortMargins.right

            if portLabelsInside, let prevPortContext = previousPortContext {
                requiredSpace += prevPortContext.portMargin.right
            }

            minWidth = max(
                minWidth,
                minSizeRequiredToRespectSpacing(
                    requiredSpace,
                    previousPortRatio,
                    1
                )
            )
        }

        cell.padding.left = 0
        cell.minimumContentAreaSize.x = minWidth
    }

    package static let equalityTolerance: Double = 0.01

    package static func minSizeRequiredToRespectSpacing(_ spacing: Double, _ firstRatio: Double, _ secondRatio: Double) -> Double {
        assert(secondRatio >= firstRatio)

        if abs(firstRatio - secondRatio) < equalityTolerance {
            return 0
        } else {
            return spacing / (secondRatio - firstRatio)
        }
    }

    // MARK: - Free

    package static func calculateHorizontalNodeSizeRequiredByFreePorts(_ nodeContext: NodeContext, _ portSide: PortSide) {
        guard let cell = nodeContext.insidePortLabelCells[portSide] else { return }

        let portContexts = nodeContext.portContexts[portSide] ?? []
        if portContexts.isEmpty {
            cell.padding.left = 0
            cell.padding.right = 0
            return
        }

        cell.padding.left = nodeContext.surroundingPortMargins.left
        cell.padding.right = nodeContext.surroundingPortMargins.right

        if nodeContext.sizeConstraints.contains(.portLabels) {
            setupPortMargins(nodeContext, portSide)
        }

        var width = portWidthPlusPortPortSpacing(nodeContext, portSide)

        if nodeContext.getPortAlignment(portSide: portSide) == .distributed {
            width += 2 * nodeContext.portPortSpacing
        }

        cell.minimumContentAreaSize.x = width
    }

    package static func setupPortMargins(_ nodeContext: NodeContext, _ portSide: PortSide) {
        let portContexts = nodeContext.portContexts[portSide] ?? []

        let portLabelsOutside = nodeContext.portLabelsPlacement.contains(.outside)
        let alwaysSameSide = nodeContext.portLabelsPlacement.contains(.alwaysSameSide)
        let alwaysSameSideAbove = nodeContext.portLabelsPlacement.contains(.alwaysOtherSameSide)
        let spaceEfficient = nodeContext.portLabelsPlacement.contains(.spaceEfficient)
        let uniformPortSpacing = nodeContext.sizeOptions.contains(.uniformPortSpacing)

        let spaceEfficientPortLabels = !alwaysSameSide && !alwaysSameSideAbove
            && (spaceEfficient || portContexts.count == 2)

        computeHorizontalPortMargins(nodeContext, portSide, portLabelsOutside)

        var leftmostPortContext: PortContext?
        var rightmostPortContext: PortContext?

        if portLabelsOutside {
            var portContextIterator = portContexts.makeIterator()

            leftmostPortContext = portContextIterator.next()
            rightmostPortContext = leftmostPortContext

            while let currentPortContext = portContextIterator.next() {
                rightmostPortContext = currentPortContext
            }

            leftmostPortContext?.portMargin.left = 0
            rightmostPortContext?.portMargin.right = 0

            if spaceEfficientPortLabels, let lpc = leftmostPortContext, !lpc.labelsNextToPort {
                lpc.portMargin.right = 0
            }
        }

        if uniformPortSpacing {
            unifyPortMargins(portContexts)

            if portLabelsOutside {
                leftmostPortContext?.portMargin.left = 0
                rightmostPortContext?.portMargin.right = 0
            }
        }
    }

    package static func computeHorizontalPortMargins(_ nodeContext: NodeContext, _ portSide: PortSide, _ portLabelsOutside: Bool) {
        let portContexts = nodeContext.portContexts[portSide] ?? []

        for portContext in portContexts {
            let labelWidth = portContext.portLabelCell?.getMinimumWidth() ?? 0

            if labelWidth > 0 {
                if portContext.labelsNextToPort {
                    let portWidth = portContext.port.getSize().x
                    if labelWidth > portWidth {
                        let overhang = (labelWidth - portWidth) / 2
                        portContext.portMargin.left = overhang
                        portContext.portMargin.right = overhang
                    }
                } else {
                    portContext.portMargin.right = nodeContext.portLabelSpacingHorizontal + labelWidth
                }
            } else if PortLabelPlacement.isFixed(nodeContext.portLabelsPlacement) {
                let labelsBounds = ElkUtil.getLabelsBounds(portContext.port)
                if labelsBounds.x < 0 {
                    portContext.portMargin.left = -labelsBounds.x
                }
                if labelsBounds.x + labelsBounds.width > portContext.port.getSize().x {
                    portContext.portMargin.right = labelsBounds.x + labelsBounds.width - portContext.port.getSize().x
                }
            }
        }
    }

    package static func unifyPortMargins(_ portContexts: [PortContext]) {
        var maxLeft: Double = 0
        var maxRight: Double = 0

        for portContext in portContexts {
            maxLeft = max(maxLeft, portContext.portMargin.left)
            maxRight = max(maxRight, portContext.portMargin.right)
        }

        for portContext in portContexts {
            portContext.portMargin.left = maxLeft
            portContext.portMargin.right = maxRight
        }
    }

    package static func portWidthPlusPortPortSpacing(_ nodeContext: NodeContext, _ portSide: PortSide) -> Double {
        var result: Double = 0

        let portContexts = nodeContext.portContexts[portSide] ?? []
        let count = portContexts.count
        for (index, portContext) in portContexts.enumerated() {
            result += portContext.portMargin.left + portContext.port.getSize().x + portContext.portMargin.right

            if index < count - 1 {
                result += nodeContext.portPortSpacing
            }
        }

        return result
    }
}
