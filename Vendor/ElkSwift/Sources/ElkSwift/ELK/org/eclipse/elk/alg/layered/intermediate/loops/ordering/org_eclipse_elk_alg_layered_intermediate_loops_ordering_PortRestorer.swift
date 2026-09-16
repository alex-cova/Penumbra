import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_loops_ordering_PortRestorer {

    private enum PortSideArea: CaseIterable {
        case START, MIDDLE, END
    }

    private enum AddMode {
        case PREPEND, APPEND
    }

    private var slLoopsByType: [SelfLoopType: [SelfHyperLoop]] = [:]
    /// targetAreas[side][area] → [SelfLoopPort]
    private var targetAreas: [PortSide: [PortSideArea: [SelfLoopPort]]] = [:]

    package init() {}

    package func restorePorts(_ slHolder: SelfLoopHolder, _ monitor: IElkProgressMonitor) {
        initTargetAreas()
        slLoopsByType = gatherSelfLoopsByType(slHolder)

        let ordering: SelfLoopOrderingStrategy = slHolder.getLNode().getProperty(
            LayeredOptions.EDGE_ROUTING_SELF_LOOP_ORDERING) as? SelfLoopOrderingStrategy ?? .STACKED
        processOneSideLoops(ordering)
        processTwoSideCornerLoops()
        processThreeSideLoops()
        processFourSideLoops()
        processTwoSideOpposingLoops()

        restorePortsToNode(slHolder)

        // Un-hide all ports
        for side in allSides {
            for area in PortSideArea.allCases {
                for slPort in targetAreas[side]?[area] ?? [] {
                    slPort.setHidden(false)
                }
            }
        }
        slHolder.setPortsHidden(false)

        slLoopsByType = [:]
    }

    private let allSides: [PortSide] = [.UNDEFINED, .NORTH, .EAST, .SOUTH, .WEST]

    private func initTargetAreas() {
        targetAreas = [:]
        for side in allSides {
            targetAreas[side] = [:]
            for area in PortSideArea.allCases {
                targetAreas[side]?[area] = []
            }
        }
    }

    // MARK: - Self Loop Gathering

    private func gatherSelfLoopsByType(_ slHolder: SelfLoopHolder) -> [SelfLoopType: [SelfHyperLoop]] {
        var loops = [SelfLoopType: [SelfHyperLoop]]()
        for slLoop in slHolder.getSLHyperLoops() {
            if let t = slLoop.getSelfLoopType() {
                loops[t, default: []].append(slLoop)
            }
        }
        return loops
    }

    // MARK: - One Side

    private func processOneSideLoops(_ ordering: SelfLoopOrderingStrategy) {
        var loops = slLoopsByType[.ONE_SIDE] ?? []
        if ordering == .REVERSE_STACKED {
            loops.reverse()
        }
        for slLoop in loops {
            let side = slLoop.getSLPorts()[0].getLPort().getSide()
            var sortedPorts = slLoop.getSLPorts()
            sortedPorts.sort { $0.getSLNetFlow() < $1.getSLNetFlow() }

            switch ordering {
            case .SEQUENCED:
                addToTargetArea(sortedPorts, side, .MIDDLE, .APPEND)
            case .REVERSE_STACKED, .STACKED:
                let splitIndex = computePortListSplitIndex(sortedPorts)
                addToTargetArea(Array(sortedPorts[0..<splitIndex]), side, .MIDDLE, .PREPEND)
                addToTargetArea(Array(sortedPorts[splitIndex...]), side, .MIDDLE, .APPEND)
            }
        }
    }

    private func computePortListSplitIndex(_ sortedPorts: [SelfLoopPort]) -> Int {
        var positiveNetFlowIndex = 0
        while positiveNetFlowIndex < sortedPorts.count {
            if sortedPorts[positiveNetFlowIndex].getSLNetFlow() > 0 { break }
            positiveNetFlowIndex += 1
        }
        if positiveNetFlowIndex > 0 && positiveNetFlowIndex < sortedPorts.count - 1 {
            return positiveNetFlowIndex
        }

        var nonNegativeNetFlowIndex = 0
        while nonNegativeNetFlowIndex < sortedPorts.count {
            if sortedPorts[nonNegativeNetFlowIndex].getSLNetFlow() > 0 { break }
            nonNegativeNetFlowIndex += 1
        }
        if nonNegativeNetFlowIndex > 0 && positiveNetFlowIndex < sortedPorts.count - 1 {
            return nonNegativeNetFlowIndex
        }

        return sortedPorts.count / 2
    }

    // MARK: - Two Sides Corner

    private func processTwoSideCornerLoops() {
        for slLoop in slLoopsByType[.TWO_SIDES_CORNER] ?? [] {
            let sides = Self.sortedTwoSideLoopPortSides(slLoop)
            addToTargetAreaFromLoop(slLoop, sides[0], .END, .PREPEND)
            addToTargetAreaFromLoop(slLoop, sides[1], .START, .APPEND)
        }
    }

    private func processTwoSideOpposingLoops() {
        for slLoop in slLoopsByType[.TWO_SIDES_OPPOSING] ?? [] {
            let sides = Self.sortedTwoSideLoopPortSides(slLoop)
            addToTargetAreaFromLoop(slLoop, sides[0], .END, .PREPEND)
            addToTargetAreaFromLoop(slLoop, sides[1], .START, .APPEND)
        }
    }

    package static func sortedTwoSideLoopPortSides(_ slLoop: SelfHyperLoop) -> [PortSide] {
        var sides = Array(slLoop.getSLPortsBySide().keys).sorted { $0.ordinal < $1.ordinal }
        if sides.count == 2 && sides[0] == .NORTH && sides[1] == .WEST {
            sides = [.WEST, .NORTH]
        }
        return sides
    }

    // MARK: - Three Sides

    private static let NES: [PortSide] = [.NORTH, .EAST, .SOUTH]
    private static let ESW: [PortSide] = [.EAST, .SOUTH, .WEST]
    private static let SWN: [PortSide] = [.SOUTH, .WEST, .NORTH]
    private static let WNE: [PortSide] = [.WEST, .NORTH, .EAST]

    private func processThreeSideLoops() {
        for slLoop in slLoopsByType[.THREE_SIDES] ?? [] {
            let sides = determineLoopConstellation(slLoop)
            addToTargetAreaFromLoop(slLoop, sides[0], .END, .PREPEND)
            addToTargetAreaFromLoop(slLoop, sides[1], .MIDDLE, .APPEND)
            addToTargetAreaFromLoop(slLoop, sides[2], .START, .APPEND)
        }
    }

    private func determineLoopConstellation(_ slLoop: SelfHyperLoop) -> [PortSide] {
        let portSides = Set(slLoop.getSLPortsBySide().keys)
        if !portSides.contains(.NORTH) { return Self.ESW }
        if !portSides.contains(.EAST)  { return Self.SWN }
        if !portSides.contains(.SOUTH) { return Self.WNE }
        if !portSides.contains(.WEST)  { return Self.NES }
        return Self.NES // shouldn't happen
    }

    // MARK: - Four Sides

    private func processFourSideLoops() {
        for slLoop in slLoopsByType[.FOUR_SIDES] ?? [] {
            for side in slLoop.getSLPortsBySide().keys {
                addToTargetAreaFromLoop(slLoop, side, .MIDDLE, .APPEND)
            }
        }
    }

    // MARK: - Placement Utilities

    private func addToTargetAreaFromLoop(_ slLoop: SelfHyperLoop, _ portSide: PortSide,
                                         _ area: PortSideArea, _ addMode: AddMode) {
        addToTargetArea(slLoop.getSLPortsBySide(portSide), portSide, area, addMode)
    }

    private func addToTargetArea(_ slPorts: [SelfLoopPort], _ portSide: PortSide,
                                  _ area: PortSideArea, _ addMode: AddMode) {
        var hiddenPorts = slPorts.filter { $0.isHidden() }
        hiddenPorts.reverse()

        if addMode == .PREPEND {
            targetAreas[portSide]?[area]?.insert(contentsOf: hiddenPorts, at: 0)
        } else {
            targetAreas[portSide]?[area]?.append(contentsOf: hiddenPorts)
        }
    }

    // MARK: - Port Restoring

    private func restorePortsToNode(_ slHolder: SelfLoopHolder) {
        let lNode = slHolder.getLNode()

        let oldPortList = Array(lNode.getPorts())
        var nextOldPortIndex = 0

        // Clear and rebuild port list
        lNode.ports.removeAll()

        addAll(targetAreas[.NORTH]?[.START] ?? [], lNode)
        nextOldPortIndex = addAllThat(oldPortList, nextOldPortIndex,
            { $0.getSide() == .NORTH && self.isNorthSouthPortWithWestOrWestEastConnections($0) },
            lNode)
        addAll(targetAreas[.NORTH]?[.MIDDLE] ?? [], lNode)
        nextOldPortIndex = addAllThat(oldPortList, nextOldPortIndex,
            { $0.getSide() == .NORTH },
            lNode)
        addAll(targetAreas[.NORTH]?[.END] ?? [], lNode)

        addAll(targetAreas[.EAST]?[.START] ?? [], lNode)
        addAll(targetAreas[.EAST]?[.MIDDLE] ?? [], lNode)
        nextOldPortIndex = addAllThat(oldPortList, nextOldPortIndex,
            { $0.getSide() == .EAST },
            lNode)
        addAll(targetAreas[.EAST]?[.END] ?? [], lNode)

        addAll(targetAreas[.SOUTH]?[.START] ?? [], lNode)
        nextOldPortIndex = addAllThat(oldPortList, nextOldPortIndex,
            { $0.getSide() == .SOUTH && self.isNorthSouthPortWithEastConnections($0) },
            lNode)
        addAll(targetAreas[.SOUTH]?[.MIDDLE] ?? [], lNode)
        nextOldPortIndex = addAllThat(oldPortList, nextOldPortIndex,
            { $0.getSide() == .SOUTH },
            lNode)
        addAll(targetAreas[.SOUTH]?[.END] ?? [], lNode)

        addAll(targetAreas[.WEST]?[.START] ?? [], lNode)
        nextOldPortIndex = addAllThat(oldPortList, nextOldPortIndex,
            { $0.getSide() == .WEST },
            lNode)
        addAll(targetAreas[.WEST]?[.MIDDLE] ?? [], lNode)
        addAll(targetAreas[.WEST]?[.END] ?? [], lNode)

        _ = nextOldPortIndex // suppress unused warning
    }

    private func addAll(_ slPorts: [SelfLoopPort], _ lNode: LNode) {
        for slPort in slPorts {
            slPort.getLPort().setNode(lNode)
        }
    }

    private func addAllThat(_ lPorts: [LPort], _ fromIndex: Int,
                             _ condition: (LPort) -> Bool, _ lNode: LNode) -> Int {
        for i in fromIndex..<lPorts.count {
            let lPort = lPorts[i]
            if condition(lPort) {
                lNode.ports.append(lPort)
            } else {
                return i
            }
        }
        return lPorts.count
    }

    private func isNorthSouthPortWithWestOrWestEastConnections(_ lPort: LPort) -> Bool {
        let connections = northSouthPortConnectionSides(lPort)
        let westConnections = connections.contains(.WEST)
        return westConnections
    }

    private func isNorthSouthPortWithEastConnections(_ lPort: LPort) -> Bool {
        let connections = northSouthPortConnectionSides(lPort)
        return connections.contains(.EAST)
    }

    private func northSouthPortConnectionSides(_ lPort: LPort) -> Set<PortSide> {
        var connectionSides = Set<PortSide>()

        if let portDummy = lPort.getProperty(InternalProperties.PORT_DUMMY) as? LNode {
            for dummyLPort in portDummy.getPorts() {
                if dummyLPort.getProperty(InternalProperties.ORIGIN) as AnyObject === lPort {
                    if !dummyLPort.getConnectedEdges().isEmpty {
                        connectionSides.insert(dummyLPort.getSide())
                    }
                }
            }
        }

        return connectionSides
    }
}
