import Foundation

/// Edge router module that draws edges with non-orthogonal line segments.
/// Sets horizontal coordinates for nodes and routes edges with bend points.
package final class org_eclipse_elk_alg_layered_p5edges_PolylineEdgeRouter {

    /// Predicate: is the node an external port dummy on west or east side?
    private static func isExternalWestOrEastPort(_ node: LNode) -> Bool {
        let extPortSide: PortSide? = node.getProperty(InternalProperties.EXT_PORT_SIDE)
        return node.type == .externalPort
            && (extPortSide == .WEST || extPortSide == .EAST)
    }

    // MARK: - Processor configurations

    private static let BASELINE_PROCESSOR_CONFIGURATION: LayoutProcessorConfiguration<LayeredPhases, LGraph> =
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(LayeredPhases.P3_NODE_ORDERING, IntermediateProcessorStrategy.INVERTED_PORT_PROCESSOR)

    private static let NORTH_SOUTH_PORT_PROCESSING_ADDITIONS: LayoutProcessorConfiguration<LayeredPhases, LGraph> =
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(LayeredPhases.P3_NODE_ORDERING, IntermediateProcessorStrategy.NORTH_SOUTH_PORT_PREPROCESSOR)
            .addAfter(LayeredPhases.P5_EDGE_ROUTING, IntermediateProcessorStrategy.NORTH_SOUTH_PORT_POSTPROCESSOR)

    private static let SELF_LOOP_PROCESSING_ADDITIONS: LayoutProcessorConfiguration<LayeredPhases, LGraph> =
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(LayeredPhases.P1_CYCLE_BREAKING, IntermediateProcessorStrategy.SELF_LOOP_PREPROCESSOR)
            .addAfter(LayeredPhases.P5_EDGE_ROUTING, IntermediateProcessorStrategy.SELF_LOOP_POSTPROCESSOR)
            .addBefore(LayeredPhases.P4_NODE_PLACEMENT, IntermediateProcessorStrategy.SELF_LOOP_PORT_RESTORER)
            .addBefore(LayeredPhases.P4_NODE_PLACEMENT, IntermediateProcessorStrategy.SELF_LOOP_ROUTER)

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

    // MARK: - Constants

    private static let MIN_VERT_DIFF: Double = 1.0
    private static let LAYER_SPACE_FAC: Double = 0.4

    private var createdJunctionPoints: Set<KVector> = []

    package init() {}

    // MARK: - ILayoutPhase

    package func getLayoutProcessorConfiguration(
        _ graph: LGraph
    ) -> LayoutProcessorConfiguration<LayeredPhases, LGraph>? {
        let graphProperties = graph.getProperty(InternalProperties.GRAPH_PROPERTIES)
            as? Set<GraphProperties> ?? []

        let configuration = LayoutProcessorConfiguration<LayeredPhases, LGraph>.create(
            from: Self.BASELINE_PROCESSOR_CONFIGURATION)

        if graphProperties.contains(.NORTH_SOUTH_PORTS) {
            let _ = configuration.addAll(Self.NORTH_SOUTH_PORT_PROCESSING_ADDITIONS)
        }
        if graphProperties.contains(.SELF_LOOPS) {
            let _ = configuration.addAll(Self.SELF_LOOP_PROCESSING_ADDITIONS)
        }
        if graphProperties.contains(.CENTER_LABELS) {
            let _ = configuration.addAll(Self.CENTER_EDGE_LABEL_PROCESSING_ADDITIONS)
        }
        if graphProperties.contains(.END_LABELS) {
            let _ = configuration.addAll(Self.END_EDGE_LABEL_PROCESSING_ADDITIONS)
        }

        return configuration
    }

    package func process(
        _ layeredGraph: LGraph,
        _ monitor: IElkProgressMonitor
    ) {
        monitor.begin("Polyline edge routing", 1)

        let slopedEdgeZoneWidth: Double =
            layeredGraph.getProperty(LayeredOptions.EDGE_ROUTING_POLYLINE_SLOPED_EDGE_ZONE_WIDTH) ?? 2.0
        let nodeSpacing: Double =
            layeredGraph.getProperty(LayeredOptions.SPACING_NODE_NODE_BETWEEN_LAYERS) ?? 20.0
        let edgeSpacing: Double =
            layeredGraph.getProperty(LayeredOptions.SPACING_EDGE_EDGE_BETWEEN_LAYERS) ?? 10.0
        let edgeSpaceFac = min(1.0, edgeSpacing / max(nodeSpacing, 1.0))

        var xpos: Double = 0.0

        let layers = layeredGraph.getLayers()

        // Determine horizontal spacing for west-side in-layer edges of first layer
        if !layers.isEmpty {
            let yDiff = calculateWestInLayerEdgeYDiff(layers[0])
            xpos = Self.LAYER_SPACE_FAC * edgeSpaceFac * yDiff
        }

        // Iterate over layers
        for layerIndex in 0..<layers.count {
            let layer = layers[layerIndex]
            let externalLayer = layer.getNodes().allSatisfy { Self.isExternalWestOrEastPort($0) }

            // Don't give node spacing to rightmost external port layer
            if externalLayer && xpos > 0 {
                xpos -= nodeSpacing
            }

            // Set horizontal coordinates for all nodes of the layer
            LGraphUtil.placeNodesHorizontally(layer, xoffset: xpos)

            // Track max vertical span of edges between this and next layer
            var maxVertDiff: Double = 0.0

            for node in layer.getNodes() {
                var maxCurrOutputYDiff: Double = 0.0
                for outgoingEdge in node.getOutgoingEdges() {
                    guard let sourcePort = outgoingEdge.getSource(),
                          let targetPort = outgoingEdge.getTarget() else { continue }

                    let sourcePos = sourcePort.getAbsoluteAnchor().y
                    let targetPos = targetPort.getAbsoluteAnchor().y

                    if layer === targetPort.getNode()?.getLayer() && !outgoingEdge.isSelfLoop() {
                        // In-layer edge: add extra bend point
                        processInLayerEdge(outgoingEdge, xpos,
                            Self.LAYER_SPACE_FAC * edgeSpaceFac * Swift.abs(sourcePos - targetPos))

                        if sourcePort.getSide() == .WEST {
                            // West in-layer edges don't contribute to between-layer spacing
                            continue
                        }
                    }

                    maxCurrOutputYDiff = Swift.max(maxCurrOutputYDiff, Swift.abs(targetPos - sourcePos))
                }

                // Process bend points for certain node types
                switch node.type {
                case .normal, .label, .longEdge, .northSouthPort, .breakingPoint:
                    processNode(node, xpos, slopedEdgeZoneWidth)
                default:
                    break
                }

                maxVertDiff = Swift.max(maxVertDiff, maxCurrOutputYDiff)
            }

            // Consider west-side in-layer edges of next layer
            if layerIndex + 1 < layers.count {
                let yDiff = calculateWestInLayerEdgeYDiff(layers[layerIndex + 1])
                maxVertDiff = Swift.max(maxVertDiff, yDiff)
            }

            // Determine where next layer should start
            var layerSpacing = Self.LAYER_SPACE_FAC * edgeSpaceFac * maxVertDiff
            if !externalLayer && layerIndex + 1 < layers.count {
                layerSpacing += nodeSpacing
            }

            xpos += layer.getSize().x + layerSpacing
        }

        createdJunctionPoints.removeAll()

        // Set the graph's horizontal size
        layeredGraph.getSize().x = xpos

        monitor.done()
    }

    // MARK: - Edge Routing

    private func processNode(_ node: LNode, _ layerLeftXPos: Double, _ maxAcceptableXDiff: Double) {
        let layerRightXPos = layerLeftXPos + (node.getLayer()?.getSize().x ?? 0)

        for port in node.getPorts() {
            let absolutePortAnchor = port.getAbsoluteAnchor()

            if node.type == .northSouthPort {
                if let correspondingPort = port.getProperty(InternalProperties.ORIGIN) as? LPort {
                    absolutePortAnchor.x = correspondingPort.getAbsoluteAnchor().x
                    node.getPosition().x = absolutePortAnchor.x
                }
            }

            let bendPoint = KVector(0, absolutePortAnchor.y)

            if port.getSide() == .EAST {
                bendPoint.x = layerRightXPos
            } else if port.getSide() == .WEST {
                bendPoint.x = layerLeftXPos
            } else {
                continue
            }

            let xDistance = Swift.abs(absolutePortAnchor.x - bendPoint.x)
            if xDistance <= maxAcceptableXDiff && !isInLayerDummy(node) {
                continue
            }

            let addJunctionPoint =
                port.getOutgoingEdges().count + port.getIncomingEdges().count > 1

            for e in port.getConnectedEdges() {
                guard let otherPort = (e.getSource() === port ? e.getTarget() : e.getSource()) else { continue }
                if Swift.abs(otherPort.getAbsoluteAnchor().y - bendPoint.y) > Self.MIN_VERT_DIFF {
                    addBendPoint(e, bendPoint, addJunctionPoint, port)
                }
            }
        }
    }

    private func processInLayerEdge(_ edge: LEdge, _ layerXPos: Double, _ edgeSpacing: Double) {
        guard let sourcePort = edge.getSource(),
              let targetPort = edge.getTarget() else { return }

        let sourceAnchorY = sourcePort.getAbsoluteAnchor().y
        let midY = (sourceAnchorY + targetPort.getAbsoluteAnchor().y) / 2.0

        if sourcePort.getSide() == .EAST {
            let bx = layerXPos + (sourcePort.getNode()?.getLayer()?.getSize().x ?? 0) + edgeSpacing
            let bendPoint = KVector(bx, midY)
            edge.getBendPoints().insert(bendPoint, at: 0)
        } else {
            let bendPoint = KVector(layerXPos - edgeSpacing, midY)
            edge.getBendPoints().insert(bendPoint, at: 0)
        }
    }

    // MARK: - Utility

    private func calculateWestInLayerEdgeYDiff(_ layer: Layer) -> Double {
        var maxYDiff: Double = 0.0

        for node in layer.getNodes() {
            for outgoingEdge in node.getOutgoingEdges() {
                guard let sp = outgoingEdge.getSource(),
                      let tp = outgoingEdge.getTarget() else { continue }

                if layer === tp.getNode()?.getLayer()
                    && sp.getSide() == .WEST {

                    let sourcePos = sp.getAbsoluteAnchor().y
                    let targetPos = tp.getAbsoluteAnchor().y
                    maxYDiff = Swift.max(maxYDiff, Swift.abs(targetPos - sourcePos))
                }
            }
        }

        return maxYDiff
    }

    private func addBendPoint(_ edge: LEdge, _ bendPoint: KVector, _ addJunctionPoint: Bool, _ currPort: LPort) {
        if (edge.isInLayerEdge() || currPort.getAbsoluteAnchor() != bendPoint) && !edge.isSelfLoop() {
            if edge.getSource() === currPort {
                edge.getBendPoints().insert(KVector(bendPoint), at: 0)
            } else {
                edge.getBendPoints().append(KVector(bendPoint))
            }

            if addJunctionPoint && !createdJunctionPoints.contains(bendPoint) {
                var junctionPoints: KVectorChain? = edge.getProperty(LayeredOptions.JUNCTION_POINTS)
                if junctionPoints == nil {
                    junctionPoints = KVectorChain()
                    edge.setProperty(LayeredOptions.JUNCTION_POINTS, junctionPoints)
                }

                let jpoint = KVector(bendPoint)
                junctionPoints?.add(jpoint)
                createdJunctionPoints.insert(jpoint)
            }
        }
    }

    private func isInLayerDummy(_ node: LNode) -> Bool {
        if node.type == .longEdge {
            for e in node.getConnectedEdges() {
                if e.isInLayerEdge() {
                    return true
                }
            }
        }
        return false
    }
}
