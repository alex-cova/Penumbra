import Foundation

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/AbstractBarycenterPortDistributor.java
package class org_eclipse_elk_alg_layered_p3order_AbstractBarycenterPortDistributor:
    org_eclipse_elk_alg_layered_p3order_ISweepPortDistributor,
    org_eclipse_elk_alg_layered_p3order_counting_IInitializable
{
    package static let PORT_CONSTRAINTS_KEY: any IProperty = Property<org_eclipse_elk_core_options_PortConstraints>("org.eclipse.elk.portConstraints")
    package static let PORT_DUMMY_KEY: any IProperty = Property<org_eclipse_elk_alg_layered_graph_LNode>("portDummy")
    package static let ORIGIN_KEY: any IProperty = Property<org_eclipse_elk_alg_layered_graph_LPort>("origin")
    package static let SORTED_PORTS_KEY: any IProperty = Property<[org_eclipse_elk_alg_layered_graph_LPort]>("org.eclipse.elk.alg.layered.p3order.sortedPorts.todo")

    package var portRanks: [Float] = []
    package var minBarycenter: Float = 0.0
    package var maxBarycenter: Float = 0.0
    package var nodePositions: [[Int]]
    package var portBarycenter: [Float] = []
    package var inLayerPorts: [org_eclipse_elk_alg_layered_graph_LPort] = []
    package var nPorts: Int = 0

    package init(_ numLayers: Int) {
        self.nodePositions = Array(repeating: [], count: max(0, numLayers))
    }

    package func getPortRanks() -> [Float] {
        return portRanks
    }

    package func setPortRank(_ portId: Int, _ rank: Float) {
        ensurePortArraysContain(portId)
        portRanks[portId] = rank
    }

    package func distributePortsWhileSweeping(
        _ nodeOrder: [[org_eclipse_elk_alg_layered_graph_LNode]],
        _ currentIndex: Int,
        _ isForwardSweep: Bool
    ) -> Bool {
        updateNodePositions(nodeOrder, currentIndex)
        let freeLayer = nodeOrder[currentIndex]
        let side: org_eclipse_elk_core_options_PortSide = isForwardSweep ? .WEST : .EAST

        if isNotFirstLayer(nodeOrder.count, currentIndex, isForwardSweep) {
            let fixedLayer = nodeOrder[isForwardSweep ? currentIndex - 1 : currentIndex + 1]
            calculatePortRanks(fixedLayer, portTypeFor(isForwardSweep))
            for node in freeLayer {
                distributePorts(node, side)
            }

            calculatePortRanks(freeLayer, portTypeFor(!isForwardSweep))
            for node in fixedLayer where !hasNestedGraph(node) {
                distributePorts(node, side.opposed())
            }
        } else {
            for node in freeLayer {
                distributePorts(node, side)
            }
        }

        // Java behavior: barycenter port distributors do not guarantee monotonic improvement.
        return false
    }

    package final func calculatePortRanks(
        _ layer: [org_eclipse_elk_alg_layered_graph_LNode],
        _ portType: org_eclipse_elk_alg_layered_options_PortType
    ) {
        var consumedRank: Float = 0.0
        for node in layer {
            consumedRank += calculatePortRanks(node, consumedRank, portType)
        }
    }

    package func calculatePortRanks(
        _ node: org_eclipse_elk_alg_layered_graph_LNode,
        _ rankSum: Float,
        _ type: org_eclipse_elk_alg_layered_options_PortType
    ) -> Float {
        assertionFailure("Abstract method calculatePortRanks(node, rankSum, type) is not implemented.")
        return 0
    }

    package func distributePorts(
        _ node: org_eclipse_elk_alg_layered_graph_LNode,
        _ side: org_eclipse_elk_core_options_PortSide
    ) {
        let pc = portConstraintsOf(node)
        if !(pc.isOrderFixed()) {
            distributePorts(node, node.getPorts(side))
            distributePorts(node, node.getPorts(.SOUTH))
            distributePorts(node, node.getPorts(.NORTH))
            sortPorts(node)
        }
    }

    package func distributePorts(
        _ node: org_eclipse_elk_alg_layered_graph_LNode,
        _ ports: [org_eclipse_elk_alg_layered_graph_LPort]
    ) {
        inLayerPorts.removeAll(keepingCapacity: true)
        iteratePortsAndCollectInLayerPorts(node, ports)
        if !inLayerPorts.isEmpty {
            calculateInLayerPortsBarycenterValues(node)
        }
    }

    package func iteratePortsAndCollectInLayerPorts(
        _ node: org_eclipse_elk_alg_layered_graph_LNode,
        _ ports: [org_eclipse_elk_alg_layered_graph_LPort]
    ) {
        minBarycenter = 0.0
        maxBarycenter = 0.0

        let layerSize = node.getLayer()?.getNodes().count ?? 0
        let absurdlyLargeFloat = Float(2 * layerSize + 1)

        portLoop: for port in ports {
            let northSouthPort = port.getSide() == .NORTH || port.getSide() == .SOUTH
            var sum: Float = 0.0
            var degree: Int = 0

            if northSouthPort {
                guard let portDummy: org_eclipse_elk_alg_layered_graph_LNode =
                    port.getProperty(Self.PORT_DUMMY_KEY)
                else {
                    continue
                }
                let nsResult = dealWithNorthSouthPorts(absurdlyLargeFloat, port, portDummy)
                sum += nsResult
            } else {
                for outgoingEdge in port.getOutgoingEdges() {
                    guard let connectedPort = outgoingEdge.getTarget(),
                          let connectedNode = connectedPort.getNode(),
                          let connectedLayer = connectedNode.getLayer(),
                          let nodeLayer = node.getLayer() else {
                        continue
                    }
                    let sameLayer = connectedLayer === nodeLayer
                    let rank = rankOfPort(connectedPort)
                    if sameLayer {
                        inLayerPorts.append(port)
                        continue portLoop
                    } else {
                        sum += rank
                    }
                }

                for incomingEdge in port.getIncomingEdges() {
                    guard let connectedPort = incomingEdge.getSource(),
                          let connectedNode = connectedPort.getNode(),
                          let connectedLayer = connectedNode.getLayer(),
                          let nodeLayer = node.getLayer() else {
                        continue
                    }
                    let sameLayer = connectedLayer === nodeLayer
                    let rank = rankOfPort(connectedPort)
                    if sameLayer {
                        inLayerPorts.append(port)
                        continue portLoop
                    } else {
                        sum -= rank
                    }
                }
            }

            degree = port.getDegree()
            ensurePortArraysContain(port.id)
            if degree > 0 {
                portBarycenter[port.id] = sum / Float(degree)
                minBarycenter = Swift.min(minBarycenter, portBarycenter[port.id])
                maxBarycenter = Swift.max(maxBarycenter, portBarycenter[port.id])
            } else if northSouthPort {
                portBarycenter[port.id] = sum
            }
        }
    }

    package func calculateInLayerPortsBarycenterValues(
        _ node: org_eclipse_elk_alg_layered_graph_LNode
    ) {
        let nodeIndexInLayer = positionOf(node) + 1
        let layerSize = (node.getLayer()?.getNodes().count ?? 0) + 1

        for inLayerPort in inLayerPorts {
            var sum = 0
            var inLayerConnections = 0
            for connectedPort in inLayerPort.getConnectedPorts() {
                guard let connectedNode = connectedPort.getNode(),
                      let connectedLayer = connectedNode.getLayer(),
                      let nodeLayer = node.getLayer() else {
                    continue
                }
                if connectedLayer === nodeLayer {
                    sum += positionOf(connectedNode) + 1
                    inLayerConnections += 1
                }
            }

            guard inLayerConnections > 0 else { continue }
            let barycenter = Float(sum) / Float(inLayerConnections)
            ensurePortArraysContain(inLayerPort.id)

            let portSide = inLayerPort.getSide()
            if portSide == .EAST {
                if barycenter < Float(nodeIndexInLayer) {
                    portBarycenter[inLayerPort.id] = minBarycenter - barycenter
                } else {
                    portBarycenter[inLayerPort.id] = maxBarycenter + (Float(layerSize) - barycenter)
                }
            } else if portSide == .WEST {
                if barycenter < Float(nodeIndexInLayer) {
                    portBarycenter[inLayerPort.id] = maxBarycenter + barycenter
                } else {
                    portBarycenter[inLayerPort.id] = minBarycenter - (Float(layerSize) - barycenter)
                }
            }
        }
    }

    package func dealWithNorthSouthPorts(
        _ absurdlyLargeFloat: Float,
        _ port: org_eclipse_elk_alg_layered_graph_LPort,
        _ portDummy: org_eclipse_elk_alg_layered_graph_LNode
    ) -> Float {
        var input = false
        var output = false

        for portDummyPort in portDummy.getPorts() {
            let origin: org_eclipse_elk_alg_layered_graph_LPort? = portDummyPort.getProperty(Self.ORIGIN_KEY)
            if origin === port {
                if !portDummyPort.getOutgoingEdges().isEmpty {
                    output = true
                } else if !portDummyPort.getIncomingEdges().isEmpty {
                    input = true
                }
            }
        }

        if input && (input != output) {
            let pos = Float(positionOf(portDummy))
            return port.getSide() == .NORTH ? -pos : absurdlyLargeFloat - pos
        } else if output && (input != output) {
            return Float(positionOf(portDummy)) + 1.0
        } else if input && output {
            return port.getSide() == .NORTH ? 0.0 : absurdlyLargeFloat / 2.0
        }
        return 0.0
    }

    package func positionOf(_ node: org_eclipse_elk_alg_layered_graph_LNode) -> Int {
        guard let layer = node.getLayer() else { return 0 }
        let layerId = layer.id
        if layerId < 0 || layerId >= nodePositions.count {
            return 0
        }
        let row = nodePositions[layerId]
        if node.id < 0 || node.id >= row.count {
            return 0
        }
        return row[node.id]
    }

    package func updateNodePositions(
        _ nodeOrder: [[org_eclipse_elk_alg_layered_graph_LNode]],
        _ currentIndex: Int
    ) {
        let layer = nodeOrder[currentIndex]
        for (i, node) in layer.enumerated() {
            guard let l = node.getLayer() else { continue }
            ensureNodePositionRow(layerId: l.id, nodeCount: max(node.id + 1, layer.count))
            nodePositions[l.id][node.id] = i
        }
    }

    package func hasNestedGraph(_ node: org_eclipse_elk_alg_layered_graph_LNode) -> Bool {
        node.getNestedGraph() != nil
    }

    package func isNotFirstLayer(_ length: Int, _ currentIndex: Int, _ isForwardSweep: Bool) -> Bool {
        isForwardSweep ? currentIndex != 0 : currentIndex != max(0, length - 1)
    }

    package func portTypeFor(_ isForwardSweep: Bool) -> org_eclipse_elk_alg_layered_options_PortType {
        isForwardSweep ? .OUTPUT : .INPUT
    }

    package func sortPorts(_ node: org_eclipse_elk_alg_layered_graph_LNode) {
        let sorted = node.getPorts().sorted { port1, port2 in
            let side1 = port1.getSide()
            let side2 = port2.getSide()
            if side1 != side2 {
                return sideOrdinal(side1) < sideOrdinal(side2)
            }

            // Match Java's Float.compare semantics: straightforward numeric comparison
            let p1 = barycenterOf(port1)
            let p2 = barycenterOf(port2)
            return p1 < p2
        }

        node.ports = sorted
        node.setProperty(Self.SORTED_PORTS_KEY, sorted)
    }

    package func sideOrdinal(_ side: org_eclipse_elk_core_options_PortSide) -> Int {
        switch side {
        case .UNDEFINED: return 0
        case .NORTH: return 1
        case .EAST: return 2
        case .SOUTH: return 3
        case .WEST: return 4
        }
    }

    package func initAtLayerLevel(_ l: Int, _ nodeOrder: [[org_eclipse_elk_alg_layered_graph_LNode]]) {
        let nodeCount = (l >= 0 && l < nodeOrder.count) ? nodeOrder[l].count : 0
        ensureNodePositionRow(layerId: l, nodeCount: nodeCount)
    }

    package func initAtNodeLevel(_ l: Int, _ n: Int, _ nodeOrder: [[org_eclipse_elk_alg_layered_graph_LNode]]) {
        let node = nodeOrder[l][n]
        node.id = n
        ensureNodePositionRow(layerId: l, nodeCount: nodeOrder[l].count)
        nodePositions[l][n] = n
    }

    package func initAtPortLevel(_ l: Int, _ n: Int, _ p: Int, _ nodeOrder: [[org_eclipse_elk_alg_layered_graph_LNode]]) {
        let ports = nodeOrder[l][n].getPorts()
        guard p >= 0 && p < ports.count else { return }
        ports[p].id = nPorts
        nPorts += 1
    }

    package func initAfterTraversal() {
        portRanks = Array(repeating: 0.0, count: nPorts)
        portBarycenter = Array(repeating: 0.0, count: nPorts)
    }

    package func ensureNodePositionRow(layerId: Int, nodeCount: Int) {
        guard layerId >= 0 else { return }
        if layerId >= nodePositions.count {
            nodePositions += Array(repeating: [], count: layerId - nodePositions.count + 1)
        }
        if nodePositions[layerId].count < nodeCount {
            nodePositions[layerId] += Array(repeating: 0, count: nodeCount - nodePositions[layerId].count)
        }
    }

    package func ensurePortArraysContain(_ portId: Int) {
        guard portId >= 0 else { return }
        if portRanks.count <= portId {
            portRanks += Array(repeating: 0.0, count: portId - portRanks.count + 1)
        }
        if portBarycenter.count <= portId {
            portBarycenter += Array(repeating: 0.0, count: portId - portBarycenter.count + 1)
        }
    }

    package func rankOfPort(_ port: org_eclipse_elk_alg_layered_graph_LPort) -> Float {
        let id = port.id
        guard id >= 0 && id < portRanks.count else {
            return 0.0
        }
        let r = portRanks[id]
        return r
    }

    package func barycenterOf(_ port: org_eclipse_elk_alg_layered_graph_LPort) -> Float {
        let id = port.id
        guard id >= 0 && id < portBarycenter.count else { return 0.0 }
        return portBarycenter[id]
    }

    package func portConstraintsOf(
        _ node: org_eclipse_elk_alg_layered_graph_LNode
    ) -> org_eclipse_elk_core_options_PortConstraints {
        (node.getProperty(Self.PORT_CONSTRAINTS_KEY) as? org_eclipse_elk_core_options_PortConstraints) ?? .UNDEFINED
    }
}
