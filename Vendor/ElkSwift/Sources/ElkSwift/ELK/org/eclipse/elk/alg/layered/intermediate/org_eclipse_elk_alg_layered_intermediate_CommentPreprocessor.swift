import Foundation

/**
 * A pre-processor for comment boxes. Looks for comments that have exactly one connection
 * to a normal node and removes them from the graph. Such comments are put either into
 * the `InternalProperties.TOP_COMMENTS` or the `InternalProperties.BOTTOM_COMMENTS` list
 * of the connected node and processed later by the `CommentPostprocessor`.
 *
 * <dl>
 *   <dt>Precondition:</dt>
 *      <dd>none</dd>
 *   <dt>Postcondition:</dt>
 *      <dd>Comments with only one connection to a port of degree 1 are removed and stored for later
 *      processing.</dd>
 *   <dt>Slots:</dt>
 *      <dd>Before phase 1.</dd>
 * </dl>
 */
package final class CommentPreprocessor: ILayoutProcessor {

    package typealias G = LGraph

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("Comment pre-processing", 1)

        var commentBoxCount = 0

        var nodesToRemove: [Int] = []
        for (index, node) in layeredGraph.layerlessNodes.enumerated() {
            if node.getProperty(LayeredOptions.COMMENT_BOX) as? Bool ?? false {
                commentBoxCount += 1

                var edgeCount = 0
                var edge: LEdge? = nil
                var oppositePort: LPort? = nil

                for port in node.ports {
                    edgeCount += port.degree
                    if port.incomingEdges.count == 1 {
                        edge = port.incomingEdges[0]
                        oppositePort = edge?.source
                    }
                    if port.outgoingEdges.count == 1 {
                        edge = port.outgoingEdges[0]
                        oppositePort = edge?.target
                    }
                }

                if let edge = edge, let oppositePort = oppositePort,
                   edgeCount == 1 && oppositePort.degree == 1
                    && !(oppositePort.node?.getProperty(LayeredOptions.COMMENT_BOX) as? Bool ?? false),
                    let realNode = oppositePort.node {
                    // found a comment that has exactly one connection
                    processBox(box: node, edge: edge, oppositePort: oppositePort, realNode: realNode)
                    nodesToRemove.append(index)
                } else {
                    // reverse edges that are oddly connected
                    var revEdges: [LEdge] = []

                    for port in node.ports {
                        for outedge in port.outgoingEdges {
                            if !(outedge.target?.outgoingEdges.isEmpty ?? true) {
                                revEdges.append(outedge)
                            }
                        }

                        for inedge in port.incomingEdges {
                            if !(inedge.source?.incomingEdges.isEmpty ?? true) {
                                revEdges.append(inedge)
                            }
                        }
                    }

                    for re in revEdges {
                        re.reverse(layeredGraph, true)
                    }
                }
            }
        }

        // Remove nodes in reverse order
        for index in nodesToRemove.reversed() {
            layeredGraph.layerlessNodes.remove(at: index)
        }

        if monitor.isLoggingEnabled() {
            monitor.log("Found \(commentBoxCount) comment boxes")
        }

        monitor.done()
    }

    /**
     * Process a comment box by putting it into a property of the corresponding node.
     */
    package func processBox(box: LNode, edge: LEdge, oppositePort: LPort, realNode: LNode) {
        var topFirst = false
        var onlyTop = false
        var onlyBottom = false

        if (realNode.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .UNDEFINED).isSideFixed() {
            var hasNorth = false
            var hasSouth = false

            portLoop: for port1 in realNode.ports {
                for port2 in port1.getConnectedPorts() {
                    if !(port2.node?.getProperty(LayeredOptions.COMMENT_BOX) as? Bool ?? false) {
                        if port1.side == PortSide.NORTH {
                            hasNorth = true
                            break portLoop
                        }
                        if port1.side == PortSide.SOUTH {
                            hasSouth = true
                            break portLoop
                        }
                    }
                }
            }
            onlyTop = hasSouth && !hasNorth
            onlyBottom = hasNorth && !hasSouth
        }

        if !onlyTop && !onlyBottom && !realNode.labels.isEmpty {
            var labelPos: Double = 0
            for label in realNode.labels {
                labelPos += label.position.y + label.size.y / 2
            }
            labelPos /= Double(realNode.labels.count)
            topFirst = labelPos >= realNode.size.y / 2
        } else {
            topFirst = !onlyBottom
        }

        var boxList: [LNode]

        if topFirst {
            // determine the position to use, favoring the top position
            if let topBoxes = realNode.getProperty(InternalProperties.TOP_COMMENTS) as? [LNode] {
                if onlyTop {
                    boxList = topBoxes
                } else if let bottomBoxes = realNode.getProperty(InternalProperties.BOTTOM_COMMENTS) as? [LNode] {
                    if topBoxes.count <= bottomBoxes.count {
                        boxList = topBoxes
                    } else {
                        boxList = bottomBoxes
                    }
                } else {
                    boxList = []
                    realNode.setProperty(InternalProperties.BOTTOM_COMMENTS, boxList)
                }
            } else {
                boxList = []
                realNode.setProperty(InternalProperties.TOP_COMMENTS, boxList)
            }
        } else {
            // determine the position to use, favoring the bottom position
            if let bottomBoxes = realNode.getProperty(InternalProperties.BOTTOM_COMMENTS) as? [LNode] {
                if onlyBottom {
                    boxList = bottomBoxes
                } else if let topBoxes = realNode.getProperty(InternalProperties.TOP_COMMENTS) as? [LNode] {
                    if bottomBoxes.count <= topBoxes.count {
                        boxList = bottomBoxes
                    } else {
                        boxList = topBoxes
                    }
                } else {
                    boxList = []
                    realNode.setProperty(InternalProperties.TOP_COMMENTS, boxList)
                }
            } else {
                boxList = []
                realNode.setProperty(InternalProperties.BOTTOM_COMMENTS, boxList)
            }
        }

        // add the comment box to one of the two possible lists
        boxList.append(box)

        // set the opposite port as property for the comment box
        box.setProperty(InternalProperties.COMMENT_CONN_PORT, oppositePort)

        // detach the edge and the opposite port
        if edge.target === oppositePort {
            edge.target = nil
            if oppositePort.degree == 0 {
                oppositePort.node = nil
            }
            removeHierarchicalPortDummyNode(oppositePort)
        } else {
            edge.source = nil
            if oppositePort.degree == 0 {
                oppositePort.node = nil
            }
        }
        edge.bendPoints.clear()
    }

    package func removeHierarchicalPortDummyNode(_ oppositePort: LPort) {
        if let dummy = oppositePort.getProperty(InternalProperties.PORT_DUMMY) as? LNode {
            if let layer = dummy.layer {
                if let index = layer.nodes.firstIndex(of: dummy) {
                    layer.nodes.remove(at: index)
                }
                if layer.nodes.isEmpty {
                    if let graph = dummy.graph, let layerIndex = graph.layers.firstIndex(of: layer) {
                        graph.layers.remove(at: layerIndex)
                    }
                }
            }
        }
    }
}
