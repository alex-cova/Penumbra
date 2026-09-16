import Foundation

/**
 * Post-processor for comment boxes. If any comments are found that were removed by the
 * {@link CommentPreprocessor}, they are reinserted and placed above or below their
 * corresponding connected node.
 *
 * <dl>
 *   <dt>Precondition:</dt>
 *      <dd>Comments have been processed by {@link CommentPreprocessor}.</dd>
 *   <dt>Postcondition:</dt>
 *      <dd>Comments that have been removed by pre-processing are reinserted properly in the graph.</dd>
 *   <dt>Slots:</dt>
 *      <dd>After phase 5.</dd>
 * </dl>
 */
package final class CommentPostprocessor: ILayoutProcessor {

    package typealias G = LGraph

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("Comment post-processing", 1)

        for layer in layeredGraph.layers {
            var boxes: [LNode] = []
            for node in layer.nodes {
                let topBoxes = node.getProperty(InternalProperties.TOP_COMMENTS) as? [LNode]
                let bottomBoxes = node.getProperty(InternalProperties.BOTTOM_COMMENTS) as? [LNode]

                if topBoxes != nil || bottomBoxes != nil {
                    process(node, topBoxes: topBoxes, bottomBoxes: bottomBoxes)

                    if let topBoxes = topBoxes {
                        boxes.append(contentsOf: topBoxes)
                    }

                    if let bottomBoxes = bottomBoxes {
                        boxes.append(contentsOf: bottomBoxes)
                    }
                }
            }

            layer.nodes.append(contentsOf: boxes)
        }

        monitor.done()
    }

    /**
     * Process a node with its connected comment boxes.
     */
    package func process(_ node: LNode, topBoxes: [LNode]?, bottomBoxes: [LNode]?) {
        let nodePos = node.position
        let nodeSize = node.size
        let margin = node.margin

        let commentCommentSpacing: Double = node.getProperty(LayeredOptions.SPACING_COMMENT_COMMENT) as? Double ?? 0.0

        if let topBoxes = topBoxes, !topBoxes.isEmpty {
            // determine the total width and maximal height of the top boxes
            var boxesWidth = commentCommentSpacing * Double(topBoxes.count - 1)
            var maxHeight: Double = 0
            for box in topBoxes {
                boxesWidth += box.size.x
                maxHeight = max(maxHeight, box.size.y)
            }

            // place the boxes on top of the node, horizontally centered around the node itself
            var xStart = nodePos.x - (boxesWidth - nodeSize.x) / 2
            let baseLine = nodePos.y - margin.top + maxHeight
            let anchorInc = nodeSize.x / Double(topBoxes.count + 1)
            var anchorX = anchorInc

            for box in topBoxes {
                box.position.x = xStart
                box.position.y = baseLine - box.size.y

                let xStartNext = xStart + box.size.x + commentCommentSpacing

                // set source and target point for the connecting edge
                let boxPort = getBoxPort(box)
                boxPort.position.x = box.size.x / 2 - boxPort.anchor.x
                boxPort.position.y = box.size.y

                if let nodePort = box.getProperty(InternalProperties.COMMENT_CONN_PORT) as? LPort, nodePort.degree == 1 {
                    nodePort.position.x = anchorX - nodePort.anchor.x
                    nodePort.position.y = 0
                    nodePort.node = node
                }

                anchorX += anchorInc
                xStart = xStartNext
            }
        }

        if let bottomBoxes = bottomBoxes, !bottomBoxes.isEmpty {
            // determine the total width and maximal height of the bottom boxes
            var boxesWidth = commentCommentSpacing * Double(bottomBoxes.count - 1)
            var maxHeight: Double = 0
            for box in bottomBoxes {
                boxesWidth += box.size.x
                maxHeight = max(maxHeight, box.size.y)
            }

            // place the boxes in the bottom of the node, horizontally centered around the node itself
            var xStart = nodePos.x - (boxesWidth - nodeSize.x) / 2
            let baseLine = nodePos.y + nodeSize.y + margin.bottom - maxHeight
            let anchorInc = nodeSize.x / Double(bottomBoxes.count + 1)
            var anchorX = anchorInc

            for box in bottomBoxes {
                box.position.x = xStart
                box.position.y = baseLine

                let xStartNext = xStart + box.size.x + commentCommentSpacing

                // set source and target point for the connecting edge
                let boxPort = getBoxPort(box)
                boxPort.position.x = box.size.x / 2 - boxPort.anchor.x
                boxPort.position.y = 0

                if let nodePort = box.getProperty(InternalProperties.COMMENT_CONN_PORT) as? LPort, nodePort.degree == 1 {
                    nodePort.position.x = anchorX - nodePort.anchor.x
                    nodePort.position.y = nodeSize.y
                    nodePort.node = node
                }

                anchorX += anchorInc
                xStart = xStartNext
            }
        }
    }

    /**
     * Retrieve the port of the given comment box that connects it with the
     * corresponding node.
     */
    package func getBoxPort(_ commentBox: LNode) -> LPort {
        guard let nodePort = commentBox.getProperty(InternalProperties.COMMENT_CONN_PORT) as? LPort else {
            guard let port = commentBox.ports.first else {
                assertionFailure("getBoxPort: commentBox has no ports")
                return LPort()
            }
            return port
        }

        for port in commentBox.ports {
            for edge in port.outgoingEdges {
                // reconnect the edge (has been disconnected by pre-processor)
                edge.target = nodePort
                return port
            }
            for edge in port.incomingEdges {
                // reconnect the edge (has been disconnected by pre-processor)
                edge.source = nodePort
                return port
            }
        }
        guard let port = commentBox.ports.first else {
            assertionFailure("getBoxPort: commentBox has no ports after iteration")
            return LPort()
        }
        return port
    }
}
