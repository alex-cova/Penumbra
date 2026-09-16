import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_ReversedEdgeRestorer {
    package init() {}

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("Restoring reversed edges", 1)

        for layer in layeredGraph.layers {
            for node in layer.nodes {
                for port in node.ports {
                    let edgeArray = LGraphUtil.toEdgeArray(port.outgoingEdges)
                    for edge in edgeArray {
                        if edge.getProperty(InternalProperties.REVERSED) as? Bool ?? false {
                            edge.reverse(layeredGraph, false)
                        }
                    }
                }
            }
        }

        monitor.done()
    }
}
