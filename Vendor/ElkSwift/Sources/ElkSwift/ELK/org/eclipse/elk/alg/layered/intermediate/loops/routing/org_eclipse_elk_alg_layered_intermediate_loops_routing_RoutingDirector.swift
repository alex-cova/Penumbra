import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_loops_routing_RoutingDirector {

    private static let UNCONNECTED_PORT_PENALTY = 1
    private static let CONNECTED_PORT_PENALTY = 3

    private var portPenalties: [Int]?

    package init() {}

    package func determineLoopRoutes(_ slHolder: SelfLoopHolder) {
        assignPortIds(slHolder.getLNode().getPorts())
        sortHyperLoopPortLists(slHolder)

        for slLoop in slHolder.getSLHyperLoops() {
            guard let loopType = slLoop.getSelfLoopType() else { continue }
            switch loopType {
            case .ONE_SIDE:
                determineOneSideLoopRoutes(slLoop)
            case .TWO_SIDES_CORNER:
                determineTwoSideCornerLoopRoutes(slLoop)
            case .TWO_SIDES_OPPOSING:
                determineTwoSideOpposingLoopRoutes(slLoop)
            case .THREE_SIDES:
                determineThreeSideLoopRoutes(slLoop)
            case .FOUR_SIDES:
                determineFourSideLoopRoutes(slLoop)
            }
            computeOccupiedPortSides(slLoop)
        }

        portPenalties = nil
    }

    private func assignPortIds(_ lPorts: [LPort]) {
        for (i, port) in lPorts.enumerated() {
            port.id = i
        }
    }

    private func sortHyperLoopPortLists(_ slHolder: SelfLoopHolder) {
        for slLoop in slHolder.getSLHyperLoops() {
            slLoop.sortSLPorts { $0.getLPort().id < $1.getLPort().id }
        }
    }

    private func computeOccupiedPortSides(_ slLoop: SelfHyperLoop) {
        guard let leftmost = slLoop.getLeftmostPort(), let rightmost = slLoop.getRightmostPort() else { return }
        var currPortSide = leftmost.getLPort().getSide()
        let targetSide = rightmost.getLPort().getSide()

        while currPortSide != targetSide {
            slLoop.addOccupiedPortSide(currPortSide)
            currPortSide = currPortSide.right()
        }
        slLoop.addOccupiedPortSide(currPortSide)
    }

    // MARK: - One Side

    private func determineOneSideLoopRoutes(_ slLoop: SelfHyperLoop) {
        let side = slLoop.getSLPorts()[0].getLPort().getSide()
        assignLeftmostRightmostPorts(slLoop, side, side)
    }

    // MARK: - Two Sides Corner

    private func determineTwoSideCornerLoopRoutes(_ slLoop: SelfHyperLoop) {
        let sides = PortRestorer.sortedTwoSideLoopPortSides(slLoop)
        assignLeftmostRightmostPorts(slLoop, sides[0], sides[1])
    }

    // MARK: - Two Sides Opposing

    private func determineTwoSideOpposingLoopRoutes(_ slLoop: SelfHyperLoop) {
        let sides = Array(slLoop.getSLPortsBySide().keys)
        guard sides.count == 2 else { return }

        let slHolder = slLoop.getSLHolder()

        let option1LeftmostPort = lowestPortOnSide(slLoop, sides[0])
        let option1RightmostPort = highestPortOnSide(slLoop, sides[1])
        let option1Penalty = computeEdgePenalty(slHolder, option1LeftmostPort, option1RightmostPort)

        let option2LeftmostPort = lowestPortOnSide(slLoop, sides[1])
        let option2RightmostPort = highestPortOnSide(slLoop, sides[0])
        let option2Penalty = computeEdgePenalty(slHolder, option2LeftmostPort, option2RightmostPort)

        if option1Penalty <= option2Penalty {
            slLoop.setLeftmostPort(option1LeftmostPort)
            slLoop.setRightmostPort(option1RightmostPort)
        } else {
            slLoop.setLeftmostPort(option2LeftmostPort)
            slLoop.setRightmostPort(option2RightmostPort)
        }
    }

    // MARK: - Three Sides

    private func determineThreeSideLoopRoutes(_ slLoop: SelfHyperLoop) {
        var leftmostSide = PortSide.UNDEFINED
        var rightmostSide = PortSide.UNDEFINED

        switch computeMissingPortSide(slLoop) {
        case .NORTH:
            leftmostSide = .EAST; rightmostSide = .WEST
        case .EAST:
            leftmostSide = .SOUTH; rightmostSide = .NORTH
        case .SOUTH:
            leftmostSide = .WEST; rightmostSide = .EAST
        case .WEST:
            leftmostSide = .NORTH; rightmostSide = .SOUTH
        default:
            break
        }

        assignLeftmostRightmostPorts(slLoop, leftmostSide, rightmostSide)
    }

    private func computeMissingPortSide(_ slLoop: SelfHyperLoop) -> PortSide {
        let sides = Set(slLoop.getSLPortsBySide().keys)
        for side in [PortSide.NORTH, .EAST, .SOUTH, .WEST] {
            if !sides.contains(side) {
                return side
            }
        }
        return .UNDEFINED
    }

    // MARK: - Four Sides

    private func determineFourSideLoopRoutes(_ slLoop: SelfHyperLoop) {
        let sortedSLPorts = slLoop.getSLPorts()
        let slHolder = slLoop.getSLHolder()

        var worstLeftPort = sortedSLPorts[sortedSLPorts.count - 1]
        var worstRightPort = sortedSLPorts[0]
        var worstPenalty = computeEdgePenalty(slHolder, worstLeftPort, worstRightPort)

        for rightPortIndex in 1..<sortedSLPorts.count {
            let currLeftPort = sortedSLPorts[rightPortIndex - 1]
            let currRightPort = sortedSLPorts[rightPortIndex]
            let currPenalty = computeEdgePenalty(slHolder, currLeftPort, currRightPort)

            if currPenalty > worstPenalty {
                worstLeftPort = currLeftPort
                worstRightPort = currRightPort
                worstPenalty = currPenalty
            }
        }

        slLoop.setLeftmostPort(worstRightPort)
        slLoop.setRightmostPort(worstLeftPort)
    }

    // MARK: - Utility Methods

    private func assignLeftmostRightmostPorts(_ slLoop: SelfHyperLoop, _ leftmostSide: PortSide,
                                               _ rightmostSide: PortSide) {
        slLoop.setLeftmostPort(lowestPortOnSide(slLoop, leftmostSide))
        slLoop.setRightmostPort(highestPortOnSide(slLoop, rightmostSide))
    }

    private func lowestPortOnSide(_ slLoop: SelfHyperLoop, _ side: PortSide) -> SelfLoopPort {
        return slLoop.getSLPortsBySide(side).min { $0.getLPort().id < $1.getLPort().id }!
    }

    private func highestPortOnSide(_ slLoop: SelfHyperLoop, _ side: PortSide) -> SelfLoopPort {
        return slLoop.getSLPortsBySide(side).max { $0.getLPort().id < $1.getLPort().id }!
    }

    private func computeEdgePenalty(_ slHolder: SelfLoopHolder, _ leftmostPort: SelfLoopPort,
                                     _ rightmostPort: SelfLoopPort) -> Int {
        if portPenalties == nil {
            computePenalties(slHolder)
        }

        let portCount = slHolder.getLNode().getPorts().count
        let leftmostPortId = leftmostPort.getLPort().id
        let rightmostPortId = rightmostPort.getLPort().id
        var leftOfRightmostPortId = rightmostPortId - 1

        if leftOfRightmostPortId < 0 {
            leftOfRightmostPortId = portCount - 1
        }

        guard let penalties = portPenalties else { return 0 }

        if leftmostPortId <= leftOfRightmostPortId {
            return penalties[leftOfRightmostPortId] - penalties[leftmostPortId]
        } else {
            return penalties[portCount - 1] - penalties[leftmostPortId] + penalties[leftOfRightmostPortId]
        }
    }

    private func computePenalties(_ slHolder: SelfLoopHolder) {
        let ports = slHolder.getLNode().getPorts()
        portPenalties = [Int](repeating: 0, count: ports.count)
        var penaltySum = 0

        for i in 0..<ports.count {
            let currPort = ports[i]
            if currPort.getIncomingEdges().isEmpty && currPort.getOutgoingEdges().isEmpty {
                penaltySum += Self.UNCONNECTED_PORT_PENALTY
            } else {
                penaltySum += Self.CONNECTED_PORT_PENALTY
            }
            portPenalties?[i] = penaltySum
        }
    }
}
