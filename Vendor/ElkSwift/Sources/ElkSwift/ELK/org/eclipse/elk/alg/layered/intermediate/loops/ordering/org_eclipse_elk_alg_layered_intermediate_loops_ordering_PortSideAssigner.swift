import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_loops_ordering_PortSideAssigner {

    package init() {}

    package func assignPortSides(_ slHolder: SelfLoopHolder) {
        let dist: SelfLoopDistributionStrategy = slHolder.getLNode().getProperty(
            LayeredOptions.EDGE_ROUTING_SELF_LOOP_DISTRIBUTION) as? SelfLoopDistributionStrategy ?? .NORTH

        switch dist {
        case .NORTH:
            assignToNorthSide(slHolder)
        case .NORTH_SOUTH:
            assignToNorthOrSouthSide(slHolder)
        case .EQUALLY:
            assignToAllSides(slHolder)
        }
    }

    // MARK: - North

    private func assignToNorthSide(_ slHolder: SelfLoopHolder) {
        for slLoop in slHolder.getSLHyperLoops() {
            for slPort in slLoop.getSLPorts() where slPort.isHidden() {
                slPort.getLPort().setSide(.NORTH)
            }
        }
    }

    // MARK: - North, South

    private func assignToNorthOrSouthSide(_ slHolder: SelfLoopHolder) {
        var northPorts = 0
        var southPorts = 0

        for slLoop in slHolder.getSLHyperLoops() {
            let slHiddenPorts = slLoop.getSLPorts().filter { $0.isHidden() }
            let newPortSide: PortSide
            if northPorts <= southPorts {
                newPortSide = .NORTH
                northPorts += slHiddenPorts.count
            } else {
                newPortSide = .SOUTH
                southPorts += slHiddenPorts.count
            }
            for slPort in slHiddenPorts {
                slPort.getLPort().setSide(newPortSide)
            }
        }
    }

    // MARK: - Equal Distribution

    private enum Target: CaseIterable {
        case NORTH, SOUTH, EAST, WEST
        case NORTH_WEST_CORNER, NORTH_EAST_CORNER, SOUTH_WEST_CORNER, SOUTH_EAST_CORNER

        var firstSide: PortSide {
            switch self {
            case .NORTH: return .NORTH
            case .SOUTH: return .SOUTH
            case .EAST: return .EAST
            case .WEST: return .WEST
            case .NORTH_WEST_CORNER: return .WEST
            case .NORTH_EAST_CORNER: return .NORTH
            case .SOUTH_WEST_CORNER: return .SOUTH
            case .SOUTH_EAST_CORNER: return .EAST
            }
        }

        var secondSide: PortSide {
            switch self {
            case .NORTH: return .NORTH
            case .SOUTH: return .SOUTH
            case .EAST: return .EAST
            case .WEST: return .WEST
            case .NORTH_WEST_CORNER: return .NORTH
            case .NORTH_EAST_CORNER: return .EAST
            case .SOUTH_WEST_CORNER: return .WEST
            case .SOUTH_EAST_CORNER: return .SOUTH
            }
        }

        var isCornerTarget: Bool { return firstSide != secondSide }
    }

    private func assignToAllSides(_ slHolder: SelfLoopHolder) {
        var slSortedLoops = slHolder.getSLHyperLoops()
        slSortedLoops.sort { $0.getSLPorts().count > $1.getSLPorts().count }

        let assignmentTargets = Target.allCases
        for (index, slLoop) in slSortedLoops.enumerated() {
            let currTarget = assignmentTargets[index % assignmentTargets.count]
            assignToTarget(slLoop, currTarget)
        }
    }

    private func assignToTarget(_ slLoop: SelfHyperLoop, _ target: Target) {
        var slPorts = slLoop.getSLPorts()

        if target.isCornerTarget {
            slPorts.sort { $0.getLPort().getNetFlow() < $1.getLPort().getNetFlow() }
        }

        let secondHalfStartIndex = slPorts.count / 2

        for i in 0..<secondHalfStartIndex {
            let slPort = slPorts[i]
            if slPort.isHidden() {
                slPort.getLPort().setSide(target.firstSide)
            }
        }

        for i in secondHalfStartIndex..<slPorts.count {
            let slPort = slPorts[i]
            if slPort.isHidden() {
                slPort.getLPort().setSide(target.secondSide)
            }
        }
    }
}
