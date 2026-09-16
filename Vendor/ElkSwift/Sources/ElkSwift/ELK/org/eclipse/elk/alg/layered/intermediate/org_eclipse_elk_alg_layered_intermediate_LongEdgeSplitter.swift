import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_LongEdgeSplitter {
    package init() {}

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("Edge splitting", 1)

        if layeredGraph.layers.count <= 2 {
            monitor.done()
            return
        }

        // Iterate through the layers
        var layerIndex = 0
        while layerIndex < layeredGraph.layers.count - 1 {
            let layer = layeredGraph.layers[layerIndex]
            let nextLayer = layeredGraph.layers[layerIndex + 1]

            for node in layer.nodes {
                for port in node.ports {
                    for edge in port.outgoingEdges {
                        guard let targetPort = edge.target else { continue }
                        let targetLayer = targetPort.node?.layer

                        if targetLayer !== layer && targetLayer !== nextLayer {
                            let dummyNode = createDummyNode(layeredGraph, nextLayer, edge)
                            org_eclipse_elk_alg_layered_intermediate_LongEdgeSplitter.splitEdge(edge, dummyNode)
                        }
                    }
                }
            }

            layerIndex += 1
        }

        monitor.done()
    }

    private func createDummyNode(_ layeredGraph: LGraph, _ targetLayer: Layer, _ edgeToSplit: LEdge) -> LNode {
        let dummyNode = LNode(layeredGraph)
        dummyNode.type = .longEdge
        dummyNode.setProperty(InternalProperties.ORIGIN, value: edgeToSplit)
        dummyNode.setProperty(LayeredOptions.PORT_CONSTRAINTS, value: PortConstraints.FIXED_POS)
        dummyNode.setLayer(targetLayer)
        return dummyNode
    }

    @discardableResult
    package static func splitEdge(_ edge: LEdge, _ dummyNode: LNode) -> LEdge {
        guard let oldEdgeTarget = edge.target else { return LEdge() }

        // Set thickness of the edge
        var thickness = edge.getProperty(LayeredOptions.EDGE_THICKNESS) as? Double ?? 0.0
        if thickness < 0 {
            thickness = 0
            edge.setProperty(LayeredOptions.EDGE_THICKNESS, value: thickness)
        }
        dummyNode.size.y = thickness
        let portPos = floor(thickness / 2)

        // Create dummy input and output ports
        let dummyInput = LPort()
        dummyInput.side = .WEST
        dummyInput.setNode(dummyNode)
        dummyInput.position.y = portPos

        let dummyOutput = LPort()
        dummyOutput.side = .EAST
        dummyOutput.setNode(dummyNode)
        dummyOutput.position.y = portPos

        edge.setTarget(dummyInput)

        // Create a dummy edge
        let dummyEdge = LEdge()
        _ = dummyEdge.copyProperties(edge)
        dummyEdge.setProperty(LayeredOptions.JUNCTION_POINTS, value: nil as KVectorChain?)
        dummyEdge.setSource(dummyOutput)
        dummyEdge.setTarget(oldEdgeTarget)

        setDummyNodeProperties(dummyNode, edge, dummyEdge)
        moveHeadLabels(edge, dummyEdge)

        return dummyEdge
    }

    private static func setDummyNodeProperties(_ dummyNode: LNode, _ inEdge: LEdge, _ outEdge: LEdge) {
        guard let inEdgeSource = inEdge.source, let inEdgeSourceNode = inEdgeSource.node,
              let outEdgeTarget = outEdge.target, let outEdgeTargetNode = outEdgeTarget.node else {
            return
        }

        if inEdgeSourceNode.type == .longEdge {
            dummyNode.setProperty(InternalProperties.LONG_EDGE_SOURCE,
                                  value: inEdgeSourceNode.getProperty(InternalProperties.LONG_EDGE_SOURCE))
            dummyNode.setProperty(InternalProperties.LONG_EDGE_TARGET,
                                  value: inEdgeSourceNode.getProperty(InternalProperties.LONG_EDGE_TARGET))
            dummyNode.setProperty(InternalProperties.LONG_EDGE_HAS_LABEL_DUMMIES,
                                  value: inEdgeSourceNode.getProperty(InternalProperties.LONG_EDGE_HAS_LABEL_DUMMIES))
        } else if inEdgeSourceNode.type == .label {
            dummyNode.setProperty(InternalProperties.LONG_EDGE_SOURCE,
                                  value: inEdgeSourceNode.getProperty(InternalProperties.LONG_EDGE_SOURCE))
            dummyNode.setProperty(InternalProperties.LONG_EDGE_TARGET,
                                  value: inEdgeSourceNode.getProperty(InternalProperties.LONG_EDGE_TARGET))
            dummyNode.setProperty(InternalProperties.LONG_EDGE_HAS_LABEL_DUMMIES, value: true)
        } else if outEdgeTargetNode.type == .label {
            dummyNode.setProperty(InternalProperties.LONG_EDGE_SOURCE,
                                  value: outEdgeTargetNode.getProperty(InternalProperties.LONG_EDGE_SOURCE))
            dummyNode.setProperty(InternalProperties.LONG_EDGE_TARGET,
                                  value: outEdgeTargetNode.getProperty(InternalProperties.LONG_EDGE_TARGET))
            dummyNode.setProperty(InternalProperties.LONG_EDGE_HAS_LABEL_DUMMIES, value: true)
        } else {
            dummyNode.setProperty(InternalProperties.LONG_EDGE_SOURCE, value: inEdgeSource)
            dummyNode.setProperty(InternalProperties.LONG_EDGE_TARGET, value: outEdgeTarget)
        }
    }

    private static func moveHeadLabels(_ oldEdge: LEdge, _ newEdge: LEdge) {
        var i = 0
        while i < oldEdge.labels.count {
            let label = oldEdge.labels[i]
            let labelPlacement = label.getProperty(LayeredOptions.EDGE_LABELS_PLACEMENT) as? EdgeLabelPlacement

            if labelPlacement == .head {
                oldEdge.labels.remove(at: i)
                newEdge.labels.append(label)

                if !label.hasProperty(InternalProperties.END_LABEL_EDGE) {
                    label.setProperty(InternalProperties.END_LABEL_EDGE, value: oldEdge)
                }
            } else {
                i += 1
            }
        }
    }
}
