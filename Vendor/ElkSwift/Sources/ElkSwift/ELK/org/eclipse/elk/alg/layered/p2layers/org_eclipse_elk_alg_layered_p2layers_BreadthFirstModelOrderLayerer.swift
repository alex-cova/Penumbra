// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p2layers/BreadthFirstModelOrderLayerer.java

import Foundation

package final class org_eclipse_elk_alg_layered_p2layers_BreadthFirstModelOrderLayerer {
    package var layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph?

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
        monitor.begin("Breadth first model order layering", 1)

        layeredGraph = thelayeredGraph

        let layerlessNodes = thelayeredGraph.getLayerlessNodes()
        var realNodes = layerlessNodes.filter { $0.getType() == .NORMAL }

        realNodes.sort {
            let leftModelOrder = org_eclipse_elk_alg_layered_p1cycles_ModelOrderPropertyScaffolding
                .modelOrder(for: $0) ?? $0.id
            let rightModelOrder = org_eclipse_elk_alg_layered_p1cycles_ModelOrderPropertyScaffolding
                .modelOrder(for: $1) ?? $1.id
            if leftModelOrder == rightModelOrder {
                return $0.id < $1.id
            }
            return leftModelOrder < rightModelOrder
        }

        var firstNode = true
        var currentLayer = thelayeredGraph.addLayer()
        var currentDummyLayer: org_eclipse_elk_alg_layered_graph_Layer?

        for node in realNodes {
            if firstNode {
                node.setLayer(currentLayer)
                firstNode = false
            } else {
                for edge in node.getIncomingEdges() {
                    guard let sourceNode = edge.getSource()?.getNode() else {
                        continue
                    }

                    var isConnectedToCurrentLayer = false
                    if sourceNode.getType() == .NORMAL {
                        isConnectedToCurrentLayer = sourceNode.getLayer() === currentLayer
                    } else if sourceNode.getType() == .LABEL {
                        if let firstIncomingEdge = sourceNode.getIncomingEdges().first,
                           let labelSourceNode = firstIncomingEdge.getSource()?.getNode() {
                            isConnectedToCurrentLayer = labelSourceNode.getLayer() === currentLayer
                        }
                    }

                    if isConnectedToCurrentLayer {
                        currentDummyLayer = thelayeredGraph.addLayer()
                        currentLayer = thelayeredGraph.addLayer()
                    }
                }

                for edge in node.getIncomingEdges() {
                    guard let sourceNode = edge.getSource()?.getNode() else {
                        continue
                    }
                    if sourceNode.getType() == .LABEL && sourceNode.getLayer() == nil {
                        sourceNode.setLayer(currentDummyLayer)
                    }
                }

                node.setLayer(currentLayer)
            }
        }

        for node in layerlessNodes {
            thelayeredGraph.removeLayerlessNode(node)
        }

        let layersSnapshot = thelayeredGraph.getLayers()
        let emptyLayers = layersSnapshot.filter { $0.getNodes().isEmpty }
        for layer in emptyLayers {
            thelayeredGraph.removeLayer(layer)
        }

        for (layerId, layer) in thelayeredGraph.getLayers().enumerated() {
            layer.id = layerId
        }

        layeredGraph = nil
        monitor.done()
    }
}
