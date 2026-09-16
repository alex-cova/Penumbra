import Foundation

/**
 * Makes sure nodes with edge or layer constraints have only incoming or only outgoing edges, as appropriate.
 *
 * <dl>
 *   <dt>Precondition:</dt>
 *     <dd>an unlayered graph.</dd>
 *   <dt>Postcondition:</dt>
 *     <dd>nodes with layer constraints have only incoming or only outgoing edges, as appropriate.</dd>
 *   <dt>Slots:</dt>
 *     <dd>Before phase 1.</dd>
 *   <dt>Same-slot dependencies:</dt>
 *     <dd>None.</dd>
 * </dl>
 *
 * @see LayerConstraintProcessor
 */
package final class EdgeAndLayerConstraintEdgeReverser: ILayoutProcessor {

    package typealias G = LGraph

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("Edge and layer constraint edge reversal", 1)

        // Apply edge reversal to all FIRST and FIRST_SEPARATE as well as LAST and LAST_SEPARATE nodes
        let remainingNodes = handleOuterNodes(layeredGraph)

        // Apply edge reversal to remaining nodes
        handleInnerNodes(layeredGraph, remainingNodes)

        monitor.done()
    }

    // Outer Nodes

    /**
     * Ensures that edges incident to outer nodes are correct.
     *
     * @return list of those nodes that are not outer nodes.
     */
    package func handleOuterNodes(_ layeredGraph: LGraph) -> [LNode] {
        var remainingNodes = [LNode]()
        remainingNodes.reserveCapacity(layeredGraph.layerlessNodes.count)

        for node in layeredGraph.layerlessNodes {
            // Check if there is a layer constraint
            let layerConstraint: LayerConstraint = node.getProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT) as? LayerConstraint ?? .NONE
            var edgeConstraint: EdgeConstraint? = nil

            switch layerConstraint {
            case .FIRST, .FIRST_SEPARATE:
                edgeConstraint = .OUTGOING_ONLY
            case .LAST, .LAST_SEPARATE:
                edgeConstraint = .INCOMING_ONLY
            default:
                break
            }

            if let edgeConstraint = edgeConstraint {
                // Set the edge constraint on the node
                node.setProperty(InternalProperties.EDGE_CONSTRAINT, value: edgeConstraint)

                if edgeConstraint == .INCOMING_ONLY {
                    reverseEdges(layeredGraph, node: node, nodeLayerConstraint: layerConstraint, targetPortType: .INPUT)
                } else if edgeConstraint == .OUTGOING_ONLY {
                    reverseEdges(layeredGraph, node: node, nodeLayerConstraint: layerConstraint, targetPortType: .OUTPUT)
                }
            } else {
                // Remember this node for the next loop
                remainingNodes.append(node)
            }
        }

        return remainingNodes
    }

    // Inner Nodes

    /**
     * @param remainingNodes
     */
    package func handleInnerNodes(_ layeredGraph: LGraph, _ remainingNodes: [LNode]) {
        // Iterate over the remaining nodes
        for node in remainingNodes {
            // Check if there is a layer constraint
            let layerConstraint: LayerConstraint = node.getProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT) as? LayerConstraint ?? .NONE
            var edgeConstraint: EdgeConstraint? = nil

            switch layerConstraint {
            case .FIRST, .FIRST_SEPARATE:
                edgeConstraint = .OUTGOING_ONLY
            case .LAST, .LAST_SEPARATE:
                edgeConstraint = .INCOMING_ONLY
            default:
                break
            }

            if let edgeConstraint = edgeConstraint {
                // Set the edge constraint on the node
                node.setProperty(InternalProperties.EDGE_CONSTRAINT, value: edgeConstraint)

                if edgeConstraint == .INCOMING_ONLY {
                    reverseEdges(layeredGraph, node: node, nodeLayerConstraint: layerConstraint, targetPortType: .INPUT)
                } else if edgeConstraint == .OUTGOING_ONLY {
                    reverseEdges(layeredGraph, node: node, nodeLayerConstraint: layerConstraint, targetPortType: .OUTPUT)
                }
            } else {
                // If the port sides are fixed, but all ports are reversed, that probably means that we
                // have a feedback node.
                if (node.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .UNDEFINED).isSideFixed() && !node.ports.isEmpty {

                    var allPortsReversed = true

                    for port in node.ports {
                        if !(port.side == PortSide.EAST && port.getNetFlow() > 0
                                || port.side == PortSide.WEST && port.getNetFlow() < 0) {

                            allPortsReversed = false
                            break
                        }

                        // no LAST or LAST_SEPARATE allowed for the target of outgoing edges
                        for edge in port.outgoingEdges {
                            let lc = edge.target?.node?.getProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT) as? LayerConstraint ?? .NONE
                            if lc == .LAST || lc == .LAST_SEPARATE {
                                allPortsReversed = false
                                break
                            }
                        }
                        // no FIRST or FIRST_SEPARATE allowed for the source of incoming edges
                        for edge in port.incomingEdges {
                            let lc = edge.source?.node?.getProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT) as? LayerConstraint ?? .NONE
                            if lc == .FIRST || lc == .FIRST_SEPARATE {
                                allPortsReversed = false
                                break
                            }
                        }
                    }

                    if allPortsReversed {
                        // Reverse all kinds of edges
                        reverseEdges(layeredGraph, node: node, nodeLayerConstraint: layerConstraint, targetPortType: .UNDEFINED)
                    }
                }
            }
        }
    }

    // Edge Reversal

    package func reverseEdges(_ layeredGraph: LGraph, node: LNode, nodeLayerConstraint: LayerConstraint, targetPortType: PortType) {

        // Iterate through the node's edges and reverse them, if necessary
        for port in LGraphUtil.toPortArray(node.ports) {
            // Only incoming edges
            if targetPortType == .INPUT || targetPortType == .UNDEFINED {
                let outgoing = LGraphUtil.toEdgeArray(port.outgoingEdges)

                for edge in outgoing {
                    // Reverse the edge if we're allowed to do so
                    if canReverseOutgoingEdge(nodeLayerConstraint, edge) {
                        edge.reverse(layeredGraph, true)
                    }
                }
            }

            // Only outgoing edges
            if targetPortType == .OUTPUT || targetPortType == .UNDEFINED {
                let incoming = LGraphUtil.toEdgeArray(port.incomingEdges)

                for edge in incoming {
                    // Reverse the edge if we're allowed to do so
                    if canReverseIncomingEdge(nodeLayerConstraint, edge) {
                        edge.reverse(layeredGraph, true)
                    }
                }
            }
        }
    }

    // Reversal Testing

    package func canReverseOutgoingEdge(_ sourceNodeLayerConstraint: LayerConstraint, _ edge: LEdge) -> Bool {
        // If the edge is already reversed, we don't want to reverse it again
        if edge.getProperty(InternalProperties.REVERSED) as? Bool ?? false {
            return false
        }

        guard let targetNode = edge.target?.node else {
            return false
        }

        // If the node is supposed to be in the LAST layer...
        if sourceNodeLayerConstraint == .LAST {
            if targetNode.type == .label {
                return false
            }
        }

        // If the target is a node in the LAST_SEPARATE layer, we won't reverse it
        let targetLayerConstraint = targetNode.getProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT) as? LayerConstraint ?? .NONE
        if targetLayerConstraint == .LAST_SEPARATE {
            return false
        }

        return true
    }

    package func canReverseIncomingEdge(_ targetNodeLayerConstraint: LayerConstraint, _ edge: LEdge) -> Bool {
        // If the edge is already reversed, we don't want to reverse it again
        if edge.getProperty(InternalProperties.REVERSED) as? Bool ?? false {
            return false
        }

        guard let sourceNode = edge.source?.node else {
            return false
        }

        // If the node is supposed to be in the FIRST layer...
        if targetNodeLayerConstraint == .FIRST {
            if sourceNode.type == .label {
                return false
            }
        }

        // If the source is a node in the FIRST_SEPARATE layer, we won't reverse it
        let sourceLayerConstraint = sourceNode.getProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT) as? LayerConstraint ?? .NONE
        if sourceLayerConstraint == .FIRST_SEPARATE {
            return false
        }

        return true
    }
}
