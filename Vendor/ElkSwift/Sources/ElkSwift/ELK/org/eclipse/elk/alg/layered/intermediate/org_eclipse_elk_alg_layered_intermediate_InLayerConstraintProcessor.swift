import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_InLayerConstraintProcessor {
    package init() {}

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("Layer constraint edge reversal", 1)

        for layer in layeredGraph.layers {
            var topInsertionIndex = -1
            var bottomConstrainedNodes = [LNode]()

            let nodes = LGraphUtil.toNodeArray(layer.nodes)

            for i in 0..<nodes.count {
                let constraint: InLayerConstraint =
                    nodes[i].getProperty(InternalProperties.IN_LAYER_CONSTRAINT) as? InLayerConstraint ?? .NONE

                if topInsertionIndex == -1 {
                    if constraint != .TOP {
                        topInsertionIndex = i
                    }
                } else {
                    if constraint == .TOP {
                        // Move the node to the top insertion point
                        nodes[i].setLayer(nil)
                        // Insert at specific index
                        layer.nodes.insert(nodes[i], at: topInsertionIndex)
                        nodes[i].layer = layer
                        topInsertionIndex += 1
                    }
                }

                if constraint == .BOTTOM {
                    bottomConstrainedNodes.append(nodes[i])
                }
            }

            // Append the bottom-constrained nodes
            for node in bottomConstrainedNodes {
                node.setLayer(nil)
                node.setLayer(layer)
            }
        }

        monitor.done()
    }
}
