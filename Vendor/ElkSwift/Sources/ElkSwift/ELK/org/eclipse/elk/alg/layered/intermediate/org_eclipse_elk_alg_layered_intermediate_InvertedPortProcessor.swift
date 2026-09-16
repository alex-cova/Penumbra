import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_InvertedPortProcessor {
    package init() {}

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("Inverted port preprocessing", 1)

        let layers = layeredGraph.layers

        var currentLayer: Layer? = nil
        var unassignedNodes = [LNode]()
        var layerIndex = 0

        while layerIndex < layers.count {
            let previousLayer = currentLayer
            currentLayer = layers[layerIndex]
            layerIndex += 1

            // If the previous layer had unassigned nodes, assign them now
            if let prev = previousLayer {
                for node in unassignedNodes {
                    node.setLayer(prev)
                }
            }
            unassignedNodes.removeAll()

            // Iterate through the layer's nodes
            guard let layer = currentLayer else { continue }
            for node in layer.nodes {
                // Skip dummy nodes
                if node.type != .normal {
                    continue
                }

                // Skip nodes whose port sides are not fixed
                let portConstraints = node.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .UNDEFINED
                if !portConstraints.isSideFixed() {
                    continue
                }

                // Look for input ports on the right side
                for port in node.getPorts(.INPUT, .EAST) {
                    let edgeArray = LGraphUtil.toEdgeArray(port.incomingEdges)
                    for edge in edgeArray {
                        createEastPortSideDummies(layeredGraph, port, edge, &unassignedNodes)
                    }
                }

                // Look for output ports on the left side
                for port in node.getPorts(.OUTPUT, .WEST) {
                    let edgeArray = LGraphUtil.toEdgeArray(port.outgoingEdges)
                    for edge in edgeArray {
                        createWestPortSideDummies(layeredGraph, port, edge, &unassignedNodes)
                    }
                }
            }
        }

        // There may be unassigned nodes left
        if let last = currentLayer {
            for node in unassignedNodes {
                node.setLayer(last)
            }
        }

        monitor.done()
    }

    private func createEastPortSideDummies(_ layeredGraph: LGraph, _ eastwardPort: LPort,
                                            _ edge: LEdge, _ layerNodeList: inout [LNode]) {
        // Ignore self loops
        if edge.source?.node === eastwardPort.node {
            return
        }

        // Dummy node in the same layer
        let dummy = LNode(layeredGraph)
        dummy.type = .longEdge
        dummy.setProperty(InternalProperties.ORIGIN, value: edge)
        dummy.setProperty(LayeredOptions.PORT_CONSTRAINTS, value: PortConstraints.FIXED_POS)
        layerNodeList.append(dummy)

        let dummyInput = LPort()
        dummyInput.setNode(dummy)
        dummyInput.setSide(.WEST)

        let dummyOutput = LPort()
        dummyOutput.setNode(dummy)
        dummyOutput.setSide(.EAST)

        // Reroute the original edge
        edge.setTarget(dummyInput)

        // Connect the dummy with the original port
        let dummyEdge = LEdge()
        _ = dummyEdge.copyProperties(edge)
        dummyEdge.setProperty(LayeredOptions.JUNCTION_POINTS, value: nil as KVectorChain?)
        dummyEdge.setSource(dummyOutput)
        dummyEdge.setTarget(eastwardPort)

        // Set LONG_EDGE_SOURCE and LONG_EDGE_TARGET
        setLongEdgeSourceAndTarget(dummy, dummyInput, dummyOutput, eastwardPort)

        // Move head labels from the old edge over to the new one
        var i = 0
        while i < edge.labels.count {
            let label = edge.labels[i]
            let labelPlacement = label.getProperty(LayeredOptions.EDGE_LABELS_PLACEMENT) as? EdgeLabelPlacement

            if labelPlacement == .head {
                if !label.hasProperty(InternalProperties.END_LABEL_EDGE) {
                    label.setProperty(InternalProperties.END_LABEL_EDGE, value: edge)
                }
                edge.labels.remove(at: i)
                dummyEdge.labels.append(label)
            } else {
                i += 1
            }
        }
    }

    private func createWestPortSideDummies(_ layeredGraph: LGraph, _ westwardPort: LPort,
                                            _ edge: LEdge, _ layerNodeList: inout [LNode]) {
        // Ignore self loops
        if edge.target?.node === westwardPort.node {
            return
        }

        // Dummy node in the same layer
        let dummy = LNode(layeredGraph)
        dummy.type = .longEdge
        dummy.setProperty(InternalProperties.ORIGIN, value: edge)
        dummy.setProperty(LayeredOptions.PORT_CONSTRAINTS, value: PortConstraints.FIXED_POS)
        layerNodeList.append(dummy)

        let dummyInput = LPort()
        dummyInput.setNode(dummy)
        dummyInput.setSide(.WEST)

        let dummyOutput = LPort()
        dummyOutput.setNode(dummy)
        dummyOutput.setSide(.EAST)

        // Reroute the original edge
        let originalTarget = edge.target
        edge.setTarget(dummyInput)

        // Connect the dummy with the original port
        let dummyEdge = LEdge()
        _ = dummyEdge.copyProperties(edge)
        dummyEdge.setProperty(LayeredOptions.JUNCTION_POINTS, value: nil as KVectorChain?)
        dummyEdge.setSource(dummyOutput)
        dummyEdge.setTarget(originalTarget)

        // Move head labels over to the new dummy edge
        var i = 0
        while i < edge.labels.count {
            let label = edge.labels[i]

            if (label.getProperty(LayeredOptions.EDGE_LABELS_PLACEMENT) as? EdgeLabelPlacement) == .head {
                label.setProperty(InternalProperties.END_LABEL_EDGE, value: edge)
                edge.labels.remove(at: i)
                dummyEdge.labels.append(label)
            } else {
                i += 1
            }
        }

        // Set LONG_EDGE_SOURCE and LONG_EDGE_TARGET
        setLongEdgeSourceAndTarget(dummy, dummyInput, dummyOutput, westwardPort)
    }

    private func setLongEdgeSourceAndTarget(_ longEdgeDummy: LNode, _ dummyInputPort: LPort,
                                             _ dummyOutputPort: LPort, _ oddPort: LPort) {
        guard let sourcePort = dummyInputPort.incomingEdges[0].source,
              let sourceNode = sourcePort.node else {
            return
        }
        let sourceNodeType = sourceNode.type

        guard let targetPort = dummyOutputPort.outgoingEdges[0].target,
              let targetNode = targetPort.node else {
            return
        }
        let targetNodeType = targetNode.type

        // Set the LONG_EDGE_SOURCE property
        if sourceNodeType == .longEdge {
            longEdgeDummy.setProperty(InternalProperties.LONG_EDGE_SOURCE,
                value: sourceNode.getProperty(InternalProperties.LONG_EDGE_SOURCE))
        } else {
            longEdgeDummy.setProperty(InternalProperties.LONG_EDGE_SOURCE, value: sourcePort)
        }

        // Set the LONG_EDGE_TARGET property
        if targetNodeType == .longEdge {
            longEdgeDummy.setProperty(InternalProperties.LONG_EDGE_TARGET,
                value: targetNode.getProperty(InternalProperties.LONG_EDGE_TARGET))
        } else {
            longEdgeDummy.setProperty(InternalProperties.LONG_EDGE_TARGET, value: targetPort)
        }
    }
}
