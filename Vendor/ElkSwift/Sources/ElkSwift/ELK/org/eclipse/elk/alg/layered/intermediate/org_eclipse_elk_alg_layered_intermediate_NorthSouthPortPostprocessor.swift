// Transpiled from Java source: NorthSouthPortPostprocessor.java
// Removes dummy nodes created by NorthSouthPortPreprocessor and routes edges properly.

import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_NorthSouthPortPostprocessor {

    package init() {}

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        monitor.begin("Odd port side processing", 1)

        let routing = layeredGraph.getProperty(LayeredOptions.EDGE_ROUTING) as? EdgeRouting

        for layer in layeredGraph.getLayers() {
            let nodeArray = LGraphUtil.toNodeArray(layer.getNodes())
            for node in nodeArray {
                guard node.getType() == .NORTH_SOUTH_PORT else { continue }

                if routing == .SPLINES {
                    for port in node.getPorts() {
                        if !port.getIncomingEdges().isEmpty {
                            processSplineInputPort(port)
                        }
                        if !port.getOutgoingEdges().isEmpty {
                            processSplineOutputPort(port)
                        }
                    }
                } else if node.getProperty(InternalProperties.ORIGIN) is LEdge {
                    processSelfLoop(node)
                } else {
                    // Check if all ports were created for the same origin port
                    let sameOriginPort: Bool
                    if node.getPorts().count >= 2 {
                        var allSame = true
                        let ports = node.getPorts()
                        for i in 1..<ports.count {
                            let prev = ports[i - 1].getProperty(InternalProperties.ORIGIN) as AnyObject?
                            let curr = ports[i].getProperty(InternalProperties.ORIGIN) as AnyObject?
                            if prev !== curr {
                                allSame = false
                                break
                            }
                        }
                        sameOriginPort = allSame
                    } else {
                        sameOriginPort = false
                    }

                    for port in node.getPorts() {
                        if !port.getIncomingEdges().isEmpty {
                            processInputPort(port, sameOriginPort)
                        }
                        if !port.getOutgoingEdges().isEmpty {
                            processOutputPort(port, sameOriginPort)
                        }
                    }
                }

                // Remove the node
                node.setLayer(nil)
            }
        }

        monitor.done()
    }

    private func processInputPort(_ inputPort: LPort, _ addJunctionPoints: Bool) {
        guard let originPort = inputPort.getProperty(InternalProperties.ORIGIN) as? LPort else { return }
        guard let node = inputPort.getNode() else { return }

        let x = originPort.getAbsoluteAnchor().x
        let y = node.getPosition().y

        let edgeArray = LGraphUtil.toEdgeArray(inputPort.getIncomingEdges())
        for inEdge in edgeArray {
            inEdge.setTarget(originPort)
            inEdge.getBendPoints().addLast(x, y)

            if addJunctionPoints {
                let jp: KVectorChain
                if let existing = inEdge.getProperty(LayeredOptions.JUNCTION_POINTS) as? KVectorChain {
                    jp = existing
                } else {
                    jp = KVectorChain()
                    inEdge.setProperty(LayeredOptions.JUNCTION_POINTS, jp)
                }
                jp.add(KVector(x, y))
            }
        }
    }

    private func processOutputPort(_ outputPort: LPort, _ addJunctionPoints: Bool) {
        guard let originPort = outputPort.getProperty(InternalProperties.ORIGIN) as? LPort else { return }
        guard let node = outputPort.getNode() else { return }

        let x = originPort.getAbsoluteAnchor().x
        let y = node.getPosition().y

        let edgeArray = LGraphUtil.toEdgeArray(outputPort.getOutgoingEdges())
        for outEdge in edgeArray {
            outEdge.setSource(originPort)
            outEdge.getBendPoints().addFirst(x, y)

            if addJunctionPoints {
                let jp: KVectorChain
                if let existing = outEdge.getProperty(LayeredOptions.JUNCTION_POINTS) as? KVectorChain {
                    jp = existing
                } else {
                    jp = KVectorChain()
                    outEdge.setProperty(LayeredOptions.JUNCTION_POINTS, jp)
                }
                jp.add(KVector(x, y))
            }
        }
    }

    private func processSelfLoop(_ dummy: LNode) {
        guard let selfLoop = dummy.getProperty(InternalProperties.ORIGIN) as? LEdge else { return }
        guard let inputPort = dummy.getPorts(PortSide.WEST).first else { return }
        guard let outputPort = dummy.getPorts(PortSide.EAST).first else { return }
        guard let originInputPort = inputPort.getProperty(InternalProperties.ORIGIN) as? LPort else { return }
        guard let originOutputPort = outputPort.getProperty(InternalProperties.ORIGIN) as? LPort else { return }

        selfLoop.setSource(originOutputPort)
        selfLoop.setTarget(originInputPort)

        guard let outputNode = outputPort.getNode() else { return }
        guard let inputNode = inputPort.getNode() else { return }

        let bendPoint1 = KVector(outputNode.getPosition())
        bendPoint1.x = originOutputPort.getAbsoluteAnchor().x
        selfLoop.getBendPoints().add(bendPoint1)

        let bendPoint2 = KVector(inputNode.getPosition())
        bendPoint2.x = originInputPort.getAbsoluteAnchor().x
        selfLoop.getBendPoints().add(bendPoint2)
    }

    private func processSplineInputPort(_ inputPort: LPort) {
        guard let originPort = inputPort.getProperty(InternalProperties.ORIGIN) as? LPort else { return }
        guard let inputNode = inputPort.getNode() else { return }
        originPort.setProperty(InternalProperties.SPLINE_NS_PORT_Y_COORD, inputNode.getPosition().y)

        let edgeArray = LGraphUtil.toEdgeArray(inputPort.getIncomingEdges())
        for inEdge in edgeArray {
            inEdge.setTarget(originPort)
        }
    }

    private func processSplineOutputPort(_ outputPort: LPort) {
        guard let originPort = outputPort.getProperty(InternalProperties.ORIGIN) as? LPort else { return }
        guard let outputNode = outputPort.getNode() else { return }
        originPort.setProperty(InternalProperties.SPLINE_NS_PORT_Y_COORD, outputNode.getPosition().y)

        let edgeArray = LGraphUtil.toEdgeArray(outputPort.getOutgoingEdges())
        for outEdge in edgeArray {
            outEdge.setSource(originPort)
        }
    }
}
