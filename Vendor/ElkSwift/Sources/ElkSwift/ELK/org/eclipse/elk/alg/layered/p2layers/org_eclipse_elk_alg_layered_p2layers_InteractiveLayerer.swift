// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p2layers/InteractiveLayerer.java

import Foundation

package final class org_eclipse_elk_alg_layered_p2layers_InteractiveLayerer {
    package init() {}

    package func getLayoutProcessorConfiguration(
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph
    ) -> LayoutProcessorConfiguration<LayeredPhases, LGraph>? {
        _ = graph
        return LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(
                org_eclipse_elk_alg_layered_LayeredPhases.P1_CYCLE_BREAKING,
                org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy
                    .INTERACTIVE_EXTERNAL_PORT_POSITIONER
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
        _ layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ monitor: any org_eclipse_elk_core_util_IElkProgressMonitor
    ) {
        monitor.begin("Interactive node layering", 1)

        // Create layers with a start and an end position, merging when they overlap with others.
        var currentSpans: [LayerSpan] = []
        for node in layeredGraph.getLayerlessNodes() {
            let minx = node.getPosition().x
            var maxx = minx + node.getSize().x
            // Guarantee every node has a width (external dummies may have zero width).
            maxx = max(minx + 1.0, maxx)
            insert(node, minx: minx, maxx: maxx, into: &currentSpans)
        }

        // Create real layers from the layer spans.
        var nextIndex = 0
        for span in currentSpans {
            let layer = layeredGraph.addLayer()
            layer.id = nextIndex
            nextIndex += 1

            for node in span.nodes {
                node.setLayer(layer)
                node.id = 0
            }
        }

        // Correct layering with respect to topology so edges point from left to right.
        for node in layeredGraph.getLayerlessNodes() where node.id == 0 {
            var shiftedNodes = checkNode(node, layeredGraph)
            while let nodeToCheck = shiftedNodes.popFirst() {
                let newlyShifted = checkNode(nodeToCheck, layeredGraph)
                shiftedNodes.insert(contentsOf: newlyShifted)
            }
        }

        // Remove empty layers, which can happen after correction.
        for layer in layeredGraph.getLayers() where layer.getNodes().isEmpty {
            layeredGraph.removeLayer(layer)
        }

        // Clear nodes that have no layer, since now they all have one.
        for node in layeredGraph.getLayerlessNodes() {
            layeredGraph.removeLayerlessNode(node)
        }

        monitor.done()
    }

    /// Java: InteractiveLayerer#checkNode(LNode, LGraph)
    package func checkNode(
        _ node1: org_eclipse_elk_alg_layered_graph_LNode,
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph
    ) -> OrderedIdentitySet {
        node1.id = 1
        guard let layer1 = node1.getLayer() else {
            return OrderedIdentitySet()
        }

        var shiftNodes = OrderedIdentitySet()
        for port in node1.getPorts(.OUTPUT) {
            for edge in port.getOutgoingEdges() {
                guard let node2 = edge.getTarget()?.getNode(), node1 !== node2 else {
                    continue
                }
                guard let layer2 = node2.getLayer() else {
                    continue
                }

                if layer2.id <= layer1.id {
                    // A violation was detected - move target node to the next layer.
                    let newIndex = layer1.id + 1
                    if newIndex == graph.getLayers().count {
                        let newLayer = graph.addLayer()
                        newLayer.id = newIndex
                        node2.setLayer(newLayer)
                    } else {
                        let newLayer = graph.getLayers()[newIndex]
                        node2.setLayer(newLayer)
                    }
                    shiftNodes.insert(node2)
                }
            }
        }
        return shiftNodes
    }

    package func insert(
        _ node: org_eclipse_elk_alg_layered_graph_LNode,
        minx: Double,
        maxx: Double,
        into spans: inout [LayerSpan]
    ) {
        var foundIndex: Int?
        var insertIndex = spans.count
        var index = 0

        while index < spans.count {
            let span = spans[index]
            if span.start >= maxx {
                insertIndex = index
                break
            } else if span.end > minx {
                if let existing = foundIndex {
                    spans[existing].nodes.append(contentsOf: span.nodes)
                    spans[existing].end = max(spans[existing].end, span.end)
                    spans.remove(at: index)
                    if insertIndex > index {
                        insertIndex -= 1
                    }
                    continue
                } else {
                    spans[index].nodes.append(node)
                    spans[index].start = min(spans[index].start, minx)
                    spans[index].end = max(spans[index].end, maxx)
                    foundIndex = index
                }
            }
            index += 1
        }

        if foundIndex == nil {
            var span = LayerSpan(start: minx, end: maxx, nodes: [])
            span.nodes.append(node)
            spans.insert(span, at: insertIndex)
        }
    }

}

package struct LayerSpan {
    package var start: Double
    package var end: Double
    package var nodes: [org_eclipse_elk_alg_layered_graph_LNode]
}

package struct OrderedIdentitySet {
    package var keys: Set<ObjectIdentifier> = []
    package var ordered: [org_eclipse_elk_alg_layered_graph_LNode] = []

    package var isEmpty: Bool {
        ordered.isEmpty
    }

    package mutating func insert(_ node: org_eclipse_elk_alg_layered_graph_LNode) {
        let key = ObjectIdentifier(node)
        if keys.insert(key).inserted {
            ordered.append(node)
        }
    }

    package mutating func insert(contentsOf other: OrderedIdentitySet) {
        for node in other.ordered {
            insert(node)
        }
    }

    package mutating func popFirst() -> org_eclipse_elk_alg_layered_graph_LNode? {
        guard !ordered.isEmpty else {
            return nil
        }
        let first = ordered.removeFirst()
        keys.remove(ObjectIdentifier(first))
        return first
    }
}
