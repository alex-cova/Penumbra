// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/NoCrossingMinimizer.java

import Foundation

package class org_eclipse_elk_alg_layered_p3order_NoCrossingMinimizer {
    // Java: private static final LayoutProcessorConfiguration<LayeredPhases, LGraph> INTERMEDIATE_PROCESSING_CONFIGURATION
    package static let INTERMEDIATE_PROCESSING_CONFIGURATION: LayoutProcessorConfiguration<LayeredPhases, LGraph> =
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(
                org_eclipse_elk_alg_layered_LayeredPhases.P3_NODE_ORDERING,
                org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy.LONG_EDGE_SPLITTER
            )
            .addBefore(
                org_eclipse_elk_alg_layered_LayeredPhases.P4_NODE_PLACEMENT,
                org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy.IN_LAYER_CONSTRAINT_PROCESSOR
            )
            .addAfter(
                org_eclipse_elk_alg_layered_LayeredPhases.P5_EDGE_ROUTING,
                org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy.LONG_EDGE_JOINER
            )

    package init() {}

    package func process(
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ progressMonitor: any org_eclipse_elk_core_util_IElkProgressMonitor
    ) {
        progressMonitor.begin("No crossing minimization", 1)
        progressMonitor.done()
    }

    package func getLayoutProcessorConfiguration(
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph
    ) -> LayoutProcessorConfiguration<LayeredPhases, LGraph>? {
        let configuration = LayoutProcessorConfiguration<LayeredPhases, LGraph>.create(
            from: Self.INTERMEDIATE_PROCESSING_CONFIGURATION
        )

        configuration.addBefore(
            org_eclipse_elk_alg_layered_LayeredPhases.P3_NODE_ORDERING,
            org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy.PORT_LIST_SORTER
        )
        return configuration
    }
}
