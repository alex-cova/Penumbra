// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p2layers/LongestPathLayerer.java

import Foundation

package final class org_eclipse_elk_alg_layered_p2layers_LongestPathLayerer {
    package var layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph?
    package var nodeHeights: [Int] = []

    package init() {}

    package func getLayoutProcessorConfiguration(
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph
    ) -> LayoutProcessorConfiguration<LayeredPhases, LGraph>? {
        _ = graph
        return LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(
                org_eclipse_elk_alg_layered_LayeredPhases.P1_CYCLE_BREAKING,
                org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy
                    .EDGE_AND_LAYER_CONSTRAINT_EDGE_REVERSER
            )
            .addBefore(
                org_eclipse_elk_alg_layered_LayeredPhases.P2_LAYERING,
                org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy
                    .LAYER_CONSTRAINT_PREPROCESSOR
            )
            .addBefore(
                org_eclipse_elk_alg_layered_LayeredPhases.P3_NODE_ORDERING,
                org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy
                    .LAYER_CONSTRAINT_POSTPROCESSOR
            )
    }

    package func process(
        _ thelayeredGraph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ monitor: any org_eclipse_elk_core_util_IElkProgressMonitor
    ) {
        monitor.begin("Longest path layering", 1)

        layeredGraph = thelayeredGraph
        let nodes = thelayeredGraph.getLayerlessNodes()

        nodeHeights = Array(repeating: -1, count: nodes.count)
        for (index, node) in nodes.enumerated() {
            node.id = index
            nodeHeights[index] = -1
        }

        for node in nodes {
            _ = visit(node)
        }

        let maxHeight = nodeHeights.max() ?? 0
        if maxHeight > 0 {
            var layers: [org_eclipse_elk_alg_layered_graph_Layer] = []
            layers.reserveCapacity(maxHeight)
            for _ in 0..<maxHeight {
                let layer = thelayeredGraph.addLayer()
                layers.append(layer)
            }

            for node in nodes {
                let height = nodeHeights[node.id]
                if height > 0 {
                    node.setLayer(layers[maxHeight - height])
                }
            }
        }

        for node in nodes {
            thelayeredGraph.removeLayerlessNode(node)
        }

        layeredGraph = nil
        nodeHeights = []
        monitor.done()
    }

    package func visit(_ node: org_eclipse_elk_alg_layered_graph_LNode) -> Int {
        let cachedHeight = nodeHeights[node.id]
        if cachedHeight >= 0 {
            return cachedHeight
        }

        var maxHeight = 1
        for port in node.getPorts() {
            for edge in port.getOutgoingEdges() {
                guard let targetNode = edge.getTarget()?.getNode() else {
                    continue
                }

                if node !== targetNode {
                    let targetHeight = visit(targetNode)
                    maxHeight = max(maxHeight, targetHeight + 1)
                }
            }
        }

        nodeHeights[node.id] = maxHeight
        return maxHeight
    }
}
