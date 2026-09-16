// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p1cycles/ModelOrderCycleBreaker.java

import Foundation

package final class org_eclipse_elk_alg_layered_p1cycles_ModelOrderCycleBreaker {
    package static let INTERMEDIATE_PROCESSING_CONFIGURATION =
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addAfter(
                org_eclipse_elk_alg_layered_LayeredPhases.P5_EDGE_ROUTING,
                org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy.REVERSED_EDGE_RESTORER
            )

    package init() {}

    package func getLayoutProcessorConfiguration(
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph
    ) -> LayoutProcessorConfiguration<LayeredPhases, LGraph>? {
        _ = graph
        return Self.INTERMEDIATE_PROCESSING_CONFIGURATION
    }

    package func process(
        _ layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ monitor: any org_eclipse_elk_core_util_IElkProgressMonitor
    ) {
        _ = monitor

        var revEdges: [org_eclipse_elk_alg_layered_graph_LEdge] = []

        let layerlessNodes = layeredGraph.getLayerlessNodes()
        let maxModelOrderNodes =
            org_eclipse_elk_alg_layered_p1cycles_ModelOrderPropertyScaffolding
                .maxModelOrderNodes(for: layeredGraph) ?? 1
        let cbNumModelOrderGroups =
            org_eclipse_elk_alg_layered_p1cycles_ModelOrderPropertyScaffolding
                .cbNumModelOrderGroups(for: layeredGraph) ?? 1
        let offset = max(layerlessNodes.count, maxModelOrderNodes)
        let bigOffset = offset * max(cbNumModelOrderGroups, 1)
        let enforceGroupModelOrder = shouldEnforceGroupModelOrder(layeredGraph)

        let calculator = org_eclipse_elk_alg_layered_p1cycles_GroupModelOrderCalculator()
        for source in layerlessNodes {
            let modelOrderSource = enforceGroupModelOrder
                ? calculator.computeConstraintGroupModelOrder(source, bigOffset, offset)
                : calculator.computeConstraintModelOrder(source, offset)

            for port in source.getPorts(.OUTPUT) {
                for edge in port.getOutgoingEdges() {
                    guard let target = edge.getTarget()?.getNode() else {
                        continue
                    }
                    let modelOrderTarget = enforceGroupModelOrder
                        ? calculator.computeConstraintGroupModelOrder(target, bigOffset, offset)
                        : calculator.computeConstraintModelOrder(target, offset)
                    if modelOrderTarget < modelOrderSource {
                        revEdges.append(edge)
                    }
                }
            }
        }

        for edge in revEdges {
            reverseEdge(edge, in: layeredGraph)
            layeredGraph.setProperty(org_eclipse_elk_alg_layered_options_InternalProperties.CYCLIC, true)
        }
        revEdges.removeAll(keepingCapacity: false)
    }

    package func shouldEnforceGroupModelOrder(
        _ layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph
    ) -> Bool {
        org_eclipse_elk_alg_layered_p1cycles_ModelOrderPropertyScaffolding
            .groupOrderStrategy(for: layeredGraph) == .ENFORCED
    }

    package func reverseEdge(
        _ edge: org_eclipse_elk_alg_layered_graph_LEdge,
        in layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph
    ) {
        edge.reverse(layeredGraph, true)
    }
}
