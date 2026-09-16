// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p4nodes/SimpleNodePlacer.java
import Foundation

package final class org_eclipse_elk_alg_layered_p4nodes_SimpleNodePlacer {
    /// Additional processor dependencies for graphs with hierarchical ports.
    package static let HIERARCHY_PROCESSING_ADDITIONS: LayoutProcessorConfiguration<LayeredPhases, LGraph> = {
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(
                org_eclipse_elk_alg_layered_LayeredPhases.P5_EDGE_ROUTING,
                org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy.HIERARCHICAL_PORT_POSITION_PROCESSOR
            )
    }()

    package init() {}

    package func getLayoutProcessorConfiguration(
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph
    ) -> LayoutProcessorConfiguration<LayeredPhases, LGraph>? {
        let graphProperties = graph.getProperty(org_eclipse_elk_alg_layered_options_InternalProperties.GRAPH_PROPERTIES)
            as? Set<org_eclipse_elk_alg_layered_options_GraphProperties> ?? []
        if graphProperties.contains(.EXTERNAL_PORTS) {
            return Self.HIERARCHY_PROCESSING_ADDITIONS
        }
        return nil
    }

    package func process(
        _ layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ monitor: any org_eclipse_elk_core_util_IElkProgressMonitor
    ) {
        monitor.begin("Simple node placement", 1)

        let spacings = layeredGraph.getProperty(org_eclipse_elk_alg_layered_options_InternalProperties.SPACINGS)
            as? org_eclipse_elk_alg_layered_options_Spacings ?? org_eclipse_elk_alg_layered_options_Spacings()

        // First iteration: determine the height of each layer.
        var maxHeight: Double = 0.0
        for layer in layeredGraph.getLayers() {
            let layerSize = layer.getSize()
            layerSize.y = 0.0

            var lastNode: org_eclipse_elk_alg_layered_graph_LNode?
            for node in layer.getNodes() {
                if let lastNode {
                    layerSize.y += spacings.getVerticalSpacing(node, lastNode)
                }
                layerSize.y += node.getMargin().top + node.getSize().y + node.getMargin().bottom
                lastNode = node
            }

            maxHeight = Swift.max(maxHeight, layerSize.y)
        }

        // Second iteration: center nodes of each layer around the tallest layer.
        for layer in layeredGraph.getLayers() {
            let layerSize = layer.getSize()
            var pos = (maxHeight - layerSize.y) / 2.0

            var lastNode: org_eclipse_elk_alg_layered_graph_LNode?
            for node in layer.getNodes() {
                if let lastNode {
                    pos += spacings.getVerticalSpacing(node, lastNode)
                }
                pos += node.getMargin().top
                node.getPosition().y = pos
                pos += node.getSize().y + node.getMargin().bottom
                lastNode = node
            }
        }

        monitor.done()
    }
}
