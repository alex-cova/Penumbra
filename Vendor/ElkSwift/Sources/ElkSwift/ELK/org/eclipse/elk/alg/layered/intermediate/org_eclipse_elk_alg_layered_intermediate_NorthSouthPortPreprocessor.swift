// Transpiled from Java source: NorthSouthPortPreprocessor.java
// Inserts dummy nodes to cope with northern and southern ports.

import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_NorthSouthPortPreprocessor {

    private static let USE_NEW_APPROACH = true

    package init() {}

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        monitor.begin("Odd port side processing", 1)

        var pointer: Int
        var northDummyNodes: [LNode] = []
        var southDummyNodes: [LNode] = []

        for layer in layeredGraph.getLayers() {
            pointer = -1

            let nodeArray = LGraphUtil.toNodeArray(layer.getNodes())
            for node in nodeArray {
                pointer += 1

                // We only care about non-dummy nodes with fixed port sides
                let portConstraints = node.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints
                guard node.getType() == .NORMAL,
                      portConstraints?.isSideFixed() == true else {
                    continue
                }

                // Sort the port list if we have control over the port order
                if portConstraints?.isOrderFixed() != true {
                    let strategy = node.getGraph()?.getProperty(LayeredOptions.CONSIDER_MODEL_ORDER_STRATEGY)
                    if strategy == nil || (strategy as? OrderingStrategy) == .NONE {
                        sortPortList(node)
                    }
                }

                // Nodes form their own layout unit
                node.setProperty(InternalProperties.IN_LAYER_LAYOUT_UNIT, node as Any)

                northDummyNodes.removeAll()
                southDummyNodes.removeAll()

                var barycenterAssociates: [LNode] = []

                // Prepare ports on the northern side
                var portList: [LPort] = node.getPorts(PortSide.NORTH)

                if let strategy = node.getGraph()?.getProperty(LayeredOptions.CONSIDER_MODEL_ORDER_STRATEGY) as? OrderingStrategy,
                   strategy != .NONE {
                    portList = modelOrderNorthSouthInputReversing(portList, node)
                }

                createDummyNodes(layeredGraph, portList, &northDummyNodes, &southDummyNodes,
                                 &barycenterAssociates)

                let insertPoint = pointer
                var successor = node
                for dummy in northDummyNodes {
                    dummy.setLayer(insertPoint, layer)
                    pointer += 1

                    dummy.setProperty(InternalProperties.IN_LAYER_LAYOUT_UNIT, node as Any)

                    assert(dummy.getPorts().count >= 1)
                    let dummyPort = dummy.getPorts()[0]
                    if let originPort = dummyPort.getProperty(InternalProperties.ORIGIN) as? LPort {
                        if originPort.getProperty(LayeredOptions.ALLOW_NON_FLOW_PORTS_TO_SWITCH_SIDES) != true {
                            var constraints = dummy.getProperty(InternalProperties.IN_LAYER_SUCCESSOR_CONSTRAINTS) as? [LNode] ?? []
                            constraints.append(successor)
                            dummy.setProperty(InternalProperties.IN_LAYER_SUCCESSOR_CONSTRAINTS, constraints as Any)
                        }
                    }

                    if !Self.USE_NEW_APPROACH {
                        successor = dummy
                    }
                }

                // Southern ports - listed right to left, so reverse
                var southPortList: [LPort] = node.getPorts(PortSide.SOUTH).reversed()

                if let strategy = node.getGraph()?.getProperty(LayeredOptions.CONSIDER_MODEL_ORDER_STRATEGY) as? OrderingStrategy,
                   strategy != .NONE {
                    southPortList = modelOrderNorthSouthInputReversing(southPortList, node)
                }

                createDummyNodesForSouth(layeredGraph, southPortList, &southDummyNodes,
                                         &barycenterAssociates)

                var predecessor = node
                for dummy in southDummyNodes {
                    pointer += 1
                    dummy.setLayer(pointer, layer)

                    dummy.setProperty(InternalProperties.IN_LAYER_LAYOUT_UNIT, node as Any)

                    assert(dummy.getPorts().count >= 1)
                    let dummyPort = dummy.getPorts()[0]
                    if let originPort = dummyPort.getProperty(InternalProperties.ORIGIN) as? LPort {
                        if originPort.getProperty(LayeredOptions.ALLOW_NON_FLOW_PORTS_TO_SWITCH_SIDES) != true {
                            var constraints = predecessor.getProperty(InternalProperties.IN_LAYER_SUCCESSOR_CONSTRAINTS) as? [LNode] ?? []
                            constraints.append(dummy)
                            predecessor.setProperty(InternalProperties.IN_LAYER_SUCCESSOR_CONSTRAINTS, constraints as Any)
                        }
                    }

                    if !Self.USE_NEW_APPROACH {
                        predecessor = dummy
                    }
                }

                if !barycenterAssociates.isEmpty {
                    node.setProperty(InternalProperties.BARYCENTER_ASSOCIATES, barycenterAssociates as Any)
                }
            }
        }

        monitor.done()
    }

    // MARK: - Port List Sorting

    private func sortPortList(_ node: LNode) {
        let portCount = node.getPorts().count

        var inPortsId = 0
        var inOutPortsId = portCount
        var outPortsId = 2 * portCount

        for port in node.getPorts() {
            switch port.getSide() {
            case .EAST, .WEST:
                port.id = -1
            case .NORTH, .SOUTH:
                let incoming = port.getIncomingEdges().count
                let outgoing = port.getOutgoingEdges().count

                if incoming > 0 && outgoing > 0 {
                    port.id = inOutPortsId
                    inOutPortsId += 1
                } else if incoming > 0 {
                    port.id = inPortsId
                    inPortsId += 1
                } else if outgoing > 0 {
                    port.id = outPortsId
                    outPortsId += 1
                } else {
                    port.id = inPortsId
                    inPortsId += 1
                }
            default:
                break
            }
        }

        let ports = node.getPorts()
        let sorted = ports.sorted { (port1: LPort, port2: LPort) -> Bool in
            let side1 = port1.getSide()
            let side2 = port2.getSide()

            if side1 != side2 {
                return side1.ordinal < side2.ordinal
            } else {
                if port1.id == port2.id {
                    return false
                }
                if side1 == .NORTH {
                    return port1.id < port2.id
                } else {
                    return port2.id < port1.id
                }
            }
        }
        // Replace the port list contents
        node.ports = sorted
    }

    private func modelOrderNorthSouthInputReversing(_ portList: [LPort], _ node: LNode) -> [LPort] {
        var incoming: [LPort] = []
        var outgoing: [LPort] = []
        for port in portList {
            if !port.getIncomingEdges().isEmpty {
                incoming.append(port)
            } else {
                outgoing.append(port)
            }
        }
        incoming.reverse()
        incoming.append(contentsOf: outgoing)
        return incoming
    }

    // MARK: - Dummy Node Creation

    private func createDummyNodes(
        _ layeredGraph: LGraph,
        _ ports: [LPort],
        _ dummyNodes: inout [LNode],
        _ opposingSideDummyNodes: inout [LNode],
        _ barycenterAssociates: inout [LNode]
    ) {
        var sameSideSelfLoopEdges: [LEdge] = []
        var northSouthSelfLoopEdges: [LEdge] = []

        for port in ports {
            for edge in port.getOutgoingEdges() {
                if edge.getSource()?.getNode() === edge.getTarget()?.getNode() {
                    if port.getSide() == edge.getTarget()?.getSide() {
                        sameSideSelfLoopEdges.append(edge)
                        continue
                    } else if port.getSide() == .NORTH && edge.getTarget()?.getSide() == .SOUTH {
                        northSouthSelfLoopEdges.append(edge)
                        continue
                    }
                }
            }
        }

        // Create north->south self-loop dummies
        for edge in northSouthSelfLoopEdges {
            createNorthSouthSelfLoopDummyNodes(layeredGraph, edge, &dummyNodes,
                                                &opposingSideDummyNodes, PortSide.EAST)
        }

        // Create same-side self-loop dummies
        for edge in sameSideSelfLoopEdges {
            createSameSideSelfLoopDummyNode(layeredGraph, edge, &dummyNodes)
        }

        classifyAndCreateDummies(layeredGraph, ports, &dummyNodes, &barycenterAssociates)
    }

    /// Same as createDummyNodes but without opposingSideDummyNodes (used for southern ports)
    private func createDummyNodesForSouth(
        _ layeredGraph: LGraph,
        _ ports: [LPort],
        _ dummyNodes: inout [LNode],
        _ barycenterAssociates: inout [LNode]
    ) {
        var sameSideSelfLoopEdges: [LEdge] = []

        for port in ports {
            for edge in port.getOutgoingEdges() {
                if edge.getSource()?.getNode() === edge.getTarget()?.getNode() {
                    if port.getSide() == edge.getTarget()?.getSide() {
                        sameSideSelfLoopEdges.append(edge)
                    }
                }
            }
        }

        for edge in sameSideSelfLoopEdges {
            createSameSideSelfLoopDummyNode(layeredGraph, edge, &dummyNodes)
        }

        classifyAndCreateDummies(layeredGraph, ports, &dummyNodes, &barycenterAssociates)
    }

    private func classifyAndCreateDummies(
        _ layeredGraph: LGraph,
        _ ports: [LPort],
        _ dummyNodes: inout [LNode],
        _ barycenterAssociates: inout [LNode]
    ) {
        var inPorts: [LPort] = []
        var outPorts: [LPort] = []
        var inOutPorts: [LPort] = []

        for port in ports {
            let hasIn = port.getIncomingEdges().count > 0
            let hasOut = port.getOutgoingEdges().count > 0

            if hasIn && hasOut {
                inOutPorts.append(port)
            } else if hasIn {
                inPorts.append(port)
            } else if hasOut {
                outPorts.append(port)
            }
        }

        if Self.USE_NEW_APPROACH {
            for inPort in inPorts {
                barycenterAssociates.append(createDummyNode(layeredGraph, inPort, nil, &dummyNodes))
            }
            for outPort in outPorts {
                barycenterAssociates.append(createDummyNode(layeredGraph, nil, outPort, &dummyNodes))
            }
        } else {
            var inPortsIndex = 0
            var outPortsIndex = outPorts.count - 1

            while inPortsIndex < inPorts.count && outPortsIndex >= 0 {
                let inPort = inPorts[inPortsIndex]
                let outPort = outPorts[outPortsIndex]

                guard let outIdx = ports.firstIndex(where: { $0 === outPort }),
                      let inIdx = ports.firstIndex(where: { $0 === inPort }) else { break }
                if outIdx < inIdx { break }

                barycenterAssociates.append(createDummyNode(layeredGraph, inPort, outPort, &dummyNodes))
                inPortsIndex += 1
                outPortsIndex -= 1
            }

            while inPortsIndex < inPorts.count {
                barycenterAssociates.append(createDummyNode(layeredGraph, inPorts[inPortsIndex], nil, &dummyNodes))
                inPortsIndex += 1
            }

            while outPortsIndex >= 0 {
                barycenterAssociates.append(createDummyNode(layeredGraph, nil, outPorts[outPortsIndex], &dummyNodes))
                outPortsIndex -= 1
            }
        }

        for inOutPort in inOutPorts {
            barycenterAssociates.append(createDummyNode(layeredGraph, inOutPort, inOutPort, &dummyNodes))
        }
    }

    private func createDummyNode(
        _ layeredGraph: LGraph,
        _ inPort: LPort?,
        _ outPort: LPort?,
        _ dummyNodes: inout [LNode]
    ) -> LNode {
        let dummy = LNode(layeredGraph)
        dummy.setType(.NORTH_SOUTH_PORT)
        dummy.setProperty(LayeredOptions.PORT_CONSTRAINTS, PortConstraints.FIXED_POS)

        var crossingHint = 0

        if let inPort = inPort {
            let dummyInputPort = LPort()
            dummyInputPort.setProperty(InternalProperties.ORIGIN, inPort as Any)
            dummy.setProperty(InternalProperties.ORIGIN, inPort.getNode() as Any)
            dummyInputPort.setSide(PortSide.WEST)
            dummyInputPort.setNode(dummy)

            let edgeArray = LGraphUtil.toEdgeArray(inPort.getIncomingEdges())
            for edge in edgeArray {
                edge.setTarget(dummyInputPort)
            }

            inPort.setProperty(InternalProperties.PORT_DUMMY, dummy as Any)
            crossingHint += 1
        }

        if let outPort = outPort {
            let dummyOutputPort = LPort()
            dummy.setProperty(InternalProperties.ORIGIN, outPort.getNode() as Any)
            dummyOutputPort.setProperty(InternalProperties.ORIGIN, outPort as Any)
            dummyOutputPort.setSide(PortSide.EAST)
            dummyOutputPort.setNode(dummy)

            let edgeArray = LGraphUtil.toEdgeArray(outPort.getOutgoingEdges())
            for edge in edgeArray {
                edge.setSource(dummyOutputPort)
            }

            outPort.setProperty(InternalProperties.PORT_DUMMY, dummy as Any)
            crossingHint += 1
        }

        dummy.setProperty(InternalProperties.CROSSING_HINT, crossingHint)
        dummyNodes.append(dummy)
        return dummy
    }

    private func createSameSideSelfLoopDummyNode(
        _ layeredGraph: LGraph,
        _ selfLoop: LEdge,
        _ dummyNodes: inout [LNode]
    ) {
        let dummy = LNode(layeredGraph)
        dummy.setType(.NORTH_SOUTH_PORT)
        dummy.setProperty(LayeredOptions.PORT_CONSTRAINTS, PortConstraints.FIXED_POS)
        dummy.setProperty(InternalProperties.ORIGIN, selfLoop as Any)

        let dummyInputPort = LPort()
        dummyInputPort.setProperty(InternalProperties.ORIGIN, selfLoop.getTarget() as Any)
        dummyInputPort.setSide(PortSide.WEST)
        dummyInputPort.setNode(dummy)

        let dummyOutputPort = LPort()
        dummyOutputPort.setProperty(InternalProperties.ORIGIN, selfLoop.getSource() as Any)
        dummyOutputPort.setSide(PortSide.EAST)
        dummyOutputPort.setNode(dummy)

        selfLoop.getSource()?.setProperty(InternalProperties.PORT_DUMMY, dummy as Any)
        selfLoop.getTarget()?.setProperty(InternalProperties.PORT_DUMMY, dummy as Any)

        selfLoop.setSource(nil)
        selfLoop.setTarget(nil)

        dummyNodes.append(dummy)
        dummy.setProperty(InternalProperties.CROSSING_HINT, 2)
    }

    private func createNorthSouthSelfLoopDummyNodes(
        _ layeredGraph: LGraph,
        _ selfLoop: LEdge,
        _ northDummyNodes: inout [LNode],
        _ southDummyNodes: inout [LNode],
        _ portSide: PortSide
    ) {
        // North dummy
        let northDummy = LNode(layeredGraph)
        northDummy.setType(.NORTH_SOUTH_PORT)
        northDummy.setProperty(LayeredOptions.PORT_CONSTRAINTS, PortConstraints.FIXED_POS)
        northDummy.setProperty(InternalProperties.ORIGIN, selfLoop.getSource()?.getNode() as Any)

        let northDummyOutputPort = LPort()
        northDummyOutputPort.setProperty(InternalProperties.ORIGIN, selfLoop.getSource() as Any)
        northDummyOutputPort.setSide(portSide)
        northDummyOutputPort.setNode(northDummy)

        selfLoop.getSource()?.setProperty(InternalProperties.PORT_DUMMY, northDummy as Any)

        // South dummy
        let southDummy = LNode(layeredGraph)
        southDummy.setType(.NORTH_SOUTH_PORT)
        southDummy.setProperty(LayeredOptions.PORT_CONSTRAINTS, PortConstraints.FIXED_POS)
        southDummy.setProperty(InternalProperties.ORIGIN, selfLoop.getTarget()?.getNode() as Any)

        let southDummyInputPort = LPort()
        southDummyInputPort.setProperty(InternalProperties.ORIGIN, selfLoop.getTarget() as Any)
        southDummyInputPort.setSide(portSide)
        southDummyInputPort.setNode(southDummy)

        selfLoop.getTarget()?.setProperty(InternalProperties.PORT_DUMMY, southDummy as Any)

        // Reroute the edge
        selfLoop.setSource(northDummyOutputPort)
        selfLoop.setTarget(southDummyInputPort)

        northDummyNodes.insert(northDummy, at: 0)
        southDummyNodes.append(southDummy)

        northDummy.setProperty(InternalProperties.CROSSING_HINT, 1)
        southDummy.setProperty(InternalProperties.CROSSING_HINT, 1)
    }
}
