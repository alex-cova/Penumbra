import Foundation

/**
 * This processor does the job of routing edges connected to hierarchical ports.
 *
 * Six steps:
 * 1. Restore N/S port dummies removed by HierarchicalPortConstraintProcessor and connect to proxy dummies.
 * 2. Calculate N/S dummy coordinates.
 * 3. Route edges via OrthogonalRoutingGenerator.
 * 4. Remove temporary proxy dummies, rerouting edges to original dummies with bend points.
 * 5. Fix E/W dummy x coordinates and adjust y if graph height changed.
 * 6. Correct slanted edge segments on E/W dummies.
 *
 * Runs after phase 5.
 */
package final class org_eclipse_elk_alg_layered_intermediate_HierarchicalPortOrthogonalEdgeRouter {

    /** The amount of space necessary to accommodate northern external port edge routing. */
    private var northernExtPortEdgeRoutingHeight: Double = 0.0

    package init() {}

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        monitor.begin("Orthogonally routing hierarchical port edges", 1)
        northernExtPortEdgeRoutingHeight = 0.0

        // Step 1: Restore N/S port dummies
        let northSouthDummies = restoreNorthSouthDummies(layeredGraph)

        // Step 2: Calculate N/S dummy coordinates
        setNorthSouthDummyCoordinates(layeredGraph, northSouthDummies)

        // Step 3: Route edges
        routeEdges(monitor, layeredGraph, northSouthDummies)

        // Step 4: Remove temporary N/S dummies
        removeTemporaryNorthSouthDummies(layeredGraph)

        // Step 5: Fix E/W dummy coordinates
        fixCoordinates(layeredGraph)

        // Step 6: Correct slanted edge segments
        correctSlantedEdgeSegments(layeredGraph)

        monitor.done()
    }

    // MARK: - STEP 1: RESTORE NORTH / SOUTH DUMMIES

    /**
     * Restores hierarchical port dummy nodes and connects them to temporary proxy dummies.
     */
    private func restoreNorthSouthDummies(_ layeredGraph: LGraph) -> [LNode] {
        var restoredDummies: [LNode] = []

        if !layeredGraph.hasProperty(InternalProperties.EXT_PORT_REPLACED_DUMMIES) {
            return restoredDummies
        }

        // Restore the original external port dummies
        if let replacedDummies = layeredGraph.getProperty(InternalProperties.EXT_PORT_REPLACED_DUMMIES) as? [LNode] {
            for dummy in replacedDummies {
                restoreDummy(dummy, layeredGraph)
                restoredDummies.append(dummy)
            }
        }

        // Looking for hierarchical port dummies that replaced the restored ones
        for layer in layeredGraph.getLayers() {
            for node in layer.getNodes() {
                if node.getType() != .externalPort {
                    continue
                }

                if let replacedDummy = node.getProperty(InternalProperties.EXT_PORT_REPLACED_DUMMY) as? LNode {
                    assert(replacedDummy.getType() == .externalPort)
                    connectNodeToDummy(layeredGraph, node, replacedDummy)
                }
            }
        }

        // Assign the restored dummies to the graph's last layer
        let layers = layeredGraph.getLayers()
        if !layers.isEmpty {
            for dummy in restoredDummies {
                dummy.setLayer(layers[layers.count - 1])
            }
        }

        return restoredDummies
    }

    /**
     * Restores the given dummy by setting its port side properly.
     */
    private func restoreDummy(_ dummy: LNode, _ graph: LGraph) {
        let portSide = dummy.getProperty(InternalProperties.EXT_PORT_SIDE) as? PortSide
        let dummyPort = dummy.getPorts()[0]

        if portSide == .NORTH {
            dummyPort.setSide(.SOUTH)
        } else if portSide == .SOUTH {
            dummyPort.setSide(.NORTH)
        }

        // Since the dummy node was hidden from the algorithm, its port labels are not placed properly
        // and its margins are not set accordingly.
        let sizeConstraints = graph.getProperty(LayeredOptions.NODE_SIZE_CONSTRAINTS) as? SizeConstraint ?? []
        if sizeConstraints.contains(.portLabels) {
            let portLabelSpacingHorizontal = dummy.getProperty(LayeredOptions.SPACING_LABEL_PORT_HORIZONTAL) as? Double ?? 0.0
            let portLabelSpacingVertical = dummy.getProperty(LayeredOptions.SPACING_LABEL_PORT_VERTICAL) as? Double ?? 0.0
            let labelLabelSpacing = dummy.getProperty(LayeredOptions.SPACING_LABEL_LABEL) as? Double ?? 0.0

            let portLabelPlacement = graph.getProperty(LayeredOptions.PORT_LABELS_PLACEMENT) as? PortLabelPlacement ?? []
            if portLabelPlacement.contains(.inside) {
                var currentY = portLabelSpacingVertical
                let xCenterRelativeToPort = dummy.getSize().x / 2 - dummyPort.getPosition().x

                for label in dummyPort.getLabels() {
                    label.getPosition().y = currentY
                    label.getPosition().x = xCenterRelativeToPort - label.getSize().x / 2

                    currentY += label.getSize().y + labelLabelSpacing
                }

            } else if portLabelPlacement.contains(.outside) {
                for label in dummyPort.getLabels() {
                    label.getPosition().x = portLabelSpacingHorizontal + dummy.getSize().x - dummyPort.getPosition().x
                }
            }

            // Calculate margins
            NodeDimensionCalculation.getNodeMarginCalculator(LGraphAdapters.adapt(graph, transparentNorthSouthEdges: false))
                .process(node: LGraphAdapters.adapt(dummy, transparentNorthSouthEdges: false))
        }
    }

    /**
     * Adds a port to the given node and connects that to the given dummy node.
     */
    private func connectNodeToDummy(_ layeredGraph: LGraph, _ node: LNode, _ dummy: LNode) {
        let outPort = LPort()
        outPort.setNode(node)

        let extPortSide = node.getProperty(InternalProperties.EXT_PORT_SIDE) as? PortSide ?? .UNDEFINED
        outPort.setSide(extPortSide)

        // Find the dummy node's port
        let inPort = dummy.getPorts()[0]

        // Connect the two nodes
        let edge = LEdge()
        edge.setSource(outPort)
        edge.setTarget(inPort)
    }

    // MARK: - STEP 2: SET NORTH / SOUTH DUMMY COORDINATES

    /**
     * Set coordinates for northern and southern external port dummy nodes.
     */
    private func setNorthSouthDummyCoordinates(_ layeredGraph: LGraph, _ northSouthDummies: [LNode]) {
        let constraints = layeredGraph.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .FREE
        let graphSize = layeredGraph.getSize()
        let graphPadding = layeredGraph.getPadding()
        let graphWidth = graphSize.x + graphPadding.left + graphPadding.right
        let northY = 0 - graphPadding.top - layeredGraph.getOffset().y
        let southY = graphSize.y + graphPadding.top + graphPadding.bottom - layeredGraph.getOffset().y

        var northernDummies: [LNode] = []
        var southernDummies: [LNode] = []

        for dummy in northSouthDummies {
            // Set x coordinate
            switch constraints {
            case .FREE, .FIXED_SIDE, .FIXED_ORDER:
                calculateNorthSouthDummyPositions(dummy)
            case .FIXED_RATIO:
                applyNorthSouthDummyRatio(dummy, graphWidth)
                dummy.borderToContentAreaCoordinates(true, false)
            case .FIXED_POS:
                applyNorthSouthDummyPosition(dummy)
                dummy.borderToContentAreaCoordinates(true, false)
                // Ensure that the graph is wide enough to hold the port
                graphSize.x = max(graphSize.x, dummy.getPosition().x + dummy.getSize().x / 2.0)
            default:
                break
            }

            // Set y coordinates and add the dummy to its respective list
            let extPortSide = dummy.getProperty(InternalProperties.EXT_PORT_SIDE) as? PortSide
            switch extPortSide {
            case .NORTH:
                dummy.getPosition().y = northY
                northernDummies.append(dummy)
            case .SOUTH:
                dummy.getPosition().y = southY
                southernDummies.append(dummy)
            default:
                break
            }
        }

        // Check for correct ordering and unique positions
        switch constraints {
        case .FREE, .FIXED_SIDE:
            ensureUniquePositions(northernDummies, layeredGraph)
            ensureUniquePositions(southernDummies, layeredGraph)
        case .FIXED_ORDER:
            restoreProperOrder(northernDummies, layeredGraph)
            restoreProperOrder(southernDummies, layeredGraph)
        default:
            break
        }
    }

    /**
     * Calculates the positions of N/S dummies based on connected port positions.
     */
    private func calculateNorthSouthDummyPositions(_ dummy: LNode) {
        let dummyInPort = dummy.getPorts()[0]

        if dummyInPort.getDegree() == 0 {
            dummy.getPosition().x = 0
        } else {
            var posSum = 0.0

            for connectedPort in dummyInPort.getConnectedPorts() {
                posSum += (connectedPort.getNode()?.getPosition().x ?? 0) + connectedPort.getPosition().x
                    + connectedPort.getAnchor().x
            }

            let anchor = dummy.getProperty(LayeredOptions.PORT_ANCHOR) as? KVector
            let offset = anchor?.x ?? 0
            dummy.getPosition().x = posSum / Double(dummyInPort.getDegree()) - offset
        }
    }

    /**
     * Sets the dummy's x coordinate to respect the ratio defined for its original port.
     */
    private func applyNorthSouthDummyRatio(_ dummy: LNode, _ width: Double) {
        let anchor = dummy.getProperty(LayeredOptions.PORT_ANCHOR) as? KVector
        let offset = anchor?.x ?? 0
        let ratio = dummy.getProperty(InternalProperties.PORT_RATIO_OR_POSITION) as? Double ?? 0.0
        dummy.getPosition().x = width * ratio - offset
    }

    /**
     * Sets the dummy's x coordinate to its original port's x coordinate.
     */
    private func applyNorthSouthDummyPosition(_ dummy: LNode) {
        let anchor = dummy.getProperty(LayeredOptions.PORT_ANCHOR) as? KVector
        let offset = anchor?.x ?? 0
        let pos = dummy.getProperty(InternalProperties.PORT_RATIO_OR_POSITION) as? Double ?? 0.0
        dummy.getPosition().x = pos - offset
    }

    /**
     * Ensures that no two dummy nodes have the same x coordinate.
     * May not preserve original order (for FREE/FIXED_SIDE constraints).
     */
    private func ensureUniquePositions(_ dummies: [LNode], _ graph: LGraph) {
        if dummies.isEmpty { return }

        var dummyArray = LGraphUtil.toNodeArray(dummies)
        dummyArray.sort { $0.getPosition().x < $1.getPosition().x }

        assignAscendingCoordinates(dummyArray, graph)
    }

    /**
     * Checks if auto-calculated coordinates violate fixed order and fixes them.
     */
    private func restoreProperOrder(_ dummies: [LNode], _ graph: LGraph) {
        if dummies.isEmpty { return }

        var dummyArray = LGraphUtil.toNodeArray(dummies)
        dummyArray.sort {
            let a = $0.getProperty(InternalProperties.PORT_RATIO_OR_POSITION) as? Double ?? 0.0
            let b = $1.getProperty(InternalProperties.PORT_RATIO_OR_POSITION) as? Double ?? 0.0
            return a < b
        }

        assignAscendingCoordinates(dummyArray, graph)
    }

    /**
     * Iterates over the array, ensuring x coordinates are strictly ascending.
     */
    private func assignAscendingCoordinates(_ dummies: [LNode], _ graph: LGraph) {
        let spacing = graph.getProperty(LayeredOptions.SPACING_PORT_PORT) as? Double ?? 0.0

        var nextValidCoordinate = dummies[0].getPosition().x
            + dummies[0].getSize().x
            + dummies[0].getMargin().right
            + spacing

        for index in 1..<dummies.count {
            let currentPosition = dummies[index].getPosition()
            let currentSize = dummies[index].getSize()
            let currentMargin = dummies[index].getMargin()

            // Ensure spacings are adhered to
            let delta = currentPosition.x - currentMargin.left - nextValidCoordinate
            if delta < 0 {
                currentPosition.x -= delta
            }

            // Ensure the graph is large enough for this node
            let graphSize = graph.getSize()
            graphSize.x = max(graphSize.x, currentPosition.x + currentSize.x)

            // Compute next valid coordinate
            nextValidCoordinate = currentPosition.x + currentSize.x + currentMargin.right + spacing
        }
    }

    // MARK: - STEP 3: EDGE ROUTING

    /**
     * Routes northern and southern hierarchical port edges and adjusts the graph's height and
     * offsets accordingly.
     */
    private func routeEdges(_ monitor: IElkProgressMonitor, _ layeredGraph: LGraph,
                            _ northSouthDummies: [LNode]) {

        var northernSourceLayer: [LNode] = []
        var northernTargetLayer: [LNode] = []
        var southernSourceLayer: [LNode] = []
        var southernTargetLayer: [LNode] = []

        let nodeSpacing = layeredGraph.getProperty(LayeredOptions.SPACING_NODE_NODE) as? Double ?? 0.0
        let edgeSpacing = layeredGraph.getProperty(LayeredOptions.SPACING_EDGE_EDGE) as? Double ?? 0.0

        // Assemble the N/S hierarchical port dummies and their connected nodes
        for hierarchicalPortDummy in northSouthDummies {
            let portSide = hierarchicalPortDummy.getProperty(InternalProperties.EXT_PORT_SIDE) as? PortSide

            if portSide == .NORTH {
                northernTargetLayer.append(hierarchicalPortDummy)
                for edge in hierarchicalPortDummy.getIncomingEdges() {
                    if let sourceNode = edge.getSource()?.getNode() {
                        if !northernSourceLayer.contains(where: { $0 === sourceNode }) {
                            northernSourceLayer.append(sourceNode)
                        }
                    }
                }
            } else if portSide == .SOUTH {
                southernTargetLayer.append(hierarchicalPortDummy)
                for edge in hierarchicalPortDummy.getIncomingEdges() {
                    if let sourceNode = edge.getSource()?.getNode() {
                        if !southernSourceLayer.contains(where: { $0 === sourceNode }) {
                            southernSourceLayer.append(sourceNode)
                        }
                    }
                }
            }
        }

        // Northern routing
        if !northernSourceLayer.isEmpty {
            let routingGenerator = OrthogonalRoutingGenerator(
                RoutingDirection.SOUTH_TO_NORTH, edgeSpacing, "extnorth")

            let slots = routingGenerator.routeEdges(
                monitor,
                layeredGraph,
                northernSourceLayer,
                0,
                northernTargetLayer,
                -nodeSpacing - layeredGraph.getOffset().y)

            if slots > 0 {
                northernExtPortEdgeRoutingHeight = nodeSpacing + Double(slots - 1) * edgeSpacing
                layeredGraph.getOffset().y += northernExtPortEdgeRoutingHeight
                layeredGraph.getSize().y += northernExtPortEdgeRoutingHeight
            }
        }

        // Southern routing
        if !southernSourceLayer.isEmpty {
            let routingGenerator = OrthogonalRoutingGenerator(
                RoutingDirection.NORTH_TO_SOUTH, edgeSpacing, "extsouth")

            let slots = routingGenerator.routeEdges(
                monitor,
                layeredGraph,
                southernSourceLayer,
                0,
                southernTargetLayer,
                layeredGraph.getSize().y + nodeSpacing - layeredGraph.getOffset().y)

            if slots > 0 {
                layeredGraph.getSize().y += nodeSpacing + Double(slots - 1) * edgeSpacing
            }
        }
    }

    // MARK: - STEP 4: REMOVE TEMPORARY DUMMIES

    /**
     * Removes temporary hierarchical port dummies, reconnecting edges to the original dummies
     * with appropriate bend points.
     */
    private func removeTemporaryNorthSouthDummies(_ layeredGraph: LGraph) {
        var nodesToRemove: [LNode] = []

        for layer in layeredGraph.getLayers() {
            for node in layer.getNodes() {
                if node.getType() != .externalPort {
                    continue
                }

                if !node.hasProperty(InternalProperties.EXT_PORT_REPLACED_DUMMY) {
                    continue
                }

                // Find the three ports: in (WEST), out (EAST), and origin (N or S)
                var nodeInPort: LPort? = nil
                var nodeOutPort: LPort? = nil
                var nodeOriginPort: LPort? = nil

                for port in node.getPorts() {
                    switch port.getSide() {
                    case .WEST:
                        nodeInPort = port
                    case .EAST:
                        nodeOutPort = port
                    default:
                        nodeOriginPort = port
                    }
                }

                guard let originPort = nodeOriginPort,
                      !originPort.getOutgoingEdges().isEmpty else {
                    continue
                }

                // Find the edge connecting this dummy to the original external port dummy
                let nodeToOriginEdge = originPort.getOutgoingEdges()[0]

                // Compute bend points for incoming edges
                let incomingEdgeBendPoints = KVectorChain(nodeToOriginEdge.getBendPoints().toArray())

                let firstBendPoint = KVector(originPort.getPosition())
                firstBendPoint.add(node.getPosition())
                incomingEdgeBendPoints.insert(firstBendPoint, at: 0)

                // Compute bend points for outgoing edges
                let outgoingEdgeBendPoints = KVectorChain.reverse(nodeToOriginEdge.getBendPoints())

                let lastBendPoint = KVector(originPort.getPosition())
                lastBendPoint.add(node.getPosition())
                outgoingEdgeBendPoints.append(lastBendPoint)

                // Retrieve the original hierarchical port dummy
                guard let replacedDummy = node.getProperty(InternalProperties.EXT_PORT_REPLACED_DUMMY) as? LNode else {
                    continue
                }
                let replacedDummyPort = replacedDummy.getPorts()[0]

                // Reroute all the input port's edges
                if let inPort = nodeInPort {
                    let edges = Array(inPort.getIncomingEdges())
                    for edge in edges {
                        edge.setTarget(replacedDummyPort)
                        edge.getBendPoints().addAllAsCopies(
                            at: edge.getBendPoints().size(), incomingEdgeBendPoints.toArray())
                    }
                }

                // Reroute all the output port's edges
                if let outPort = nodeOutPort {
                    let edges = LGraphUtil.toEdgeArray(outPort.getOutgoingEdges())
                    for edge in edges {
                        edge.setSource(replacedDummyPort)
                        edge.getBendPoints().addAllAsCopies(at: 0, outgoingEdgeBendPoints.toArray())
                    }
                }

                // Remove connection between node and original hierarchical port dummy
                nodeToOriginEdge.setSource(nil)
                nodeToOriginEdge.setTarget(nil)

                // Remember the temporary node for removal
                nodesToRemove.append(node)
            }
        }

        // Remove nodes
        for node in nodesToRemove {
            node.setLayer(nil)
        }
    }

    // MARK: - STEP 5: FIX DUMMY COORDINATES

    /**
     * Fixes all hierarchical port dummy coordinates.
     */
    private func fixCoordinates(_ layeredGraph: LGraph) {
        let constraints = layeredGraph.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .FREE

        let layers = layeredGraph.getLayers()
        fixCoordinatesInLayer(layers[0], constraints, layeredGraph)
        fixCoordinatesInLayer(layers[layers.count - 1], constraints, layeredGraph)
    }

    /**
     * Fixes the coordinates of nodes in the given layer.
     */
    private func fixCoordinatesInLayer(_ layer: Layer, _ constraints: PortConstraints, _ graph: LGraph) {
        let padding = graph.getPadding()
        let offset = graph.getOffset()
        let graphActualSize = graph.getActualSize()

        var newActualGraphHeight = graphActualSize.y

        // First iteration: fix EAST and WEST dummy nodes (may change graph height)
        for node in layer.getNodes() {
            if node.getType() != .externalPort {
                continue
            }

            let extPortSide = node.getProperty(InternalProperties.EXT_PORT_SIDE) as? PortSide ?? .UNDEFINED
            let extPortSize = node.getProperty(InternalProperties.EXT_PORT_SIZE) as? KVector ?? KVector()
            let nodePosition = node.getPosition()

            // Set x coordinate
            switch extPortSide {
            case .EAST:
                nodePosition.x = graph.getSize().x + padding.right - offset.x
            case .WEST:
                nodePosition.x = -offset.x - padding.left
            default:
                break
            }

            // Set y coordinate
            var requiredActualGraphHeight = 0.0

            switch extPortSide {
            case .EAST, .WEST:
                if constraints == .FIXED_RATIO {
                    let ratio = node.getProperty(InternalProperties.PORT_RATIO_OR_POSITION) as? Double ?? 0.0
                    let anchorY = (node.getProperty(LayeredOptions.PORT_ANCHOR) as? KVector)?.y ?? 0.0
                    nodePosition.y = graphActualSize.y * ratio - anchorY
                    requiredActualGraphHeight = nodePosition.y + extPortSize.y
                    node.borderToContentAreaCoordinates(false, true)
                } else if constraints == .FIXED_POS {
                    let posOrRatio = node.getProperty(InternalProperties.PORT_RATIO_OR_POSITION) as? Double ?? 0.0
                    let anchorY = (node.getProperty(LayeredOptions.PORT_ANCHOR) as? KVector)?.y ?? 0.0
                    nodePosition.y = posOrRatio - anchorY
                    requiredActualGraphHeight = nodePosition.y + extPortSize.y
                    node.borderToContentAreaCoordinates(false, true)
                }
            default:
                break
            }

            newActualGraphHeight = max(newActualGraphHeight, requiredActualGraphHeight)
        }

        // Make the graph larger, if necessary
        graph.getSize().y += newActualGraphHeight - graphActualSize.y

        // Second iteration: fix NORTH and SOUTH dummies now that the graph's height is fixed
        for node in layer.getNodes() {
            if node.getType() != .externalPort {
                continue
            }

            let extPortSide = node.getProperty(InternalProperties.EXT_PORT_SIDE) as? PortSide ?? .UNDEFINED
            let nodePosition = node.getPosition()

            switch extPortSide {
            case .NORTH:
                nodePosition.y = -offset.y - padding.top
            case .SOUTH:
                nodePosition.y = graph.getSize().y + padding.bottom - offset.y
            default:
                break
            }
        }
    }

    // MARK: - STEP 6: SLANTED EDGE SEGMENT CORRECTION

    /**
     * Goes over E/W hierarchical dummy nodes and checks for slanted incident edge segments.
     */
    private func correctSlantedEdgeSegments(_ layeredGraph: LGraph) {
        let layers = layeredGraph.getLayers()
        correctSlantedEdgeSegmentsInLayer(layers[0])
        correctSlantedEdgeSegmentsInLayer(layers[layers.count - 1])
    }

    /**
     * Corrects slanted edge segments for E/W hierarchical dummy nodes in the given layer.
     */
    private func correctSlantedEdgeSegmentsInLayer(_ layer: Layer) {
        for node in layer.getNodes() {
            if node.getType() != .externalPort {
                continue
            }

            let extPortSide = node.getProperty(InternalProperties.EXT_PORT_SIDE) as? PortSide

            if extPortSide == .EAST || extPortSide == .WEST {
                for edge in node.getConnectedEdges() {
                    let bendPoints = edge.getBendPoints()

                    if bendPoints.isEmpty {
                        // TODO: The edge has no bend points yet, but may still be slanted.
                        continue
                    }

                    // Correct slanted segment connected to the source port if it belongs to our node
                    let sourcePort = edge.getSource()!
                    if sourcePort.getNode() === node {
                        let firstBendPoint = bendPoints.getFirst()!
                        firstBendPoint.y = sourcePort.getAbsoluteAnchor().y
                    }

                    // Correct slanted segment connected to the target port if it belongs to our node
                    let targetPort = edge.getTarget()!
                    if targetPort.getNode() === node {
                        let lastBendPoint = bendPoints.getLast()!
                        lastBendPoint.y = targetPort.getAbsoluteAnchor().y
                    }
                }
            }
        }
    }
}
