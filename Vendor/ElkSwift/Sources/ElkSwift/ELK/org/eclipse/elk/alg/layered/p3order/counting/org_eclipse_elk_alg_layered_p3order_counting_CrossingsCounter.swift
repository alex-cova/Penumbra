// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/counting/CrossingsCounter.java
import Foundation

package final class org_eclipse_elk_alg_layered_p3order_counting_CrossingsCounter {
    // In Java, int[] portPositions is a reference type shared across all CrossingsCounter
    // instances created from the same array. SharedIntArray preserves this semantics in Swift.
    package var portPositions: SharedIntArray
    private var indexTree: org_eclipse_elk_alg_layered_p3order_counting_BinaryIndexedTree?
    private var ends: [Int] = []
    private var nodeCardinalities: [Int] = []

    package init() {
        self.portPositions = SharedIntArray()
    }

    package init(_ portPositions: SharedIntArray) {
        self.portPositions = portPositions
    }

    /// Convenience init wrapping a plain [Int] into its own SharedIntArray.
    /// Use the SharedIntArray init when multiple counters must share the same backing storage.
    package init(_ portPositions: [Int]) {
        self.portPositions = SharedIntArray(repeating: 0, count: portPositions.count)
        self.portPositions.values = portPositions
    }

    // MARK: - Public API

    package func countCrossingsBetweenLayers(
        _ leftLayerNodes: [LNode],
        _ rightLayerNodes: [LNode]
    ) -> Int {
        let ports = initPortPositionsCounterClockwise(leftLayerNodes, rightLayerNodes)
        indexTree = org_eclipse_elk_alg_layered_p3order_counting_BinaryIndexedTree(ports.count)
        return countCrossingsOnPorts(ports)
    }

    package func countInLayerCrossingsOnSide(
        _ nodes: [LNode],
        _ side: PortSide
    ) -> Int {
        let ports = initPortPositionsForInLayerCrossings(nodes, side)
        return countInLayerCrossingsOnPorts(ports)
    }

    package func countNorthSouthPortCrossingsInLayer(
        _ layer: [LNode]
    ) -> Int {
        let ports = initPositionsForNorthSouthCounting(layer)
        indexTree = org_eclipse_elk_alg_layered_p3order_counting_BinaryIndexedTree(ports.count)
        return countNorthSouthCrossingsOnPorts(ports)
    }

    package func initForCountingBetween(_ leftLayerNodes: [LNode], _ rightLayerNodes: [LNode]) {
        let ports = initPortPositionsCounterClockwise(leftLayerNodes, rightLayerNodes)
        indexTree = org_eclipse_elk_alg_layered_p3order_counting_BinaryIndexedTree(ports.count)
    }

    @discardableResult
    package func initPortPositionsForInLayerCrossings(_ nodes: [LNode], _ side: PortSide) -> [LPort] {
        var ports: [LPort] = []
        initPositions(nodes, &ports, side, true, true)
        indexTree = org_eclipse_elk_alg_layered_p3order_counting_BinaryIndexedTree(ports.count)
        return ports
    }

    package func switchPorts(_ topPort: LPort, _ bottomPort: LPort) {
        let topPortPos = portPositions[topPort.id]
        portPositions[topPort.id] = portPositions[bottomPort.id]
        portPositions[bottomPort.id] = topPortPos
    }

    package func switchNodes(_ wasUpperNode: LNode, _ wasLowerNode: LNode, _ side: PortSide) {
        for port in CrossMinUtil.inNorthSouthEastWestOrder(wasUpperNode, side) {
            portPositions[port.id] = positionOf(port) + nodeCardinalities[wasLowerNode.id]
        }
        for port in CrossMinUtil.inNorthSouthEastWestOrder(wasLowerNode, side) {
            portPositions[port.id] = positionOf(port) - nodeCardinalities[wasUpperNode.id]
        }
    }

    package func countCrossingsBetweenPortsInBothOrders(
        _ upperPort: org_eclipse_elk_alg_layered_graph_LPort,
        _ lowerPort: org_eclipse_elk_alg_layered_graph_LPort
    ) -> org_eclipse_elk_core_util_Pair<Int, Int> {
        let ports = connectedPortsSortedByPosition(upperPort, lowerPort)
        let upperLowerCrossings = countCrossingsOnPorts(ports)
        indexTree?.clear()
        switchPorts(upperPort, lowerPort)
        let sortedPorts = ports.sorted { positionOf($0) < positionOf($1) }
        let lowerUpperCrossings = countCrossingsOnPorts(sortedPorts)
        indexTree?.clear()
        switchPorts(lowerPort, upperPort)
        return org_eclipse_elk_core_util_Pair<Int, Int>.of(upperLowerCrossings, lowerUpperCrossings)
    }

    package func countInLayerCrossingsBetweenNodesInBothOrders(
        _ upperNode: LNode,
        _ lowerNode: LNode,
        _ side: PortSide
    ) -> org_eclipse_elk_core_util_Pair<Int, Int> {
        let ports = connectedInLayerPortsSortedByPosition(upperNode, lowerNode, side)
        let upperLowerCrossings = countInLayerCrossingsOnPorts(ports)
        switchNodes(upperNode, lowerNode, side)
        indexTree?.clear()
        let sortedPorts = ports.sorted { positionOf($0) < positionOf($1) }
        let lowerUpperCrossings = countInLayerCrossingsOnPorts(sortedPorts)
        switchNodes(lowerNode, upperNode, side)
        indexTree?.clear()
        return org_eclipse_elk_core_util_Pair<Int, Int>.of(upperLowerCrossings, lowerUpperCrossings)
    }

    // MARK: - Private helpers

    private func connectedPortsSortedByPosition(
        _ upperPort: org_eclipse_elk_alg_layered_graph_LPort,
        _ lowerPort: org_eclipse_elk_alg_layered_graph_LPort
    ) -> [org_eclipse_elk_alg_layered_graph_LPort] {
        var seen = Set<ObjectIdentifier>()
        var result: [(org_eclipse_elk_alg_layered_graph_LPort, Int)] = []
        for port in [upperPort, lowerPort] {
            let id = ObjectIdentifier(port)
            if seen.insert(id).inserted {
                result.append((port, positionOf(port)))
            }
            for edge in port.getConnectedEdges() {
                if !isPortSelfLoop(edge) {
                    let other = otherEndOf(edge, port)
                    let otherId = ObjectIdentifier(other)
                    if seen.insert(otherId).inserted {
                        result.append((other, positionOf(other)))
                    }
                }
            }
        }
        result.sort { $0.1 < $1.1 }
        return result.map(\.0)
    }

    private func connectedInLayerPortsSortedByPosition(
        _ upperNode: LNode,
        _ lowerNode: LNode,
        _ side: PortSide
    ) -> [LPort] {
        // Use a TreeSet-like sorted unique collection
        var seen = Set<ObjectIdentifier>()
        var result: [(LPort, Int)] = []
        for node in [upperNode, lowerNode] {
            for port in CrossMinUtil.inNorthSouthEastWestOrder(node, side) {
                for edge in port.getConnectedEdges() {
                    if !edge.isSelfLoop() {
                        let portId = ObjectIdentifier(port)
                        if seen.insert(portId).inserted {
                            result.append((port, positionOf(port)))
                        }
                        if isInLayer(edge) {
                            let other = otherEndOf(edge, port)
                            let otherId = ObjectIdentifier(other)
                            if seen.insert(otherId).inserted {
                                result.append((other, positionOf(other)))
                            }
                        }
                    }
                }
            }
        }
        result.sort { $0.1 < $1.1 }
        return result.map(\.0)
    }

    private func isPortSelfLoop(_ edge: org_eclipse_elk_alg_layered_graph_LEdge) -> Bool {
        edge.getSource() === edge.getTarget()
    }

    // MARK: - Private counting

    private func countCrossingsOnPorts(_ ports: [LPort]) -> Int {
        guard let tree = indexTree else { return 0 }
        var crossings = 0
        for port in ports {
            tree.removeAll(positionOf(port))
            for edge in port.getConnectedEdges() {
                let endPosition = positionOf(otherEndOf(edge, port))
                if endPosition > positionOf(port) {
                    crossings += tree.rank(endPosition)
                    ends.append(endPosition)
                }
            }
            while !ends.isEmpty {
                tree.add(ends.removeLast())
            }
        }
        return crossings
    }

    private func countInLayerCrossingsOnPorts(_ ports: [LPort]) -> Int {
        guard let tree = indexTree else { return 0 }
        var crossings = 0
        for port in ports {
            tree.removeAll(positionOf(port))
            var numBetweenLayerEdges = 0
            for edge in port.getConnectedEdges() {
                if isInLayer(edge) {
                    let endPosition = positionOf(otherEndOf(edge, port))
                    if endPosition > positionOf(port) {
                        crossings += tree.rank(endPosition)
                        ends.append(endPosition)
                    }
                } else {
                    numBetweenLayerEdges += 1
                }
            }
            crossings += tree.size() * numBetweenLayerEdges
            while !ends.isEmpty {
                tree.add(ends.removeLast())
            }
        }
        return crossings
    }

    private func countNorthSouthCrossingsOnPorts(_ ports: [LPort]) -> Int {
        guard let tree = indexTree else { return 0 }
        var crossings = 0
        var targetsAndDegrees: [(LPort, Int)] = []

        for port in ports {
            tree.removeAll(positionOf(port))
            targetsAndDegrees.removeAll(keepingCapacity: true)

            switch port.getNode()?.getType() {
            case .NORMAL:
                if let dummy = port.getProperty(InternalProperties.PORT_DUMMY) as? LNode {
                    for p in dummy.getPorts() {
                        targetsAndDegrees.append((p, p.getDegree()))
                    }
                }
            case .LONG_EDGE:
                if let node = port.getNode() {
                    if let otherPort = node.getPorts().first(where: { $0 !== port }) {
                        targetsAndDegrees.append((otherPort, otherPort.getDegree()))
                    }
                }
            case .NORTH_SOUTH_PORT:
                if let dummyPort = port.getProperty(InternalProperties.ORIGIN) as? LPort {
                    targetsAndDegrees.append((dummyPort, port.getDegree()))
                }
            default:
                break
            }

            for (target, degree) in targetsAndDegrees {
                let endPosition = positionOf(target)
                if endPosition > positionOf(port) {
                    crossings += tree.rank(endPosition) * degree
                    ends.append(endPosition)
                }
            }

            while !ends.isEmpty {
                tree.add(ends.removeLast())
            }
        }

        return crossings
    }

    // MARK: - Port position initialization

    private func initPortPositionsCounterClockwise(
        _ leftLayerNodes: [LNode],
        _ rightLayerNodes: [LNode]
    ) -> [LPort] {
        var ports: [LPort] = []
        initPositions(leftLayerNodes, &ports, .EAST, true, false)
        initPositions(rightLayerNodes, &ports, .WEST, false, false)
        return ports
    }

    private func initPositions(
        _ nodes: [LNode],
        _ ports: inout [LPort],
        _ side: PortSide,
        _ topDown: Bool,
        _ getCardinalities: Bool
    ) {
        var numPorts = ports.count
        if getCardinalities {
            nodeCardinalities = Array(repeating: 0, count: nodes.count)
        }

        var i = topDown ? 0 : nodes.count - 1
        while topDown ? (i < nodes.count) : (i >= 0) {
            let node = nodes[i]
            let nodePorts = getPorts(node, side, topDown)
            if getCardinalities, node.id >= 0, node.id < nodeCardinalities.count {
                nodeCardinalities[node.id] = nodePorts.count
            }
            for port in nodePorts {
                if port.id >= 0, port.id < portPositions.count {
                    portPositions[port.id] = numPorts
                }
                numPorts += 1
            }
            ports.append(contentsOf: nodePorts)
            i += topDown ? 1 : -1
        }
    }

    private static let INDEXING_SIDE: PortSide = .WEST
    private static let STACK_SIDE: PortSide = .EAST

    private func initPositionsForNorthSouthCounting(_ nodes: [LNode]) -> [LPort] {
        var ports: [LPort] = []
        var stack: [LNode] = []

        var lastLayoutUnit: LNode? = nil
        var index = 0

        for i in 0..<nodes.count {
            let current = nodes[i]

            if isLayoutUnitChanged(lastLayoutUnit, current) {
                index = emptyStack(&stack, &ports, Self.STACK_SIDE, index)
            }
            if current.hasProperty(InternalProperties.IN_LAYER_LAYOUT_UNIT) {
                lastLayoutUnit = current.getProperty(InternalProperties.IN_LAYER_LAYOUT_UNIT) as? LNode
            }

            switch current.getType() {
            case .NORMAL:
                for p in getNorthSouthPortsWithIncidentEdges(current, .NORTH) {
                    if p.id >= 0, p.id < portPositions.count {
                        portPositions[p.id] = index
                    }
                    index += 1
                    ports.append(p)
                }

                index = emptyStack(&stack, &ports, Self.STACK_SIDE, index)

                for p in getNorthSouthPortsWithIncidentEdges(current, .SOUTH) {
                    if p.id >= 0, p.id < portPositions.count {
                        portPositions[p.id] = index
                    }
                    index += 1
                    ports.append(p)
                }

            case .NORTH_SOUTH_PORT:
                let westPorts = current.getPortSideView(Self.INDEXING_SIDE)
                if !westPorts.isEmpty {
                    let p = westPorts[0]
                    if p.id >= 0, p.id < portPositions.count {
                        portPositions[p.id] = index
                    }
                    index += 1
                    ports.append(p)
                }
                let eastPorts = current.getPortSideView(Self.STACK_SIDE)
                if !eastPorts.isEmpty {
                    stack.append(current)
                }

            case .LONG_EDGE:
                for p in current.getPortSideView(.WEST) {
                    if p.id >= 0, p.id < portPositions.count {
                        portPositions[p.id] = index
                    }
                    index += 1
                    ports.append(p)
                }
                for _ in current.getPortSideView(.EAST) {
                    stack.append(current)
                }

            default:
                break
            }
        }

        _ = emptyStack(&stack, &ports, Self.STACK_SIDE, index)

        return ports
    }

    private func emptyStack(
        _ stack: inout [LNode],
        _ ports: inout [LPort],
        _ side: PortSide,
        _ startIndex: Int
    ) -> Int {
        var index = startIndex
        while !stack.isEmpty {
            let dummy = stack.removeLast()
            let sidePorts = dummy.getPortSideView(side)
            guard !sidePorts.isEmpty else { continue }
            let p = sidePorts[0]
            if p.id >= 0, p.id < portPositions.count {
                portPositions[p.id] = index
            }
            index += 1
            ports.append(p)
        }
        return index
    }

    // MARK: - Convenience

    private func getPorts(_ node: LNode, _ side: PortSide, _ topDown: Bool) -> [LPort] {
        let sidePorts = node.getPortSideView(side)
        if side == .EAST {
            return topDown ? sidePorts : sidePorts.reversed()
        } else {
            return topDown ? sidePorts.reversed() : sidePorts
        }
    }

    private func getNorthSouthPortsWithIncidentEdges(_ node: LNode, _ side: PortSide) -> [LPort] {
        node.getPortSideView(side).filter { $0.hasProperty(InternalProperties.PORT_DUMMY) }
    }

    private func isInLayer(_ edge: LEdge) -> Bool {
        guard let sourceLayer = edge.getSource()?.getNode()?.getLayer(),
              let targetLayer = edge.getTarget()?.getNode()?.getLayer()
        else { return false }
        return sourceLayer === targetLayer
    }

    private func positionOf(_ port: LPort) -> Int {
        let id = port.id
        guard id >= 0, id < portPositions.count else { return 0 }
        return portPositions[id]
    }

    private func otherEndOf(_ edge: LEdge, _ fromPort: LPort) -> LPort {
        if fromPort === edge.getSource() {
            guard let target = edge.getTarget() else { return fromPort }
            return target
        } else {
            guard let source = edge.getSource() else { return fromPort }
            return source
        }
    }

    private func isLayoutUnitChanged(_ lastUnit: LNode?, _ node: LNode) -> Bool {
        guard let lastUnit else { return false }
        if lastUnit === node { return false }
        guard node.hasProperty(InternalProperties.IN_LAYER_LAYOUT_UNIT) else { return false }
        let unit = node.getProperty(InternalProperties.IN_LAYER_LAYOUT_UNIT) as? LNode
        return unit !== lastUnit
    }
}
