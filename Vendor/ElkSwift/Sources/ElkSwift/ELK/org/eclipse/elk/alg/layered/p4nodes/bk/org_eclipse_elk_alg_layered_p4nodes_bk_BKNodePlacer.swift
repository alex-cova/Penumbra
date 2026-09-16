// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p4nodes/bk/BKNodePlacer.java

import Foundation

package final class org_eclipse_elk_alg_layered_p4nodes_bk_BKNodePlacer {
    package enum OptionKeys {
        static let nodePlacementBkFixedAlignment = "org.eclipse.elk.layered.nodePlacement.bk.fixedAlignment"
        static let nodePlacementFavorStraightEdgesFull = "org.eclipse.elk.layered.nodePlacement.favorStraightEdges"
        static let nodePlacementFavorStraightEdgesShort = "nodePlacement.favorStraightEdges"
    }

    /// Additional processor dependencies for graphs with hierarchical ports.
    package static let HIERARCHY_PROCESSING_ADDITIONS: LayoutProcessorConfiguration<LayeredPhases, LGraph> = {
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(
                org_eclipse_elk_alg_layered_LayeredPhases.P5_EDGE_ROUTING,
                org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy.HIERARCHICAL_PORT_POSITION_PROCESSOR
            )
    }()

    package var lGraph: org_eclipse_elk_alg_layered_graph_LGraph?
    package var markedEdges: Set<org_eclipse_elk_alg_layered_graph_LEdge> = []
    package var ni: org_eclipse_elk_alg_layered_p4nodes_bk_NeighborhoodInformation?
    package var produceBalancedLayout: Bool = false

    package init() {}

    /// Java source: BKNodePlacer.getLayoutProcessorConfiguration(LGraph)
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

    /// Java source: BKNodePlacer.process(LGraph, IElkProgressMonitor)
    package func process(
        _ layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ monitor: any org_eclipse_elk_core_util_IElkProgressMonitor
    ) {
        monitor.begin("Brandes & Koepf node placement", 1)

        lGraph = layeredGraph
        ni = org_eclipse_elk_alg_layered_p4nodes_bk_NeighborhoodInformation.buildFor(layeredGraph)

        let align = getFixedAlignment(layeredGraph)
        let favorStraightEdges = getFavorStraightEdges(layeredGraph)
        produceBalancedLayout = (align == .NONE && !favorStraightEdges) || align == .BALANCED

        markConflicts(layeredGraph)

        var layouts: [org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout] = []
        switch align {
        case .LEFTDOWN:
            layouts.append(org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout(
                layeredGraph,
                ni?.nodeCount ?? 0,
                .DOWN,
                .LEFT
            ))
        case .LEFTUP:
            layouts.append(org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout(
                layeredGraph,
                ni?.nodeCount ?? 0,
                .UP,
                .LEFT
            ))
        case .RIGHTDOWN:
            layouts.append(org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout(
                layeredGraph,
                ni?.nodeCount ?? 0,
                .DOWN,
                .RIGHT
            ))
        case .RIGHTUP:
            layouts.append(org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout(
                layeredGraph,
                ni?.nodeCount ?? 0,
                .UP,
                .RIGHT
            ))
        case .NONE, .BALANCED:
            layouts.append(org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout(
                layeredGraph,
                ni?.nodeCount ?? 0,
                .DOWN,
                .RIGHT
            ))
            layouts.append(org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout(
                layeredGraph,
                ni?.nodeCount ?? 0,
                .UP,
                .RIGHT
            ))
            layouts.append(org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout(
                layeredGraph,
                ni?.nodeCount ?? 0,
                .DOWN,
                .LEFT
            ))
            layouts.append(org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout(
                layeredGraph,
                ni?.nodeCount ?? 0,
                .UP,
                .LEFT
            ))
        }

        guard let ni else {
            monitor.done()
            return
        }

        let aligner = org_eclipse_elk_alg_layered_p4nodes_bk_BKAligner(layeredGraph, ni)
        for bal in layouts {
            aligner.verticalAlignment(bal, markedEdges)
            aligner.insideBlockShift(bal)
        }

        let compactor: org_eclipse_elk_alg_layered_p4nodes_bk_ICompactor =
            org_eclipse_elk_alg_layered_p4nodes_bk_BKCompactor(layeredGraph, ni)
        for bal in layouts {
            compactor.horizontalCompaction(bal)
        }

        var chosenLayout: org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout?

        if produceBalancedLayout {
            let balanced = createBalancedLayout(layouts, ni.nodeCount)
            let passesConstraint = checkOrderConstraint(layeredGraph, balanced, monitor)
            if passesConstraint {
                chosenLayout = balanced
            }
        }

        if chosenLayout == nil {
            for bal in layouts {
                let passes = checkOrderConstraint(layeredGraph, bal, monitor)
                if passes {
                    if chosenLayout == nil || (chosenLayout?.layoutSize() ?? .infinity) > bal.layoutSize() {
                        chosenLayout = bal
                    }
                }
            }
        }

        if chosenLayout == nil, let first = layouts.first {
            chosenLayout = first
        }


        if let chosenLayout {
            for layer in layeredGraph.getLayers() {
                for node in layer.getNodes() {
                    node.getPosition().y = chosenLayout.y[node.id] + chosenLayout.innerShift[node.id]
                }
            }
        }

        for bal in layouts {
            bal.cleanup()
        }
        ni.cleanup()
        markedEdges.removeAll(keepingCapacity: false)

        monitor.done()
    }

    package static let MIN_LAYERS_FOR_CONFLICTS: Int = 3

    /// Java source: BKNodePlacer.markConflicts(LGraph)
    package func markConflicts(_ layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph) {
        let numberOfLayers = layeredGraph.getLayers().count
        if numberOfLayers < Self.MIN_LAYERS_FOR_CONFLICTS {
            return
        }

        var layerSize = Array(repeating: 0, count: numberOfLayers)
        for (index, layer) in layeredGraph.getLayers().enumerated() {
            layerSize[index] = layer.getNodes().count
        }

        let layers = layeredGraph.getLayers()
        for i in 1 ..< numberOfLayers - 1 {
            let currentLayer = layers[i + 1]
            var k_0 = 0
            var l = 0

            for l_1 in 0 ..< layerSize[i + 1] {
                let v_l_i = currentLayer.getNodes()[l_1]

                if l_1 == layerSize[i + 1] - 1 || incidentToInnerSegment(v_l_i, i + 1, i) {
                    var k_1 = layerSize[i] - 1
                    if incidentToInnerSegment(v_l_i, i + 1, i),
                       let ni,
                       !ni.leftNeighbors[v_l_i.id].isEmpty,
                       let leftNeighbor = ni.leftNeighbors[v_l_i.id][0].getFirst()
                    {
                        k_1 = ni.nodeIndex[leftNeighbor.id]
                    }

                    while l <= l_1 {
                        let v_l = currentLayer.getNodes()[l]

                        if !incidentToInnerSegment(v_l, i + 1, i), let ni {
                            for upperNeighbor in ni.leftNeighbors[v_l.id] {
                                guard let upper = upperNeighbor.getFirst() else {
                                    continue
                                }
                                let k = ni.nodeIndex[upper.id]

                                if k < k_0 || k > k_1,
                                   let edge = upperNeighbor.getSecond()
                                {
                                    markedEdges.insert(edge)
                                }
                            }
                        }

                        l += 1
                    }

                    k_0 = k_1
                }
            }
        }
    }

    /// Java source: BKNodePlacer.createBalancedLayout(List<BKAlignedLayout>, int)
    package func createBalancedLayout(
        _ layouts: [org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout],
        _ nodeCount: Int
    ) -> org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout {
        guard let lGraph else {
            return org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout()
        }

        let noOfLayouts = layouts.count
        let balanced = org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout(
            lGraph,
            nodeCount,
            .DOWN,
            .RIGHT
        )

        if noOfLayouts == 0 {
            return balanced
        }

        var width = Array(repeating: 0.0, count: noOfLayouts)
        var minVals = Array(repeating: Double.greatestFiniteMagnitude, count: noOfLayouts)
        var maxVals = Array(repeating: -Double.greatestFiniteMagnitude, count: noOfLayouts)
        var minWidthLayout = 0

        for i in 0 ..< noOfLayouts {
            let bal = layouts[i]
            width[i] = bal.layoutSize()
            if width[minWidthLayout] > width[i] {
                minWidthLayout = i
            }

            for layer in lGraph {
                for n in layer {
                    let nodePosY = bal.y[n.id] + bal.innerShift[n.id]
                    minVals[i] = Swift.min(minVals[i], nodePosY)
                    maxVals[i] = Swift.max(maxVals[i], nodePosY + n.getSize().y)
                }
            }
        }

        var shift = Array(repeating: 0.0, count: noOfLayouts)
        for i in 0 ..< noOfLayouts {
            if layouts[i].vdir == .DOWN {
                shift[i] = minVals[minWidthLayout] - minVals[i]
            } else {
                shift[i] = maxVals[minWidthLayout] - maxVals[i]
            }
        }


        var calculatedYs = Array(repeating: 0.0, count: noOfLayouts)
        for layer in lGraph.getLayers() {
            for node in layer.getNodes() {
                for i in 0 ..< noOfLayouts {
                    calculatedYs[i] = layouts[i].y[node.id] + layouts[i].innerShift[node.id] + shift[i]
                }

                calculatedYs.sort()
                if noOfLayouts >= 4 {
                    balanced.y[node.id] = (calculatedYs[1] + calculatedYs[2]) / 2.0
                } else {
                    balanced.y[node.id] = calculatedYs[noOfLayouts / 2]
                }
                balanced.innerShift[node.id] = 0.0
            }
        }

        return balanced
    }

    /// Java source: BKNodePlacer.incidentToInnerSegment(LNode, int, int)
    package func incidentToInnerSegment(
        _ node: org_eclipse_elk_alg_layered_graph_LNode,
        _ layer1: Int,
        _ layer2: Int
    ) -> Bool {
        if node.getType() == .LONG_EDGE {
            for edge in node.getIncomingEdges() {
                guard let sourceNode = edge.getSource()?.getNode(),
                      sourceNode.getType() == .LONG_EDGE,
                      let sourceLayer = sourceNode.getLayer(),
                      let nodeLayer = node.getLayer(),
                      let ni
                else {
                    continue
                }

                if ni.layerIndex[sourceLayer.id] == layer2,
                   ni.layerIndex[nodeLayer.id] == layer1
                {
                    return true
                }
            }
        }
        return false
    }

    /// Java source: BKNodePlacer.getEdge(LNode, LNode)
    package static func getEdge(
        _ source: org_eclipse_elk_alg_layered_graph_LNode,
        _ target: org_eclipse_elk_alg_layered_graph_LNode
    ) -> org_eclipse_elk_alg_layered_graph_LEdge? {
        for edge in source.getConnectedEdges() {
            if edge.getTarget()?.getNode() === target || edge.getSource()?.getNode() === target {
                return edge
            }
        }

        return nil
    }

    /// Java source: BKNodePlacer.getBlocks(BKAlignedLayout)
    package static func getBlocks(
        _ bal: org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout
    ) -> [org_eclipse_elk_alg_layered_graph_LNode: [org_eclipse_elk_alg_layered_graph_LNode]] {
        var blocks: [org_eclipse_elk_alg_layered_graph_LNode: [org_eclipse_elk_alg_layered_graph_LNode]] = [:]

        for layer in bal.layeredGraph.getLayers() {
            for node in layer.getNodes() {
                let root = bal.root[node.id] ?? node
                blocks[root, default: []].append(node)
            }
        }

        return blocks
    }

    /// Java source: BKNodePlacer.getClasses(BKAlignedLayout, IElkProgressMonitor)
    package static func getClasses(
        _ bal: org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout,
        _ monitor: any org_eclipse_elk_core_util_IElkProgressMonitor
    ) -> [org_eclipse_elk_alg_layered_graph_LNode: [org_eclipse_elk_alg_layered_graph_LNode]] {
        _ = monitor
        var classes: [org_eclipse_elk_alg_layered_graph_LNode: [org_eclipse_elk_alg_layered_graph_LNode]] = [:]
        var rootsSeen: Set<ObjectIdentifier> = []

        for root in bal.root {
            guard let root else {
                continue
            }
            let key = ObjectIdentifier(root)
            if rootsSeen.contains(key) {
                continue
            }
            rootsSeen.insert(key)

            guard let sink = bal.sink[root.id] else {
                continue
            }
            classes[sink, default: []].append(root)
        }

        return classes
    }

    /// Java source: BKNodePlacer.checkOrderConstraint(LGraph, BKAlignedLayout, IElkProgressMonitor)
    package func checkOrderConstraint(
        _ layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ bal: org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout,
        _ monitor: any org_eclipse_elk_core_util_IElkProgressMonitor
    ) -> Bool {
        _ = monitor

        var feasible = true

        for layer in layeredGraph.getLayers() {
            var pos = -Double.infinity

            for node in layer.getNodes() {
                let top = bal.y[node.id] + bal.innerShift[node.id] - node.getMargin().top
                let bottom = bal.y[node.id] + bal.innerShift[node.id] + node.getSize().y
                    + node.getMargin().bottom

                if top > pos && bottom > pos {
                    pos = bal.y[node.id] + bal.innerShift[node.id] + node.getSize().y
                        + node.getMargin().bottom
                } else {
                    feasible = false
                    break
                }
            }

            if !feasible {
                break
            }
        }

        return feasible
    }

    package func getFixedAlignment(
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph
    ) -> org_eclipse_elk_alg_layered_options_FixedAlignment {
        graph.getProperty(OptionKeys.nodePlacementBkFixedAlignment)
            as? org_eclipse_elk_alg_layered_options_FixedAlignment ?? .NONE
    }

    package func getFavorStraightEdges(_ graph: org_eclipse_elk_alg_layered_graph_LGraph) -> Bool {
        if let value = graph.getProperty(OptionKeys.nodePlacementFavorStraightEdgesFull) as? Bool {
            return value
        }
        return graph.getProperty(OptionKeys.nodePlacementFavorStraightEdgesShort) as? Bool ?? false
    }
}
