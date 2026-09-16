import Foundation

package final class org_eclipse_elk_alg_layered_p5edges_OrthogonalEdgeRouter {

    private static let HYPEREDGE_PROCESSING_ADDITIONS: LayoutProcessorConfiguration<LayeredPhases, LGraph> =
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(LayeredPhases.P4_NODE_PLACEMENT, IntermediateProcessorStrategy.HYPEREDGE_DUMMY_MERGER)

    private static let INVERTED_PORT_PROCESSING_ADDITIONS: LayoutProcessorConfiguration<LayeredPhases, LGraph> =
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(LayeredPhases.P3_NODE_ORDERING, IntermediateProcessorStrategy.INVERTED_PORT_PROCESSOR)

    private static let NORTH_SOUTH_PORT_PROCESSING_ADDITIONS: LayoutProcessorConfiguration<LayeredPhases, LGraph> =
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(LayeredPhases.P3_NODE_ORDERING, IntermediateProcessorStrategy.NORTH_SOUTH_PORT_PREPROCESSOR)
            .addAfter(LayeredPhases.P5_EDGE_ROUTING, IntermediateProcessorStrategy.NORTH_SOUTH_PORT_POSTPROCESSOR)

    private static let HIERARCHICAL_PORT_PROCESSING_ADDITIONS: LayoutProcessorConfiguration<LayeredPhases, LGraph> =
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(LayeredPhases.P3_NODE_ORDERING, IntermediateProcessorStrategy.HIERARCHICAL_PORT_CONSTRAINT_PROCESSOR)
            .addBefore(LayeredPhases.P4_NODE_PLACEMENT, IntermediateProcessorStrategy.HIERARCHICAL_PORT_DUMMY_SIZE_PROCESSOR)
            .addAfter(LayeredPhases.P5_EDGE_ROUTING, IntermediateProcessorStrategy.HIERARCHICAL_PORT_ORTHOGONAL_EDGE_ROUTER)

    private static let SELF_LOOP_PROCESSING_ADDITIONS: LayoutProcessorConfiguration<LayeredPhases, LGraph> =
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(LayeredPhases.P1_CYCLE_BREAKING, IntermediateProcessorStrategy.SELF_LOOP_PREPROCESSOR)
            .addAfter(LayeredPhases.P5_EDGE_ROUTING, IntermediateProcessorStrategy.SELF_LOOP_POSTPROCESSOR)
            .addBefore(LayeredPhases.P4_NODE_PLACEMENT, IntermediateProcessorStrategy.SELF_LOOP_PORT_RESTORER)
            .addBefore(LayeredPhases.P4_NODE_PLACEMENT, IntermediateProcessorStrategy.SELF_LOOP_ROUTER)

    private static let HYPERNODE_PROCESSING_ADDITIONS: LayoutProcessorConfiguration<LayeredPhases, LGraph> =
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addAfter(LayeredPhases.P5_EDGE_ROUTING, IntermediateProcessorStrategy.HYPERNODE_PROCESSOR)

    private static let CENTER_EDGE_LABEL_PROCESSING_ADDITIONS: LayoutProcessorConfiguration<LayeredPhases, LGraph> =
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(LayeredPhases.P2_LAYERING, IntermediateProcessorStrategy.LABEL_DUMMY_INSERTER)
            .addBefore(LayeredPhases.P4_NODE_PLACEMENT, IntermediateProcessorStrategy.LABEL_DUMMY_SWITCHER)
            .addBefore(LayeredPhases.P4_NODE_PLACEMENT, IntermediateProcessorStrategy.LABEL_SIDE_SELECTOR)
            .addAfter(LayeredPhases.P5_EDGE_ROUTING, IntermediateProcessorStrategy.LABEL_DUMMY_REMOVER)

    private static let END_EDGE_LABEL_PROCESSING_ADDITIONS: LayoutProcessorConfiguration<LayeredPhases, LGraph> =
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(LayeredPhases.P4_NODE_PLACEMENT, IntermediateProcessorStrategy.LABEL_SIDE_SELECTOR)
            .addBefore(LayeredPhases.P4_NODE_PLACEMENT, IntermediateProcessorStrategy.END_LABEL_PREPROCESSOR)
            .addAfter(LayeredPhases.P5_EDGE_ROUTING, IntermediateProcessorStrategy.END_LABEL_POSTPROCESSOR)

    package init() {}

    package func getLayoutProcessorConfiguration(_ graph: LGraph) -> LayoutProcessorConfiguration<LayeredPhases, LGraph>? {
        let graphProperties = graph.getProperty(InternalProperties.GRAPH_PROPERTIES) as? Set<GraphProperties> ?? []

        let configuration = LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()

        if graphProperties.contains(.HYPEREDGES) {
            configuration.addAll(Self.HYPEREDGE_PROCESSING_ADDITIONS)
            configuration.addAll(Self.INVERTED_PORT_PROCESSING_ADDITIONS)
        }

        if graphProperties.contains(.NON_FREE_PORTS)
            || (graph.getProperty(LayeredOptions.FEEDBACK_EDGES) as? Bool ?? false) {

            configuration.addAll(Self.INVERTED_PORT_PROCESSING_ADDITIONS)

            if graphProperties.contains(.NORTH_SOUTH_PORTS) {
                configuration.addAll(Self.NORTH_SOUTH_PORT_PROCESSING_ADDITIONS)
            }
        }

        if graphProperties.contains(.EXTERNAL_PORTS) {
            configuration.addAll(Self.HIERARCHICAL_PORT_PROCESSING_ADDITIONS)
        }

        if graphProperties.contains(.SELF_LOOPS) {
            configuration.addAll(Self.SELF_LOOP_PROCESSING_ADDITIONS)
        }

        if graphProperties.contains(.HYPERNODES) {
            configuration.addAll(Self.HYPERNODE_PROCESSING_ADDITIONS)
        }

        if graphProperties.contains(.CENTER_LABELS) {
            configuration.addAll(Self.CENTER_EDGE_LABEL_PROCESSING_ADDITIONS)
        }

        if graphProperties.contains(.END_LABELS) {
            configuration.addAll(Self.END_EDGE_LABEL_PROCESSING_ADDITIONS)
        }

        return configuration
    }

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("Orthogonal edge routing", 1)

        let nodeNodeSpacing = Self.resolveDouble(layeredGraph, LayeredOptions.SPACING_NODE_NODE_BETWEEN_LAYERS)
        let edgeEdgeSpacing = Self.resolveDouble(layeredGraph, LayeredOptions.SPACING_EDGE_EDGE_BETWEEN_LAYERS)
        let edgeNodeSpacing = Self.resolveDouble(layeredGraph, LayeredOptions.SPACING_EDGE_NODE_BETWEEN_LAYERS)

        let routingGenerator = OrthogonalRoutingGenerator(
            RoutingDirection.WEST_TO_EAST, edgeEdgeSpacing, "phase5")

        var xpos: Double = 0.0
        var layerIndex = 0
        var leftLayer: Layer? = nil
        var rightLayer: Layer? = nil
        var leftLayerNodes: [LNode]? = nil
        var rightLayerNodes: [LNode]? = nil
        var leftLayerIndex = -1
        var rightLayerIndex = -1

        repeat {
            // Fetch the next layer, if any
            if layerIndex < layeredGraph.layers.count {
                rightLayer = layeredGraph.layers[layerIndex]
                rightLayerNodes = rightLayer?.nodes
                rightLayerIndex = layerIndex
                layerIndex += 1
            } else {
                rightLayer = nil
                rightLayerNodes = nil
                rightLayerIndex = layerIndex - 1
            }

            // Place the left layer's nodes
            if let left = leftLayer {
                LGraphUtil.placeNodesHorizontally(left, xoffset: xpos)
                xpos += left.size.x
            }

            // Route edges between the two layers
            let startPos: Double = leftLayer == nil ? xpos : xpos + edgeNodeSpacing
            let slotsCount = routingGenerator.routeEdges(
                monitor, layeredGraph, leftLayerNodes, leftLayerIndex, rightLayerNodes, startPos)

            let isLeftLayerExternal = leftLayer == nil || allExternalWestOrEastPort(leftLayerNodes ?? [])
            let isRightLayerExternal = rightLayer == nil || allExternalWestOrEastPort(rightLayerNodes ?? [])

            if slotsCount > 0 {
                var routingWidth = Double(slotsCount - 1) * edgeEdgeSpacing

                if leftLayer != nil {
                    routingWidth += edgeNodeSpacing
                }
                if rightLayer != nil {
                    routingWidth += edgeNodeSpacing
                }

                if routingWidth < nodeNodeSpacing && !isLeftLayerExternal && !isRightLayerExternal {
                    routingWidth = nodeNodeSpacing
                }
                xpos += routingWidth
            } else if !isLeftLayerExternal && !isRightLayerExternal {
                xpos += nodeNodeSpacing
            }

            leftLayer = rightLayer
            leftLayerNodes = rightLayerNodes
            leftLayerIndex = rightLayerIndex
        } while rightLayer != nil

        layeredGraph.getSize().x = xpos

        monitor.done()
    }

    /// Resolve a property value to Double, handling string/int/double values.
    private static func resolveDouble(_ graph: LGraph, _ property: IProperty) -> Double {
        let val = graph.getProperty(property)
        if let d = val as? Double { return d }
        if let i = val as? Int { return Double(i) }
        if let s = val as? String, let d = Double(s) { return d }
        return 0.0
    }

    private func allExternalWestOrEastPort(_ nodes: [LNode]) -> Bool {
        for node in nodes {
            let extPortSide = node.getProperty(InternalProperties.EXT_PORT_SIDE) as? PortSide
            if !(node.type == .externalPort && (extPortSide == .WEST || extPortSide == .EAST)) {
                return false
            }
        }
        return true
    }
}
