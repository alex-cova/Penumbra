import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_loops_SelfLoopHolder {

    private let lNode: LNode
    private var slHyperLoops: [SelfHyperLoop] = []
    /// LinkedHashMap in Java — we use an array to preserve insertion order,
    /// plus a dictionary for O(1) lookup by LPort identity.
    private var slPortsList: [SelfLoopPort] = []
    private var slPortsMap: [ObjectIdentifier: SelfLoopPort] = [:]

    private var portsHiddenValue: Bool = false
    private let routingSlotCountArray = RoutingSlotCountArray()

    private init(_ node: LNode) {
        self.lNode = node
    }

    // MARK: - Creation

    package static func install(_ lNode: LNode) -> SelfLoopHolder {
        let holder = SelfLoopHolder(lNode)
        _ = lNode.setProperty(InternalProperties.SELF_LOOP_HOLDER, holder)
        holder.initialize()
        return holder
    }

    package static func needsSelfLoopProcessing(_ lNode: LNode) -> Bool {
        if lNode.getType() != .NORMAL {
            return false
        }
        return lNode.getOutgoingEdges().contains { $0.isSelfLoop() }
    }

    // MARK: - Initialization

    private static let UNVISITED = 0
    private static let VISITED = 1

    private func initialize() {
        var slEdges: [SelfLoopEdge] = []

        for lEdge in lNode.getOutgoingEdges() {
            if lEdge.isSelfLoop() {
                guard let edgeSource = lEdge.getSource(), let edgeTarget = lEdge.getTarget() else { continue }
                slEdges.append(SelfLoopEdge(lEdge, selfLoopPortFor(edgeSource), selfLoopPortFor(edgeTarget)))
            }
        }

        // Reset port IDs for BFS
        for slPort in slPortsList {
            slPort.getLPort().id = Self.UNVISITED
        }

        // Run BFS at every port to gather edges into hyperloops
        for slPort in slPortsList {
            if slPort.getLPort().id == Self.UNVISITED {
                slHyperLoops.append(initializeHyperLoop(slPort))
            }
        }
    }

    private func selfLoopPortFor(_ lport: LPort) -> SelfLoopPort {
        let key = ObjectIdentifier(lport)
        if let existing = slPortsMap[key] {
            return existing
        }
        let slPort = SelfLoopPort(lport)
        slPortsMap[key] = slPort
        slPortsList.append(slPort)
        return slPort
    }

    private func initializeHyperLoop(_ slPort: SelfLoopPort) -> SelfHyperLoop {
        let slLoop = SelfHyperLoop(self)

        var bfsQueue = ArrayDeque<SelfLoopPort>([slPort])

        while !bfsQueue.isEmpty {
            let currentSLPort = bfsQueue.removeFirst()
            currentSLPort.getLPort().id = Self.VISITED

            for slEdge in currentSLPort.getOutgoingSLEdges() {
                slLoop.addSelfLoopEdge(slEdge)
                let slTargetPort = slEdge.getSLTarget()
                if slTargetPort.getLPort().id == Self.UNVISITED {
                    bfsQueue.append(slTargetPort)
                }
            }

            for slEdge in currentSLPort.getIncomingSLEdges() {
                slLoop.addSelfLoopEdge(slEdge)
                let slSourcePort = slEdge.getSLSource()
                if slSourcePort.getLPort().id == Self.UNVISITED {
                    bfsQueue.append(slSourcePort)
                }
            }
        }

        return slLoop
    }

    // MARK: - Accessors

    package func getLNode() -> LNode {
        return lNode
    }

    package func getSLHyperLoops() -> [SelfHyperLoop] {
        return slHyperLoops
    }

    package func getSLPortMap() -> [ObjectIdentifier: SelfLoopPort] {
        return slPortsMap
    }

    /// Returns the ordered list of SelfLoopPorts (preserving insertion order like Java's LinkedHashMap.values()).
    package func getSLPortValues() -> [SelfLoopPort] {
        return slPortsList
    }

    package func arePortsHidden() -> Bool {
        return portsHiddenValue
    }

    package func setPortsHidden(_ hidden: Bool) {
        self.portsHiddenValue = hidden
    }

    package func getRoutingSlotCount() -> RoutingSlotCountArray {
        return routingSlotCountArray
    }
}

/// Reference-type wrapper for an Int array, so SelfHyperLoop.setRoutingSlot can mutate it through a reference.
package final class RoutingSlotCountArray {
    private var storage: [Int] = [Int](repeating: 0, count: 5) // PortSide enum count

    package subscript(index: Int) -> Int {
        get { return storage[index] }
        set { storage[index] = newValue }
    }
}
