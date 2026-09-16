import Foundation

/**
 * This processor does some work to ensure that other phases and processors can handle
 * self-loops correctly.
 *
 * <dl>
 *   <dt>Precondition:</dt><dd>a layered graph.</dd>
 *   <dt>Postcondition:</dt><dd>long edge dummies were inserted for special kinds of self
 *     loops.</dd>
 *   <dt>Slots:</dt><dd>Before phase 3.</dd>
 *   <dt>Same-slot dependencies:</dt><dd>{@link InvertedPortProcessor}</dd>
 * </dl>
 */
package final class DummySelfLoopProcessor: ILayoutProcessor {

    package typealias G = LGraph

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("Self-loop processing", 1)

        // Iterate through all nodes
        var createdDummies: [LNode] = []

        for layer in layeredGraph {
            createdDummies.removeAll()

            for node in layer.nodes {
                for port in node.ports {
                    // Go through the port's outgoing edges
                    let edges = LGraphUtil.toEdgeArray(port.outgoingEdges)

                    for edge in edges {
                        // We're only interested in edges whose source and target node are identical
                        guard let sourceNode = edge.source?.node, let targetNode = edge.target?.node,
                              sourceNode === targetNode else {
                            continue
                        }

                        guard let sourcePort = edge.source, let targetPort = edge.target else { continue }
                        let sourcePortSide = sourcePort.side
                        let targetPortSide = targetPort.side

                        // First, let's deal with the cases where edges have to be reversed
                        if ((sourcePortSide == PortSide.NORTH || sourcePortSide == PortSide.SOUTH)
                            && targetPortSide == PortSide.WEST) {

                            edge.reverse(layeredGraph, false)
                        } else if sourcePortSide == PortSide.SOUTH
                            && targetPortSide == PortSide.NORTH {

                            edge.reverse(layeredGraph, false)
                        } else if sourcePortSide == PortSide.EAST
                            && targetPortSide != PortSide.EAST {

                            edge.reverse(layeredGraph, false)
                        }

                        // Now, let's see if a dummy has to be inserted
                        if sourcePortSide == PortSide.EAST && targetPortSide == PortSide.WEST {
                            // Note that the edge was reversed, so source and target port have switched
                            createdDummies.append(createDummy(layeredGraph, edge, targetPort, sourcePort))
                        } else if sourcePortSide == PortSide.WEST && targetPortSide == PortSide.EAST {
                            createdDummies.append(createDummy(layeredGraph, edge, sourcePort, targetPort))
                        }
                    }
                }
            }

            // Add the dummies, if any
            for dummy in createdDummies {
                dummy.layer = layer
            }
        }

        monitor.done()
    }

    /**
     * Creates a dummy for the self-loop edge connecting the two given ports.
     */
    package func createDummy(_ layeredGraph: LGraph, _ edge: LEdge, _ sourcePort: LPort,
                             _ targetPort: LPort) -> LNode {

        // Create a dummy node with an input port and an output port
        let dummyNode = LNode(layeredGraph: layeredGraph)
        dummyNode.type = NodeType.longEdge

        dummyNode.setProperty(InternalProperties.ORIGIN, value: edge)
        dummyNode.setProperty(LayeredOptions.PORT_CONSTRAINTS, value: PortConstraints.FIXED_POS)
        dummyNode.setProperty(InternalProperties.LONG_EDGE_SOURCE, value: sourcePort)
        dummyNode.setProperty(InternalProperties.LONG_EDGE_TARGET, value: targetPort)

        let dummyInput = LPort()
        dummyInput.side = PortSide.WEST
        dummyInput.node = dummyNode

        let dummyOutput = LPort()
        dummyOutput.side = PortSide.EAST
        dummyOutput.node = dummyNode

        edge.target = dummyInput

        // Create a dummy edge
        let dummyEdge = LEdge()
        dummyEdge.copyProperties(from: edge)
        dummyEdge.setProperty(LayeredOptions.JUNCTION_POINTS, value: nil)
        dummyEdge.source = dummyOutput
        dummyEdge.target = targetPort

        return dummyNode
    }
}
