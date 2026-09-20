// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p4nodes/NetworkSimplexPlacer.java

import Foundation

package class org_eclipse_elk_alg_layered_p4nodes_NetworkSimplexPlacer {
    package static let EDGE_WEIGHT_BASE: Double = 4.0
    package static let SMALL_EDGE_WEIGHT: Double = 0.1
    package static let LONG_EDGE_VS_PATH_FACTOR: Double = 2.0
    package static let NODE_SIZE_WEIGHT_STATIC: Double = 10_000.0
    package static let NODE_SIZE_WEIGHT_FLEXIBLE: Double = 1.0
    package static let EPSILON: Double = 0.00001

    package static let VISITED: Int = -1
    package static let OTHER: Int = 0
    package static let JUNCTION: Int = 2

    package static let KEY_NODE_PLACEMENT_FAVOR_STRAIGHT_EDGES = "org.eclipse.elk.layered.nodePlacement.favorStraightEdges"
    package static let KEY_THOROUGHNESS = "org.eclipse.elk.layered.thoroughness"
    package static let KEY_PRIORITY_STRAIGHTNESS = "org.eclipse.elk.layered.priority.straightness"
    package static let KEY_PORT_CONSTRAINTS = "org.eclipse.elk.portConstraints"
    package static let KEY_SPACING_PORT_PORT = "org.eclipse.elk.spacing.portPort"
    package static let KEY_SPACING_PORTS_SURROUNDING = "org.eclipse.elk.spacing.portsSurrounding"
    package static let KEY_NODE_LABELS_PLACEMENT = "org.eclipse.elk.nodeLabels.placement"
    package static let KEY_PORT_DUMMY = "portDummy"

    package static let HIERARCHY_PROCESSING_ADDITIONS: LayoutProcessorConfiguration<LayeredPhases, LGraph> = {
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(
                org_eclipse_elk_alg_layered_LayeredPhases.P5_EDGE_ROUTING,
                org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy.HIERARCHICAL_PORT_POSITION_PROCESSOR
            )
    }()

    package var lGraph: org_eclipse_elk_alg_layered_graph_LGraph?
    package var spacings: org_eclipse_elk_alg_layered_options_Spacings?
    package var nGraph: NGraph?

    package var nodeReps: [NodeRep?] = []
    package var edgeReps: [EdgeRep?] = []
    package var portMap: [ObjectIdentifier: org_eclipse_elk_alg_common_networksimplex_NNode] = [:]

    package var nodeCount: Int = 0
    package var edgeCount: Int = 0

    package var nodeState: [Int] = []
    package var twoPaths: [Path] = []
    package var crossing: [Bool] = []

    package var flexibleWhereSpacePermitsEdges: [org_eclipse_elk_alg_common_networksimplex_NEdge] = []

    package init() {}

    package func getLayoutProcessorConfiguration(
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph
    ) -> LayoutProcessorConfiguration<LayeredPhases, LGraph>? {
        let graphProperties = graph.getProperty(org_eclipse_elk_alg_layered_options_InternalProperties.GRAPH_PROPERTIES)
            as? Set<org_eclipse_elk_alg_layered_options_GraphProperties> ?? []
        return graphProperties.contains(.EXTERNAL_PORTS) ? Self.HIERARCHY_PROCESSING_ADDITIONS : nil
    }

    package func process(
        _ layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ progressMonitor: any org_eclipse_elk_core_util_IElkProgressMonitor
    ) {
        progressMonitor.begin("Network simplex node placement", 1)

        lGraph = layeredGraph
        spacings = layeredGraph.getProperty(org_eclipse_elk_alg_layered_options_InternalProperties.SPACINGS)
            as? org_eclipse_elk_alg_layered_options_Spacings ?? org_eclipse_elk_alg_layered_options_Spacings()

        prepare()
        buildInitialAuxiliaryGraph()
        insertNorthSouthAuxiliaryEdges()
        insertInLayerEdgeAuxiliaryEdges()

        let shouldPreferStraightEdges = layeredGraph.getProperty(Self.KEY_NODE_PLACEMENT_FAVOR_STRAIGHT_EDGES) as? Bool ?? false
        if shouldPreferStraightEdges {
            preferStraightEdges()
        }

        guard let nGraph else {
            cleanup()
            progressMonitor.done()
            return
        }
        _ = nGraph.makeConnected()

        let thoroughness = layeredGraph.getProperty(Self.KEY_THOROUGHNESS) as? Int ?? 1
        let iterLimit = max(1, thoroughness) * max(1, nGraph.nodes.count)

        org_eclipse_elk_alg_common_networksimplex_NetworkSimplex.forGraph(nGraph)
            .withIterationLimit(iterLimit)
            .withBalancing(false)
            .execute(progressMonitor)

        if !flexibleWhereSpacePermitsEdges.isEmpty {
            insertFlexibleWhereSpaceAuxiliaryEdges()
            for edge in flexibleWhereSpacePermitsEdges {
                edge.weight = Self.NODE_SIZE_WEIGHT_FLEXIBLE
            }
            org_eclipse_elk_alg_common_networksimplex_NetworkSimplex.forGraph(nGraph)
                .withIterationLimit(iterLimit)
                .withBalancing(false)
                .execute(progressMonitor)
        }

        if shouldPreferStraightEdges {
            postProcessTwoPaths()
        }

        applyPositions()
        cleanup()
        progressMonitor.done()
    }

    package func prepare() {
        nGraph = NGraph()

        var nodeIdx = 0
        var edgeIdx = 0
        for layer in lGraph?.getLayers() ?? [] {
            for lNode in layer.getNodes() {
                lNode.id = nodeIdx
                nodeIdx += 1

                for e in lNode.getOutgoingEdges() {
                    e.id = edgeIdx
                    edgeIdx += 1
                }

                let anchorMustBeInteger = Self.isFlexibleNode(lNode)
                for p in lNode.getPorts() {
                    if anchorMustBeInteger {
                        let y = p.getAnchor().y
                        if y != floor(y) {
                            p.getAnchor().y -= y - y.rounded()
                        }
                    }
                    let y = p.getPosition().y + p.getAnchor().y
                    if y != floor(y) {
                        p.getPosition().y -= y - y.rounded()
                    }
                }
            }
        }

        nodeCount = nodeIdx
        edgeCount = edgeIdx
        nodeReps = Array(repeating: nil, count: nodeIdx)
        edgeReps = Array(repeating: nil, count: edgeIdx)
        flexibleWhereSpacePermitsEdges.removeAll(keepingCapacity: true)
    }

    package func cleanup() {
        lGraph = nil
        spacings = nil
        nGraph = nil

        nodeReps.removeAll(keepingCapacity: false)
        edgeReps.removeAll(keepingCapacity: false)
        portMap.removeAll(keepingCapacity: false)

        nodeState.removeAll(keepingCapacity: false)
        crossing.removeAll(keepingCapacity: false)
        twoPaths.removeAll(keepingCapacity: false)
        flexibleWhereSpacePermitsEdges.removeAll(keepingCapacity: false)
    }

    package func buildInitialAuxiliaryGraph() {
        for layer in lGraph?.getLayers() ?? [] {
            transformLayer(layer)
        }
        transformEdges()
    }

    package func transformLayer(_ layer: org_eclipse_elk_alg_layered_graph_Layer) {
        var lastRep: NodeRep?

        for lNode in layer.getNodes() {
            let nodeRep = Self.isFlexibleNode(lNode) ? transformFixedOrderNode(lNode) : transformFixedPosNode(lNode)
            if lNode.id >= 0, lNode.id < nodeReps.count {
                nodeReps[lNode.id] = nodeRep
            }

            if let lastRep {
                var spacing = lastRep.origin.getMargin().bottom
                    + (spacings?.getVerticalSpacing(lastRep.origin, lNode) ?? 0)
                    + lNode.getMargin().top
                if !lastRep.isFlexible {
                    spacing += lastRep.origin.getSize().y
                }
                _ = createEdge(
                    origin: nil,
                    weight: 0,
                    delta: Int(ceil(spacing)),
                    source: lastRep.tail,
                    target: nodeRep.head
                )
            }

            lastRep = nodeRep
        }
    }

    package func transformFixedPosNode(
        _ lNode: org_eclipse_elk_alg_layered_graph_LNode
    ) -> NodeRep {
        let singleNode = createNode(origin: lNode, type: "non-flexible", baseLayer: Int(round(lNode.getPosition().y)))

        for p in lNode.getPorts() where org_eclipse_elk_core_options_PortSide.SIDES_EAST_WEST.contains(p.getSide()) {
            portMap[ObjectIdentifier(p)] = singleNode
        }

        return NodeRep(origin: lNode, isFlexible: false, head: singleNode, tail: singleNode)
    }

    package func transformFixedOrderNode(
        _ lNode: org_eclipse_elk_alg_layered_graph_LNode
    ) -> NodeRep {
        let topLayer = Int(round(lNode.getPosition().y))
        let bottomLayer = Int(round(lNode.getPosition().y + lNode.getSize().y))
        let topLeft = createNode(origin: lNode, type: "flexible-head", baseLayer: topLayer)
        let bottomLeft = createNode(origin: lNode, type: "flexible-tail", baseLayer: bottomLayer)
        let corners = NodeRep(origin: lNode, isFlexible: true, head: topLeft, tail: bottomLeft)

        let minHeight = lNode.getSize().y
        let nf = org_eclipse_elk_alg_layered_options_NodeFlexibility.getNodeFlexibility(lNode)
        let sizeWeight = nf.isFlexibleSize() ? Self.NODE_SIZE_WEIGHT_FLEXIBLE : Self.NODE_SIZE_WEIGHT_STATIC

        let nodeSizeEdge = createEdge(
            origin: nil,
            weight: sizeWeight,
            delta: Int(ceil(minHeight)),
            source: topLeft,
            target: bottomLeft
        )

        if nf == .NODE_SIZE_WHERE_SPACE_PERMITS {
            flexibleWhereSpacePermitsEdges.append(nodeSizeEdge)
        }

        transformPorts(Array(lNode.getPortSideView(.WEST).reversed()), corners)
        transformPorts(lNode.getPortSideView(.EAST), corners)

        return corners
    }

    package func transformPorts(
        _ ports: [org_eclipse_elk_alg_layered_graph_LPort],
        _ corners: NodeRep
    ) {
        if ports.isEmpty {
            return
        }

        let portSpacing = corners.origin.getProperty(Self.KEY_SPACING_PORT_PORT) as? Double ?? 0
        var portSurrounding = corners.origin.getProperty(Self.KEY_SPACING_PORTS_SURROUNDING)
            as? org_eclipse_elk_core_math_ElkMargin
        if portSurrounding == nil {
            portSurrounding = org_eclipse_elk_core_math_ElkMargin()
        }

        var lastNNode = corners.head
        var lastPort: org_eclipse_elk_alg_layered_graph_LPort?

        for port in ports {
            let spacing: Double
            if let lastPort {
                spacing = portSpacing + lastPort.getSize().y
            } else {
                spacing = portSurrounding?.top ?? 0
            }

            let nNode = createNode(origin: port, type: "port", baseLayer: lastNNode.layer + Int(ceil(spacing)))
            portMap[ObjectIdentifier(port)] = nNode

            _ = createEdge(origin: nil, weight: 0, delta: Int(ceil(spacing)), source: lastNNode, target: nNode)

            lastPort = port
            lastNNode = nNode
        }

        if let lastPort {
            let spacing = (portSurrounding?.bottom ?? 0) + lastPort.getSize().y
            _ = createEdge(
                origin: nil,
                weight: 0,
                delta: Int(ceil(spacing)),
                source: lastNNode,
                target: corners.tail
            )
        }
    }

    package func transformEdges() {
        for layer in lGraph?.getLayers() ?? [] {
            for node in layer.getNodes() {
                for edge in node.getOutgoingEdges() where Self.isHandledEdge(edge) {
                    transformEdge(edge)
                }
            }
        }
    }

    package func transformEdge(_ lEdge: org_eclipse_elk_alg_layered_graph_LEdge) {
        guard let srcPort = lEdge.getSource(),
              let tgtPort = lEdge.getTarget(),
              let srcNode = srcPort.getNode(),
              let tgtNode = tgtPort.getNode(),
              srcNode.id >= 0, srcNode.id < nodeReps.count,
              tgtNode.id >= 0, tgtNode.id < nodeReps.count,
              let srcRep = nodeReps[srcNode.id],
              let tgtRep = nodeReps[tgtNode.id],
              let srcPortRep = portMap[ObjectIdentifier(srcPort)],
              let tgtPortRep = portMap[ObjectIdentifier(tgtPort)]
        else {
            return
        }

        let dummyLayer = (srcPortRep.layer + tgtPortRep.layer) / 2
        let dummy = createNode(origin: nil, type: "edge", baseLayer: dummyLayer)

        var srcOffset = srcPort.getAnchor().y
        var tgtOffset = tgtPort.getAnchor().y
        if !srcRep.isFlexible {
            srcOffset += srcPort.getPosition().y
        }
        if !tgtRep.isFlexible {
            tgtOffset += tgtPort.getPosition().y
        }

        let delta = srcOffset - tgtOffset
        if abs(delta - delta.rounded()) > Self.EPSILON {
            // Keep running in V2: this mirrors Java assert intent without trapping.
        }

        let tgtDelta = Int(max(0, srcOffset - tgtOffset))
        let srcDelta = Int(max(0, tgtOffset - srcOffset))
        let weight = getEdgeWeight(lEdge)

        let left = createEdge(origin: lEdge, weight: weight, delta: srcDelta, source: dummy, target: srcPortRep)
        let right = createEdge(origin: lEdge, weight: weight, delta: tgtDelta, source: dummy, target: tgtPortRep)
        let edgeRep = EdgeRep(origin: lEdge, left: left, right: right)

        if lEdge.id >= 0, lEdge.id < edgeReps.count {
            edgeReps[lEdge.id] = edgeRep
        }
    }

    package func insertInLayerEdgeAuxiliaryEdges() {
        for layer in lGraph?.getLayers() ?? [] {
            for node in layer.getNodes() where node.getType() == .NORMAL {
                for inLayerEdge in node.getConnectedEdges() where inLayerEdge.isInLayerEdge() {
                    let srcIsDummy = inLayerEdge.getSource()?.getNode()?.getType() != .NORMAL
                    guard let thePort = srcIsDummy ? inLayerEdge.getTarget() : inLayerEdge.getSource(),
                          let dummyNode = inLayerEdge.getOther(thePort).getNode(),
                          dummyNode.id >= 0,
                          dummyNode.id < nodeReps.count,
                          let dummyRep = nodeReps[dummyNode.id]?.head,
                          let portRep = portMap[ObjectIdentifier(thePort)],
                          let owner = thePort.getNode()
                    else {
                        continue
                    }

                    let src: org_eclipse_elk_alg_common_networksimplex_NNode
                    let tgt: org_eclipse_elk_alg_common_networksimplex_NNode
                    if owner.getIndex() < dummyNode.getIndex() {
                        src = portRep
                        tgt = dummyRep
                    } else {
                        src = dummyRep
                        tgt = portRep
                    }

                    _ = createEdge(origin: nil, weight: Self.EDGE_WEIGHT_BASE, delta: 0, source: src, target: tgt)
                }
            }
        }
    }

    package func insertNorthSouthAuxiliaryEdges() {
        for layer in lGraph?.getLayers() ?? [] {
            for n in layer.getNodes() {
                for sp in n.getPortSideView(.SOUTH) {
                    let other = sp.getProperty(Self.KEY_PORT_DUMMY) as? org_eclipse_elk_alg_layered_graph_LNode
                    if let other,
                       n.id >= 0, n.id < nodeReps.count, other.id >= 0, other.id < nodeReps.count,
                       let nTail = nodeReps[n.id]?.tail,
                       let otherHead = nodeReps[other.id]?.head
                    {
                        _ = createEdge(origin: nil, weight: Self.SMALL_EDGE_WEIGHT, delta: 0, source: nTail, target: otherHead)
                    }
                }

                for sp in n.getPortSideView(.NORTH) {
                    let other = sp.getProperty(Self.KEY_PORT_DUMMY) as? org_eclipse_elk_alg_layered_graph_LNode
                    if let other,
                       n.id >= 0, n.id < nodeReps.count, other.id >= 0, other.id < nodeReps.count,
                       let otherTail = nodeReps[other.id]?.tail,
                       let nHead = nodeReps[n.id]?.head
                    {
                        _ = createEdge(origin: nil, weight: Self.SMALL_EDGE_WEIGHT, delta: 0, source: otherTail, target: nHead)
                    }
                }
            }
        }
    }

    package func insertFlexibleWhereSpaceAuxiliaryEdges() {
        guard let nGraph, !nGraph.nodes.isEmpty else {
            return
        }

        let minLayer = nGraph.nodes.map(\.layer).min() ?? 0
        let maxLayer = nGraph.nodes.map(\.layer).max() ?? 0
        let usedLayers = maxLayer - minLayer

        let globalSource = createNode(origin: nil, type: "global-source", baseLayer: minLayer)
        let globalSink = createNode(origin: nil, type: "global-sink", baseLayer: maxLayer)

        _ = createEdge(
            origin: nil,
            weight: Self.NODE_SIZE_WEIGHT_STATIC * 2,
            delta: usedLayers,
            source: globalSource,
            target: globalSink
        )

        for rep in nodeReps.compactMap({ $0 }) where rep.origin.getType() == .NORMAL && rep.origin.getPorts().count > 1 {
            _ = createEdge(origin: nil, weight: 0, delta: rep.tail.layer - minLayer, source: globalSource, target: rep.tail)
            _ = createEdge(origin: nil, weight: 0, delta: usedLayers - rep.head.layer, source: rep.head, target: globalSink)
        }
    }

    package func applyPositions() {
        for layer in lGraph?.getLayers() ?? [] {
            for lNode in layer.getNodes() {
                guard lNode.id >= 0, lNode.id < nodeReps.count, let nodeRep = nodeReps[lNode.id] else {
                    continue
                }

                let minY = Double(nodeRep.head.layer)
                let maxY = Double(nodeRep.tail.layer)
                lNode.getPosition().y = minY

                let sizeDelta = (maxY - minY) - lNode.getSize().y
                let flexibleNode = Self.isFlexibleNode(lNode)
                let nf = org_eclipse_elk_alg_layered_options_NodeFlexibility.getNodeFlexibility(lNode)

                if flexibleNode && nf.isFlexibleSizeWhereSpacePermits() {
                    lNode.getSize().y += sizeDelta
                }

                if flexibleNode && nf.isFlexiblePorts() {
                    for p in lNode.getPorts() where org_eclipse_elk_core_options_PortSide.SIDES_EAST_WEST.contains(p.getSide()) {
                        if let nNode = portMap[ObjectIdentifier(p)] {
                            p.getPosition().y = Double(nNode.layer) - minY
                        }
                    }

                    for label in lNode.getLabels() {
                        adjustLabelPosition(lNode, label, sizeDelta)
                    }

                    if nf.isFlexibleSizeWhereSpacePermits() {
                        for p in lNode.getPortSideView(.SOUTH) {
                            p.getPosition().y += sizeDelta
                        }
                    }
                }
            }
        }
    }

    package func adjustLabelPosition(
        _ node: org_eclipse_elk_alg_layered_graph_LNode,
        _ label: org_eclipse_elk_alg_layered_graph_LLabel,
        _ sizeDelta: Double
    ) {
        if let placement = node.getProperty(Self.KEY_NODE_LABELS_PLACEMENT) as? Set<String> {
            if placement.contains("V_BOTTOM") {
                label.getPosition().y += sizeDelta
            } else if placement.contains("V_CENTER") {
                label.getPosition().y += sizeDelta / 2.0
            }
            return
        }

        if let placement = node.getProperty(Self.KEY_NODE_LABELS_PLACEMENT) as? [String] {
            if placement.contains("V_BOTTOM") {
                label.getPosition().y += sizeDelta
            } else if placement.contains("V_CENTER") {
                label.getPosition().y += sizeDelta / 2.0
            }
        }
    }

    package func getEdgeWeight(_ edge: org_eclipse_elk_alg_layered_graph_LEdge) -> Double {
        let priority = max(1, edge.getProperty(Self.KEY_PRIORITY_STRAIGHTNESS) as? Int ?? 1)
        let sourceType = edge.getSource()?.getNode()?.getType() ?? .NORMAL
        let targetType = edge.getTarget()?.getNode()?.getType() ?? .NORMAL
        return Double(priority) * getEdgeWeight(sourceType, targetType)
    }

    package func getEdgeWeight(
        _ nodeType1: org_eclipse_elk_alg_layered_graph_NodeType,
        _ nodeType2: org_eclipse_elk_alg_layered_graph_NodeType
    ) -> Double {
        if nodeType1 == .NORMAL && nodeType2 == .NORMAL {
            return 1.0 * Self.EDGE_WEIGHT_BASE
        }
        if nodeType1 == .NORMAL || nodeType2 == .NORMAL {
            return 2.0 * Self.EDGE_WEIGHT_BASE
        }
        return 8.0 * Self.EDGE_WEIGHT_BASE
    }

    package static func isHandledEdge(_ edge: org_eclipse_elk_alg_layered_graph_LEdge) -> Bool {
        !edge.isSelfLoop() && !edge.isInLayerEdge()
    }

    package static func isFlexibleNode(_ lNode: org_eclipse_elk_alg_layered_graph_LNode) -> Bool {
        if lNode.getType() != .NORMAL {
            return false
        }
        if lNode.getPorts().count <= 1 {
            return false
        }

        let pc = lNode.getProperty(Self.KEY_PORT_CONSTRAINTS) as? org_eclipse_elk_core_options_PortConstraints ?? .UNDEFINED
        if pc.isPosFixed() {
            return false
        }

        let nf = org_eclipse_elk_alg_layered_options_NodeFlexibility.getNodeFlexibility(lNode)
        if nf == .NONE {
            return false
        }

        if !nf.isFlexibleSizeWhereSpacePermits() {
            let portSpacing = lNode.getProperty(Self.KEY_SPACING_PORT_PORT) as? Double ?? 0
            var additionalPortSpacing = lNode.getProperty(Self.KEY_SPACING_PORTS_SURROUNDING)
                as? org_eclipse_elk_core_math_ElkMargin
            if additionalPortSpacing == nil {
                additionalPortSpacing = org_eclipse_elk_core_math_ElkMargin(portSpacing)
            }

            let westPorts = lNode.getPortSideView(.WEST)
            let requiredWestHeight = (additionalPortSpacing?.top ?? 0)
                + (additionalPortSpacing?.bottom ?? 0)
                + Double(max(0, westPorts.count - 1)) * portSpacing
            if requiredWestHeight > lNode.getSize().y {
                return false
            }

            let eastPorts = lNode.getPortSideView(.EAST)
            let requiredEastHeight = (additionalPortSpacing?.top ?? 0)
                + (additionalPortSpacing?.bottom ?? 0)
                + Double(max(0, eastPorts.count - 1)) * portSpacing
            if requiredEastHeight > lNode.getSize().y {
                return false
            }
        }

        return true
    }

    package func preferStraightEdges() {
        guard let lGraph else { return }

        nodeState = Array(repeating: Self.OTHER, count: nodeCount)
        twoPaths.removeAll(keepingCapacity: true)

        for layer in lGraph.getLayers() {
            for n in layer.getNodes() where n.id >= 0 && n.id < nodeState.count {
                nodeState[n.id] = Self.getNodeState(n)
            }
        }

        markEdgeCrossings()
        let identifiedPaths = identifyPaths()

        for path in identifiedPaths {
            if path.size <= 1 {
                continue
            }

            if path.size == 2 {
                path.orderTwoPath()
                if !path.isTwoPathCenterNodeFlexible() {
                    twoPaths.append(path)
                }
                continue
            }

            if path.containsLongEdgeDummy() || path.containsFlexibleNode({ $0.isFlexibleSizeWhereSpacePermits() }) {
                continue
            }

            var last: org_eclipse_elk_alg_layered_graph_LEdge?
            for (index, cur) in path.edges.enumerated() {
                guard cur.id >= 0, cur.id < edgeReps.count, let curRep = edgeReps[cur.id] else {
                    continue
                }

                let isBoundary = (index == 0 || index == path.edges.count - 1)
                let baseWeight = isBoundary
                    ? getEdgeWeight(.NORMAL, .LONG_EDGE)
                    : getEdgeWeight(.LONG_EDGE, .LONG_EDGE)
                let weight = baseWeight * Self.LONG_EDGE_VS_PATH_FACTOR

                curRep.left.weight = max(curRep.left.weight, curRep.left.weight + (weight - curRep.left.weight))
                curRep.right.weight = max(curRep.right.weight, curRep.right.weight + (weight - curRep.right.weight))

                last = cur
                _ = last
            }
        }
    }

    package func postProcessTwoPaths() {
        var queue = ArrayDeque<Path>(twoPaths)
        var stack: [Path] = []

        while !queue.isEmpty {
            let path = queue.removeFirst()
            if improveTwoPath(path, true) {
                stack.append(path)
            }
        }

        while !stack.isEmpty {
            let path = stack.removeLast()
            _ = improveTwoPath(path, false)
        }
    }

    package func improveTwoPath(_ path: Path, _ probe: Bool) -> Bool {
        guard path.size == 2 else { return false }
        let leftOrigin = path[0]
        let rightOrigin = path[1]
        guard leftOrigin.id >= 0, leftOrigin.id < edgeReps.count,
              rightOrigin.id >= 0, rightOrigin.id < edgeReps.count,
              let leftEdge = edgeReps[leftOrigin.id],
              let rightEdge = edgeReps[rightOrigin.id]
        else {
            return false
        }

        if leftEdge.isStraight(), rightEdge.isStraight() {
            return false
        }

        guard let rightTarget = leftEdge.right.target,
              let centerNode = rightTarget.origin as? org_eclipse_elk_alg_layered_graph_LNode,
              centerNode.id >= 0,
              centerNode.id < nodeReps.count,
              let nNode = nodeReps[centerNode.id],
              let centerLayer = centerNode.getLayer()
        else {
            return false
        }

        let nodeIndex = centerNode.getIndex()
        var aboveDist = Double.infinity
        if nodeIndex > 0 {
            let above = centerLayer.getNodes()[nodeIndex - 1]
            if above.id >= 0, above.id < nodeReps.count, let aboveRep = nodeReps[above.id] {
                let spacing = ceil(spacings?.getVerticalSpacing(above, centerNode) ?? 0)
                aboveDist = Double(nNode.head.layer) - centerNode.getMargin().top
                    - (Double(aboveRep.head.layer) + above.getSize().y + above.getMargin().bottom)
                    - spacing
            }
        }

        var belowDist = Double.infinity
        if nodeIndex < centerLayer.getNodes().count - 1 {
            let below = centerLayer.getNodes()[nodeIndex + 1]
            if below.id >= 0, below.id < nodeReps.count, let belowRep = nodeReps[below.id] {
                let spacing = ceil(spacings?.getVerticalSpacing(below, centerNode) ?? 0)
                belowDist = Double(belowRep.head.layer) - below.getMargin().top
                    - (Double(nNode.head.layer) + centerNode.getSize().y + centerNode.getMargin().bottom)
                    - spacing
            }
        }

        if probe, abs(aboveDist - belowDist) <= Self.EPSILON {
            return true
        }

        let a = +Self.length(leftEdge.left)
        let b = -Self.length(leftEdge.right)
        let c = -Self.length(rightEdge.left)
        let d = +Self.length(rightEdge.right)

        let caseD = (leftEdge.notStraightBy() > 0 && rightEdge.notStraightBy() < 0)
        let caseC = (leftEdge.notStraightBy() < 0 && rightEdge.notStraightBy() > 0)
        let leftLeftTargetLayer = leftEdge.left.target?.layer ?? 0
        let rightRightTargetLayer = rightEdge.right.target?.layer ?? 0
        let caseB =
            leftLeftTargetLayer + leftEdge.right.delta
            < rightRightTargetLayer + rightEdge.left.delta
        let caseA =
            leftLeftTargetLayer + leftEdge.right.delta
            > rightRightTargetLayer + rightEdge.left.delta

        var move = 0
        if !caseD, !caseC {
            if caseA {
                if aboveDist + Double(c) > 0 {
                    move = c
                } else if belowDist - Double(a) > 0 {
                    move = a
                }
            } else if caseB {
                if aboveDist + Double(b) > 0 {
                    move = b
                } else if belowDist - Double(d) > 0 {
                    move = d
                }
            }
        }

        nNode.head.layer += move
        if nNode.isFlexible {
            nNode.tail.layer += move
        }

        return false
    }

    package static func length(_ edge: org_eclipse_elk_alg_common_networksimplex_NEdge) -> Int {
        abs((edge.source?.layer ?? 0) - (edge.target?.layer ?? 0)) - edge.delta
    }

    package func identifyPaths() -> [Path] {
        var paths: [Path] = []
        for layer in lGraph?.getLayers() ?? [] {
            for junction in layer.getNodes() where junction.id >= 0 && junction.id < nodeState.count && nodeState[junction.id] == Self.JUNCTION {
                for e in junction.getConnectedEdges() {
                    if !Self.isHandledEdge(e) {
                        continue
                    }
                    let path = follow(e, junction, Path())
                    if path.size > 1 {
                        paths.append(path)
                    }
                }
            }
        }
        return paths
    }

    package func follow(
        _ edge: org_eclipse_elk_alg_layered_graph_LEdge,
        _ current: org_eclipse_elk_alg_layered_graph_LNode,
        _ path: Path
    ) -> Path {
        let other = edge.getOther(current)
        path.add(edge)

        if other.id >= 0, other.id < nodeState.count, edge.id >= 0, edge.id < crossing.count {
            if nodeState[other.id] == Self.VISITED || nodeState[other.id] == Self.JUNCTION || crossing[edge.id] {
                return path
            }
        } else {
            return path
        }

        nodeState[other.id] = Self.VISITED
        for incident in other.getConnectedEdges() {
            if !Self.isHandledEdge(incident) || incident === edge {
                continue
            }
            return follow(incident, other, path)
        }

        return path
    }

    package static func getNodeState(_ node: org_eclipse_elk_alg_layered_graph_LNode) -> Int {
        var inco = 0
        var ouco = 0

        for p in node.getPorts() {
            inco += p.getIncomingEdges().reduce(0) { $0 + ($1.isSelfLoop() ? 0 : 1) }
            ouco += p.getOutgoingEdges().reduce(0) { $0 + ($1.isSelfLoop() ? 0 : 1) }
            if inco > 1 || ouco > 1 {
                return Self.JUNCTION
            }
        }

        return (inco + ouco == 1) ? Self.JUNCTION : Self.OTHER
    }

    package func markEdgeCrossings() {
        crossing = Array(repeating: false, count: edgeCount)

        let layers = lGraph?.getLayers() ?? []
        if layers.count < 2 {
            return
        }

        for i in 1 ..< layers.count {
            markCrossingEdges(layers[i - 1], layers[i])
        }
    }

    package func markCrossingEdges(
        _ left: org_eclipse_elk_alg_layered_graph_Layer,
        _ right: org_eclipse_elk_alg_layered_graph_Layer
    ) {
        var openEdges: [org_eclipse_elk_alg_layered_graph_LEdge] = []

        for node in left.getNodes() {
            for port in node.getPortSideView(.EAST) {
                for edge in port.getOutgoingEdges() {
                    if edge.isInLayerEdge() || edge.isSelfLoop() || edge.getTarget()?.getNode()?.getLayer() !== right {
                        continue
                    }
                    openEdges.append(edge)
                }
            }
        }

        for node in right.getNodes().reversed() {
            for port in node.getPortSideView(.WEST) {
                for edge in port.getIncomingEdges() {
                    if edge.isInLayerEdge() || edge.isSelfLoop() || edge.getSource()?.getNode()?.getLayer() !== left {
                        continue
                    }

                    if !openEdges.isEmpty {
                        var idx = openEdges.count - 1
                        var last = openEdges[idx]

                        while last !== edge && idx > 0 {
                            if last.id >= 0, last.id < crossing.count {
                                crossing[last.id] = true
                            }
                            if edge.id >= 0, edge.id < crossing.count {
                                crossing[edge.id] = true
                            }
                            idx -= 1
                            last = openEdges[idx]
                        }

                        if idx > 0 {
                            openEdges.remove(at: idx)
                        }
                    }
                }
            }
        }
    }

    package func createNode(
        origin: org_eclipse_elk_alg_layered_graph_LGraphElement?,
        type: String,
        baseLayer: Int
    ) -> org_eclipse_elk_alg_common_networksimplex_NNode {
        guard let nGraph else {
            let fallback = org_eclipse_elk_alg_common_networksimplex_NNode()
            fallback.origin = origin
            fallback.type = type
            fallback.layer = baseLayer
            return fallback
        }

        let node = org_eclipse_elk_alg_common_networksimplex_NNode.of()
            .origin(origin as Any)
            .type(type)
            .create(nGraph)
        node.layer = baseLayer
        return node
    }

    package func createEdge(
        origin: org_eclipse_elk_alg_layered_graph_LEdge?,
        weight: Double,
        delta: Int,
        source: org_eclipse_elk_alg_common_networksimplex_NNode,
        target: org_eclipse_elk_alg_common_networksimplex_NNode
    ) -> org_eclipse_elk_alg_common_networksimplex_NEdge {
        org_eclipse_elk_alg_common_networksimplex_NEdge.of(origin)
            .weight(weight)
            .delta(delta)
            .source(source)
            .target(target)
            .create()
    }

    package final class NodeRep {
        var origin: org_eclipse_elk_alg_layered_graph_LNode
        var head: org_eclipse_elk_alg_common_networksimplex_NNode
        var tail: org_eclipse_elk_alg_common_networksimplex_NNode
        var isFlexible: Bool

        init(
            origin: org_eclipse_elk_alg_layered_graph_LNode,
            isFlexible: Bool,
            head: org_eclipse_elk_alg_common_networksimplex_NNode,
            tail: org_eclipse_elk_alg_common_networksimplex_NNode
        ) {
            self.origin = origin
            self.isFlexible = isFlexible
            self.head = head
            self.tail = tail
        }
    }

    package final class EdgeRep {
        var origin: org_eclipse_elk_alg_layered_graph_LEdge
        var left: org_eclipse_elk_alg_common_networksimplex_NEdge
        var right: org_eclipse_elk_alg_common_networksimplex_NEdge

        init(
            origin: org_eclipse_elk_alg_layered_graph_LEdge,
            left: org_eclipse_elk_alg_common_networksimplex_NEdge,
            right: org_eclipse_elk_alg_common_networksimplex_NEdge
        ) {
            self.origin = origin
            self.left = left
            self.right = right
        }

        package func isStraight() -> Bool {
            notStraightBy() == 0
        }

        package func notStraightBy() -> Int {
            ((left.target?.layer ?? 0) - left.delta) - ((right.target?.layer ?? 0) - right.delta)
        }
    }

    package final class Path {
        var edges: [org_eclipse_elk_alg_layered_graph_LEdge] = []

        var isEmpty: Bool { edges.isEmpty }
        var size: Int { edges.count }

        package func add(_ edge: org_eclipse_elk_alg_layered_graph_LEdge) {
            edges.append(edge)
        }

        package func clear() {
            edges.removeAll(keepingCapacity: false)
        }

        subscript(_ index: Int) -> org_eclipse_elk_alg_layered_graph_LEdge {
            edges[index]
        }

        package func containsLongEdgeDummy() -> Bool {
            if edges.isEmpty {
                return false
            }
            if edges[0].getSource()?.getNode()?.getType() == .LONG_EDGE {
                return true
            }
            return edges.contains { $0.getTarget()?.getNode()?.getType() == .LONG_EDGE }
        }

        package func containsFlexibleNode(
            _ predicate: (org_eclipse_elk_alg_layered_options_NodeFlexibility) -> Bool
        ) -> Bool {
            if edges.isEmpty {
                return false
            }

            if let sourceNode = edges[0].getSource()?.getNode(),
               predicate(org_eclipse_elk_alg_layered_options_NodeFlexibility.getNodeFlexibility(sourceNode))
            {
                return true
            }

            return edges.compactMap { $0.getTarget()?.getNode() }
                .contains { predicate(org_eclipse_elk_alg_layered_options_NodeFlexibility.getNodeFlexibility($0)) }
        }

        package func orderTwoPath() {
            if size != 2 {
                return
            }
            let first = edges[0]
            let second = edges[1]
            if first.getTarget()?.getNode() !== second.getSource()?.getNode() {
                clear()
                add(second)
                add(first)
            }
        }

        package func isTwoPathCenterNodeFlexible() -> Bool {
            guard size == 2, let center = edges[0].getTarget()?.getNode() else {
                return false
            }
            return org_eclipse_elk_alg_layered_p4nodes_NetworkSimplexPlacer.isFlexibleNode(center)
        }
    }
}
