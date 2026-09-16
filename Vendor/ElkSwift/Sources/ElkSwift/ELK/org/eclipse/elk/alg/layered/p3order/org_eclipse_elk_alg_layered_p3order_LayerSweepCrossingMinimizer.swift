// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/LayerSweepCrossingMinimizer.java
import Foundation

package enum org_eclipse_elk_alg_layered_p3order_CrossMinType {
    case BARYCENTER
    case ONE_SIDED_GREEDY_SWITCH
    case TWO_SIDED_GREEDY_SWITCH
    case MEDIAN
}

package class org_eclipse_elk_alg_layered_p3order_LayerSweepCrossingMinimizer:
    org_eclipse_elk_alg_layered_IHierarchyAwareLayoutProcessor
{
    package enum _Keys {
        static let hierarchyHandling = "org.eclipse.elk.hierarchyHandling"
        static let portConstraints = "org.eclipse.elk.portConstraints"
        static let firstTryWithInitialOrder = "org.eclipse.elk.layered.firstTryWithInitialOrder"
        static let secondTryWithInitialOrder = "org.eclipse.elk.layered.secondTryWithInitialOrder"
        static let considerModelOrderStrategy = "org.eclipse.elk.layered.considerModelOrder.strategy"
        static let considerModelOrderPortModelOrder =
            "org.eclipse.elk.layered.considerModelOrder.portModelOrder"
        static let thoroughness = "org.eclipse.elk.layered.thoroughness"
        static let modelOrderCounterNodeInfluence =
            "org.eclipse.elk.layered.considerModelOrder.crossingCounterNodeInfluence"
        static let modelOrderCounterPortInfluence =
            "org.eclipse.elk.layered.considerModelOrder.crossingCounterPortInfluence"
        static let cmGroupOrderStrategy =
            org_eclipse_elk_alg_layered_options_LayeredOptions.CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CM_GROUP_ORDER_STRATEGY
        static let origin = "org.eclipse.elk.layered.origin"
        static let portDummy = "org.eclipse.elk.layered.portDummy"
    }

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

    package var graphInfoHolders: [org_eclipse_elk_alg_layered_p3order_GraphInfoHolder] = []
    package var graphsWhoseNodeOrderChanged: Set<ObjectIdentifier> = []
    package var random: Random?
    package var randomSeed: Int = 0
    package var crossMinType: org_eclipse_elk_alg_layered_p3order_CrossMinType

    package init() {
        crossMinType = .BARYCENTER
    }

    package init(_ cT: org_eclipse_elk_alg_layered_p3order_CrossMinType) {
        crossMinType = cT
    }

    package func process(
        _ layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ progressMonitor: any org_eclipse_elk_core_util_IElkProgressMonitor
    ) {
        progressMonitor.begin("Minimize Crossings \(crossMinType)", 1)

        let emptyGraph = layeredGraph.getLayers().isEmpty
            || layeredGraph.getLayers().allSatisfy { $0.getNodes().isEmpty }
        let singleNode = layeredGraph.getLayers().count == 1
            && (layeredGraph.getLayers().first?.getNodes().count ?? 0) == 1
        let hierarchy = layeredGraph.getProperty(_Keys.hierarchyHandling) as? HierarchyHandling
            ?? .INHERIT
        let hierarchicalLayout = hierarchy == .INCLUDE_CHILDREN

        if emptyGraph || (singleNode && !hierarchicalLayout) {
            progressMonitor.done()
            return
        }

        let graphsToSweepOn = initialize(layeredGraph)
        let minimizingMethod = chooseMinimizingMethod(graphsToSweepOn)
        minimizeCrossings(graphsToSweepOn, minimizingMethod)
        transferNodeAndPortOrdersToGraph()

        progressMonitor.done()
    }

    package func chooseMinimizingMethod(
        _ graphsToSweepOn: [org_eclipse_elk_alg_layered_p3order_GraphInfoHolder]
    ) -> (org_eclipse_elk_alg_layered_p3order_GraphInfoHolder) -> Void {
        guard let parent = graphsToSweepOn.first else {
            return { _ in }
        }

        if !parent.crossMinDeterministic() {
            return compareDifferentRandomizedLayouts
        }
        if parent.crossMinAlwaysImproves() {
            return minimizeCrossingsNoCounter
        }
        return { [weak self] g in
            _ = self?.minimizeCrossingsWithCounter(g)
        }
    }

    package func minimizeCrossings(
        _ graphsToSweepOn: [org_eclipse_elk_alg_layered_p3order_GraphInfoHolder],
        _ minimizingMethod: (org_eclipse_elk_alg_layered_p3order_GraphInfoHolder) -> Void
    ) {
        for gData in graphsToSweepOn {
            if !gData.currentNodeOrder().isEmpty {
                minimizingMethod(gData)
                if gData.hasParent() {
                    setPortOrderOnParentGraph(gData)
                }
            }
        }
    }

    package func setPortOrderOnParentGraph(_ gData: org_eclipse_elk_alg_layered_p3order_GraphInfoHolder) {
        guard gData.hasExternalPorts(),
              let bestSweep = gData.getBestSweep(),
              let bestNodes = bestSweep.nodes()
        else {
            return
        }

        sortPortsByDummyPositionsInLastLayer(bestNodes, gData.parent(), true)
        sortPortsByDummyPositionsInLastLayer(bestNodes, gData.parent(), false)
        gData.parent().setProperty(_Keys.portConstraints, org_eclipse_elk_core_options_PortConstraints.FIXED_ORDER)
    }

    package func minimizeCrossingsNoCounter(_ gData: org_eclipse_elk_alg_layered_p3order_GraphInfoHolder) {
        var isForwardSweep = nextRandomBool()
        var improved = true

        while improved {
            improved = false
            improved = setFirstLayerOrder(gData, isForwardSweep)
            improved = sweepReducingCrossings(gData, isForwardSweep, false) || improved
            isForwardSweep.toggle()
        }

        setCurrentlyBestNodeOrders()
    }

    package func compareDifferentRandomizedLayouts(_ gData: org_eclipse_elk_alg_layered_p3order_GraphInfoHolder) {
        // Reset the seed, otherwise copies of hierarchical graphs in different parent nodes
        // are laid out differently. Matches Java: random.setSeed(randomSeed)
        random?.setSeed(randomSeed)
        graphsWhoseNodeOrderChanged.removeAll(keepingCapacity: true)

        let nodeInfluence = gData.lGraph().getProperty(_Keys.modelOrderCounterNodeInfluence) as? Double ?? 0
        let portInfluence = gData.lGraph().getProperty(_Keys.modelOrderCounterPortInfluence) as? Double ?? 0
        let strategy = gData.lGraph().getProperty(_Keys.considerModelOrderStrategy)
            as? org_eclipse_elk_alg_layered_options_OrderingStrategy ?? .NONE

        if nodeInfluence != 0 || portInfluence != 0 {
            var bestCrossings = Double.greatestFiniteMagnitude
            if strategy != .NONE {
                gData.lGraph().setProperty(_Keys.firstTryWithInitialOrder, true)
            }
            let thoroughness = Self._intProperty(gData.lGraph(), _Keys.thoroughness) ?? 7
            for _ in 0..<max(1, thoroughness) {
                let crossings = minimizeCrossingsNodePortOrderWithCounter(gData)
                if crossings < bestCrossings {
                    bestCrossings = crossings
                    saveAllNodeOrdersOfChangedGraphs()
                    if bestCrossings == 0 {
                        break
                    }
                }
            }
        } else {
            var bestCrossings = Int.max
            if strategy != .NONE {
                gData.lGraph().setProperty(_Keys.firstTryWithInitialOrder, true)
            }
            let thoroughness = Self._intProperty(gData.lGraph(), _Keys.thoroughness) ?? 7
            for iter in 0..<max(1, thoroughness) {
                let crossings = minimizeCrossingsWithCounter(gData)
                if crossings < bestCrossings {
                    bestCrossings = crossings
                    saveAllNodeOrdersOfChangedGraphs()
                    if bestCrossings == 0 {
                        break
                    }
                }
            }
        }
    }

    package func minimizeCrossingsWithCounter(_ gData: org_eclipse_elk_alg_layered_p3order_GraphInfoHolder) -> Int {
        var isForwardSweep = nextRandomBool()
        let initialCrossings = countCurrentNumberOfCrossings(gData)
        let _firstTry = gData.lGraph().getProperty(_Keys.firstTryWithInitialOrder) as? Bool ?? false
        let _secondTry = gData.lGraph().getProperty(_Keys.secondTryWithInitialOrder) as? Bool ?? false


        if initialCrossings == 0, _firstTry {
            return 0
        }

        let considerModelOrder = gData.lGraph().getProperty(_Keys.considerModelOrderStrategy)
            as? org_eclipse_elk_alg_layered_options_OrderingStrategy ?? .NONE

        if (!(_firstTry || _secondTry)) || considerModelOrder == .NONE {
            _ = setFirstLayerOrder(gData, isForwardSweep)
        } else {
            isForwardSweep = _firstTry
        }

        _ = sweepReducingCrossings(gData, isForwardSweep, true)

        if gData.lGraph().getProperty(_Keys.secondTryWithInitialOrder) as? Bool ?? false {
            gData.lGraph().setProperty(_Keys.secondTryWithInitialOrder, false)
        }
        if gData.lGraph().getProperty(_Keys.firstTryWithInitialOrder) as? Bool ?? false {
            gData.lGraph().setProperty(_Keys.firstTryWithInitialOrder, false)
            gData.lGraph().setProperty(_Keys.secondTryWithInitialOrder, true)
        }

        var crossingsInGraph = countCurrentNumberOfCrossings(gData)
        var oldCrossings: Int
        var sweepIter = 0
        repeat {
            setCurrentlyBestNodeOrders()
            if crossingsInGraph == 0 {
                return 0
            }
            isForwardSweep.toggle()
            oldCrossings = crossingsInGraph
            _ = sweepReducingCrossings(gData, isForwardSweep, false)
            crossingsInGraph = countCurrentNumberOfCrossings(gData)
            sweepIter += 1
        } while oldCrossings > crossingsInGraph

        return oldCrossings
    }

    package func minimizeCrossingsNodePortOrderWithCounter(
        _ gData: org_eclipse_elk_alg_layered_p3order_GraphInfoHolder
    ) -> Double {
        var isForwardSweep = nextRandomBool()
        let initialCrossings = countCurrentNumberOfCrossingsNodePortOrder(gData)

        if initialCrossings == 0,
           gData.lGraph().getProperty(_Keys.firstTryWithInitialOrder) as? Bool ?? false
        {
            return 0
        }

        let considerModelOrder = gData.lGraph().getProperty(_Keys.considerModelOrderStrategy)
            as? org_eclipse_elk_alg_layered_options_OrderingStrategy ?? .NONE
        if (!((gData.lGraph().getProperty(_Keys.firstTryWithInitialOrder) as? Bool ?? false)
            || (gData.lGraph().getProperty(_Keys.secondTryWithInitialOrder) as? Bool ?? false)))
            || considerModelOrder == .NONE
        {
            _ = setFirstLayerOrder(gData, isForwardSweep)
        } else {
            isForwardSweep = gData.lGraph().getProperty(_Keys.firstTryWithInitialOrder) as? Bool ?? false
        }

        _ = sweepReducingCrossings(gData, isForwardSweep, true)
        if gData.lGraph().getProperty(_Keys.secondTryWithInitialOrder) as? Bool ?? false {
            gData.lGraph().setProperty(_Keys.secondTryWithInitialOrder, false)
        }
        if gData.lGraph().getProperty(_Keys.firstTryWithInitialOrder) as? Bool ?? false {
            gData.lGraph().setProperty(_Keys.firstTryWithInitialOrder, false)
            gData.lGraph().setProperty(_Keys.secondTryWithInitialOrder, true)
        }

        var crossingsInGraph = countCurrentNumberOfCrossingsNodePortOrder(gData)
        var oldCrossings: Double
        repeat {
            setCurrentlyBestNodeOrders()
            if crossingsInGraph == 0 {
                return 0
            }
            isForwardSweep.toggle()
            oldCrossings = crossingsInGraph
            _ = sweepReducingCrossings(gData, isForwardSweep, false)
            crossingsInGraph = countCurrentNumberOfCrossingsNodePortOrder(gData)
        } while oldCrossings > crossingsInGraph

        return oldCrossings
    }

    package func countModelOrderNodeChanges(
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ layers: [[org_eclipse_elk_alg_layered_graph_LNode]],
        _ strategy: org_eclipse_elk_alg_layered_options_OrderingStrategy,
        _ cmGroupOrderStrategy: org_eclipse_elk_alg_layered_options_GroupOrderStrategy
    ) -> Int {
        var previousLayerIndex = -1
        var wrongModelOrder = 0

        for layer in layers {
            let previousLayer = previousLayerIndex == -1 ? layers[0] : layers[previousLayerIndex]
            let comp = org_eclipse_elk_alg_layered_intermediate_preserveorder_ModelOrderNodeComparator(
                graph,
                previousLayer,
                strategy,
                .EQUAL,
                cmGroupOrderStrategy,
                false
            )
            if layer.count > 1 {
                for i in 0..<(layer.count - 1) {
                    for j in (i + 1)..<layer.count {
                        if layer[i].hasProperty(org_eclipse_elk_alg_layered_options_InternalProperties.MODEL_ORDER),
                           layer[j].hasProperty(org_eclipse_elk_alg_layered_options_InternalProperties.MODEL_ORDER),
                           comp.compare(layer[i], layer[j]) > 0
                        {
                            wrongModelOrder += 1
                        }
                    }
                }
            }
            previousLayerIndex += 1
        }
        return wrongModelOrder
    }

    package func countModelOrderPortChanges(
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ layers: [[org_eclipse_elk_alg_layered_graph_LNode]],
        _ groupOrderStrategy: org_eclipse_elk_alg_layered_options_GroupOrderStrategy
    ) -> Int {
        _ = groupOrderStrategy
        var previousLayerIndex = -1
        var wrongModelOrder = 0

        for layer in layers {
            let previousLayer = previousLayerIndex == -1 ? layers[0] : layers[previousLayerIndex]
            for node in layer {
                let comp = org_eclipse_elk_alg_layered_intermediate_preserveorder_ModelOrderPortComparator(
                    graph,
                    previousLayer,
                    node.getGraph()?.getProperty(_Keys.considerModelOrderStrategy)
                        as? org_eclipse_elk_alg_layered_options_OrderingStrategy ?? .NODES_AND_EDGES,
                    org_eclipse_elk_alg_layered_intermediate_SortByInputModelProcessor.longEdgeTargetNodePreprocessing(node),
                    node.getGraph()?.getProperty(_Keys.considerModelOrderPortModelOrder) as? Bool ?? false
                )
                let ports = node.getPorts()
                if ports.count > 1 {
                    for i in 0..<(ports.count - 1) {
                        for j in (i + 1)..<ports.count {
                            if comp.compare(ports[i], ports[j]) > 0 {
                                wrongModelOrder += 1
                            }
                        }
                    }
                }
            }
            previousLayerIndex += 1
        }
        return wrongModelOrder
    }

    package func countCurrentNumberOfCrossings(_ currentGraph: org_eclipse_elk_alg_layered_p3order_GraphInfoHolder) -> Int {
        let ownCrossings = currentGraph.crossCounter().countAllCrossings(currentGraph.currentNodeOrder())
        var childCrossings = 0
        for childGraph in currentGraph.childGraphs() {
            guard let child = graphData(for: childGraph), !child.dontSweepInto() else {
                continue
            }
            childCrossings += countCurrentNumberOfCrossings(child)
        }
        let totalCrossings = ownCrossings + childCrossings
        return totalCrossings
    }

    package func countCurrentNumberOfCrossingsNodePortOrder(
        _ currentGraph: org_eclipse_elk_alg_layered_p3order_GraphInfoHolder
    ) -> Double {
        var modelOrderInfluence = 0.0
        let modelOrderStrategy = currentGraph.lGraph().getProperty(_Keys.considerModelOrderStrategy)
            as? org_eclipse_elk_alg_layered_options_OrderingStrategy ?? .NONE
        let cmGroupOrderStrategy = currentGraph.lGraph().getProperty(_Keys.cmGroupOrderStrategy)
            as? org_eclipse_elk_alg_layered_options_GroupOrderStrategy ?? .ONLY_WITHIN_GROUP
        let nodeInfluence = currentGraph.lGraph().getProperty(_Keys.modelOrderCounterNodeInfluence) as? Double ?? 0
        let portInfluence = currentGraph.lGraph().getProperty(_Keys.modelOrderCounterPortInfluence) as? Double ?? 0

        if modelOrderStrategy != .NONE {
            modelOrderInfluence += nodeInfluence * Double(
                countModelOrderNodeChanges(
                    currentGraph.lGraph(),
                    currentGraph.currentNodeOrder(),
                    modelOrderStrategy,
                    cmGroupOrderStrategy
                )
            )
            modelOrderInfluence += portInfluence * Double(
                countModelOrderPortChanges(
                    currentGraph.lGraph(),
                    currentGraph.currentNodeOrder(),
                    cmGroupOrderStrategy
                )
            )
        }

        var totalCrossings = Double(currentGraph.crossCounter().countAllCrossings(currentGraph.currentNodeOrder()))
            + modelOrderInfluence
        for childGraph in currentGraph.childGraphs() {
            guard let child = graphData(for: childGraph), !child.dontSweepInto() else {
                continue
            }
            totalCrossings += Double(countCurrentNumberOfCrossings(child))
        }
        return totalCrossings
    }

    package func sweepReducingCrossings(
        _ graph: org_eclipse_elk_alg_layered_p3order_GraphInfoHolder,
        _ forward: Bool,
        _ firstSweep: Bool
    ) -> Bool {
        let nodes = graph.currentNodeOrder()
        let length = nodes.count
        if length == 0 {
            return false
        }

        var improved = graph.portDistributor().distributePortsWhileSweeping(nodes, firstIndex(forward, length), forward)
        let firstLayer = nodes[firstIndex(forward, length)]
        improved = sweepInHierarchicalNodes(firstLayer, forward, firstSweep) || improved

        var i = firstFree(forward, length)
        while isNotEnd(length, i, forward) {
            let isRandomizingSweep = firstSweep
                && !(graph.lGraph().getProperty(_Keys.firstTryWithInitialOrder) as? Bool ?? false)
                && !(graph.lGraph().getProperty(_Keys.secondTryWithInitialOrder) as? Bool ?? false)
            improved = crossMinimize(graph, i, forward, isRandomizingSweep) || improved
            improved = graph.portDistributor().distributePortsWhileSweeping(graph.currentNodeOrder(), i, forward)
                || improved
            let currentNodes = graph.currentNodeOrder()
            if i >= 0, i < currentNodes.count {
                improved = sweepInHierarchicalNodes(currentNodes[i], forward, firstSweep) || improved
            }
            i += next(forward)
        }

        graphsWhoseNodeOrderChanged.insert(ObjectIdentifier(graph))
        return improved
    }

    package func sweepInHierarchicalNodes(
        _ layer: [org_eclipse_elk_alg_layered_graph_LNode],
        _ isForwardSweep: Bool,
        _ isFirstSweep: Bool
    ) -> Bool {
        var improved = false
        for node in layer where hasNestedGraph(node) {
            guard let nested = node.getNestedGraph(),
                  let nestedData = graphData(for: nested),
                  !nestedData.dontSweepInto()
            else {
                continue
            }
            improved = sweepInHierarchicalNode(isForwardSweep, node, isFirstSweep) || improved
        }
        return improved
    }

    package func sweepInHierarchicalNode(
        _ isForwardSweep: Bool,
        _ node: org_eclipse_elk_alg_layered_graph_LNode,
        _ isFirstSweep: Bool
    ) -> Bool {
        guard let nestedLGraph = node.getNestedGraph(),
              let nestedGraph = graphData(for: nestedLGraph)
        else {
            return false
        }
        let nestedGraphNodeOrder = nestedGraph.currentNodeOrder()
        guard !nestedGraphNodeOrder.isEmpty else {
            return false
        }

        let startIndex = firstIndex(isForwardSweep, nestedGraphNodeOrder.count)
        guard !nestedGraphNodeOrder[startIndex].isEmpty else {
            return false
        }
        let firstNode = nestedGraphNodeOrder[startIndex][0]

        if isExternalPortDummy(firstNode) {
            var updated = nestedGraphNodeOrder
            updated[startIndex] = sortPortDummiesByPortPositions(
                node,
                updated[startIndex],
                sideOpposedSweepDirection(isForwardSweep)
            )
            nestedGraph.setCurrentNodeOrder(updated)
        } else {
            _ = setFirstLayerOrder(nestedGraph, isForwardSweep)
        }

        let improved = sweepReducingCrossings(nestedGraph, isForwardSweep, isFirstSweep)
        sortPortsByDummyPositionsInLastLayer(nestedGraph.currentNodeOrder(), nestedGraph.parent(), isForwardSweep)

        return improved
    }

    package func sortPortsByDummyPositionsInLastLayer(
        _ nodeOrder: [[org_eclipse_elk_alg_layered_graph_LNode]],
        _ parent: org_eclipse_elk_alg_layered_graph_LNode,
        _ onRightMostLayer: Bool
    ) {
        guard !nodeOrder.isEmpty else {
            return
        }
        let lastLayerIndex = endIndex(onRightMostLayer, nodeOrder.count)
        let lastLayer = nodeOrder[lastLayerIndex]
        guard !lastLayer.isEmpty else {
            return
        }

        var dummyIndex = firstIndex(onRightMostLayer, lastLayer.count)
        guard isExternalPortDummy(lastLayer[dummyIndex]) else {
            return
        }

        var reordered = parent.getPorts()
        for i in reordered.indices {
            let port = reordered[i]
            if isOnEndOfSweepSide(port, onRightMostLayer),
               isHierarchical(port),
               dummyIndex >= 0,
               dummyIndex < lastLayer.count,
               let origin = originPort(lastLayer[dummyIndex])
            {
                reordered[i] = origin
                dummyIndex += next(onRightMostLayer)
            }
        }
        parent.ports = reordered
    }

    package func sortPortDummiesByPortPositions(
        _ parentNode: org_eclipse_elk_alg_layered_graph_LNode,
        _ layerCloseToNodeEdge: [org_eclipse_elk_alg_layered_graph_LNode],
        _ side: org_eclipse_elk_core_options_PortSide
    ) -> [org_eclipse_elk_alg_layered_graph_LNode] {
        let ports = orderedPorts(parentNode, side)
        var sortedDummies: [org_eclipse_elk_alg_layered_graph_LNode] = []
        sortedDummies.reserveCapacity(layerCloseToNodeEdge.count)

        for port in ports where isHierarchical(port) {
            if let dummy = dummyNodeFor(port) {
                sortedDummies.append(dummy)
            }
        }

        return Array(sortedDummies.prefix(layerCloseToNodeEdge.count))
    }

    package func saveAllNodeOrdersOfChangedGraphs() {
        for graph in graphInfoHolders where graphsWhoseNodeOrderChanged.contains(ObjectIdentifier(graph)) {
            graph.setBestNodeNPortOrder(
                org_eclipse_elk_alg_layered_p3order_SweepCopy(
                    graph.currentlyBestNodeAndPortOrder()
                        ?? org_eclipse_elk_alg_layered_p3order_SweepCopy(graph.currentNodeOrder())
                )
            )
        }
    }

    package func setCurrentlyBestNodeOrders() {
        for graph in graphInfoHolders where graphsWhoseNodeOrderChanged.contains(ObjectIdentifier(graph)) {
            graph.setCurrentlyBestNodeAndPortOrder(
                org_eclipse_elk_alg_layered_p3order_SweepCopy(graph.currentNodeOrder())
            )
        }
    }

    package func firstIndex(_ isForwardSweep: Bool, _ length: Int) -> Int {
        isForwardSweep ? 0 : (length - 1)
    }

    package func endIndex(_ isForwardSweep: Bool, _ length: Int) -> Int {
        isForwardSweep ? (length - 1) : 0
    }

    package func firstFree(_ isForwardSweep: Bool, _ length: Int) -> Int {
        isForwardSweep ? 1 : (length - 2)
    }

    package func next(_ isForwardSweep: Bool) -> Int {
        isForwardSweep ? 1 : -1
    }

    package func isNotEnd(_ length: Int, _ freeLayerIndex: Int, _ isForwardSweep: Bool) -> Bool {
        if isForwardSweep {
            return freeLayerIndex < length
        }
        return freeLayerIndex >= 0
    }

    package func hasNestedGraph(_ node: org_eclipse_elk_alg_layered_graph_LNode) -> Bool {
        node.getNestedGraph() != nil
    }

    package func sideOpposedSweepDirection(_ isForwardSweep: Bool) -> org_eclipse_elk_core_options_PortSide {
        isForwardSweep ? .WEST : .EAST
    }

    package func isExternalPortDummy(_ firstNode: org_eclipse_elk_alg_layered_graph_LNode) -> Bool {
        firstNode.getType() == .EXTERNAL_PORT
    }

    package func originPort(_ node: org_eclipse_elk_alg_layered_graph_LNode) -> org_eclipse_elk_alg_layered_graph_LPort? {
        node.getProperty(_Keys.origin) as? org_eclipse_elk_alg_layered_graph_LPort
    }

    package func isHierarchical(_ port: org_eclipse_elk_alg_layered_graph_LPort) -> Bool {
        port.getProperty(org_eclipse_elk_alg_layered_options_InternalProperties.INSIDE_CONNECTIONS) as? Bool ?? false
    }

    package func dummyNodeFor(_ port: org_eclipse_elk_alg_layered_graph_LPort) -> org_eclipse_elk_alg_layered_graph_LNode? {
        port.getProperty(org_eclipse_elk_alg_layered_options_InternalProperties.PORT_DUMMY) as? org_eclipse_elk_alg_layered_graph_LNode
    }

    package func isOnEndOfSweepSide(
        _ port: org_eclipse_elk_alg_layered_graph_LPort,
        _ isForwardSweep: Bool
    ) -> Bool {
        if isForwardSweep {
            return port.getSide() == .EAST
        }
        return port.getSide() == .WEST
    }

    package func initialize(
        _ rootGraph: org_eclipse_elk_alg_layered_graph_LGraph
    ) -> [org_eclipse_elk_alg_layered_p3order_GraphInfoHolder] {
        graphInfoHolders = []
        random = rootGraph.getProperty(InternalProperties.RANDOM) as? Random
        randomSeed = Int(random?.nextLong() ?? 0)

        var graphsToSweepOn: [org_eclipse_elk_alg_layered_p3order_GraphInfoHolder] = []
        var graphs: [org_eclipse_elk_alg_layered_graph_LGraph] = [rootGraph]

        var i = 0
        while i < graphs.count {
            let graph = graphs[i]
            graph.id = i
            i += 1

            let graphData = org_eclipse_elk_alg_layered_p3order_GraphInfoHolder(
                graph,
                mapCrossMinType(crossMinType),
                graphInfoHolders,
                crossMinType
            )
            graphs.append(contentsOf: graphData.childGraphs())
            graphInfoHolders.append(graphData)
            let sweep = graphData.dontSweepInto()
            if sweep {
                graphsToSweepOn.insert(graphData, at: 0)
            }
        }

        graphsWhoseNodeOrderChanged.removeAll(keepingCapacity: true)
        return graphsToSweepOn
    }

    package func transferNodeAndPortOrdersToGraph() {
        for holder in graphInfoHolders {
            if let bestSweep = holder.getBestSweep() {
                bestSweep.transferNodeAndPortOrdersToGraph(holder.lGraph(), true)
            }
        }
    }

    package func getLayoutProcessorConfiguration(
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph
    ) -> LayoutProcessorConfiguration<LayeredPhases, LGraph>? {
        _ = graph
        let configuration = LayoutProcessorConfiguration<LayeredPhases, LGraph>.create(
            from: Self.INTERMEDIATE_PROCESSING_CONFIGURATION
        )
        configuration.addBefore(
            org_eclipse_elk_alg_layered_LayeredPhases.P3_NODE_ORDERING,
            org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy.PORT_LIST_SORTER
        )
        return configuration
    }

    package func getGraphData() -> [org_eclipse_elk_alg_layered_p3order_GraphInfoHolder] {
        graphInfoHolders
    }

    package func graphData(for graph: org_eclipse_elk_alg_layered_graph_LGraph)
        -> org_eclipse_elk_alg_layered_p3order_GraphInfoHolder?
    {
        let graphId = graph.id
        guard graphId >= 0, graphId < graphInfoHolders.count else {
            return nil
        }
        return graphInfoHolders[graphId]
    }

    package func mapCrossMinType(
        _ value: org_eclipse_elk_alg_layered_p3order_CrossMinType
    ) -> org_eclipse_elk_alg_layered_p3order_LayerSweepCrossingMinimizer_CrossMinType {
        switch value {
        case .BARYCENTER:
            return .BARYCENTER
        case .MEDIAN:
            return .MEDIAN
        case .ONE_SIDED_GREEDY_SWITCH, .TWO_SIDED_GREEDY_SWITCH:
            return .GREEDY_SWITCH
        }
    }

    package func setFirstLayerOrder(
        _ graph: org_eclipse_elk_alg_layered_p3order_GraphInfoHolder,
        _ forward: Bool
    ) -> Bool {
        var order = graph.currentNodeOrder()
        let improved = graph.crossMinimizer().setFirstLayerOrder(&order, forward)
        graph.setCurrentNodeOrder(order)
        return improved
    }

    package func crossMinimize(
        _ graph: org_eclipse_elk_alg_layered_p3order_GraphInfoHolder,
        _ index: Int,
        _ forward: Bool,
        _ randomize: Bool
    ) -> Bool {
        var order = graph.currentNodeOrder()
        let improved = graph.crossMinimizer().minimizeCrossings(&order, index, forward, randomize)
        graph.setCurrentNodeOrder(order)
        return improved
    }

    package func orderedPorts(
        _ node: org_eclipse_elk_alg_layered_graph_LNode,
        _ side: org_eclipse_elk_core_options_PortSide
    ) -> [org_eclipse_elk_alg_layered_graph_LPort] {
        switch side {
        case .EAST, .NORTH:
            return node.getPortSideView(side)
        case .SOUTH, .WEST:
            return Array(node.getPortSideView(side).reversed())
        case .UNDEFINED:
            return []
        }
    }

    package func nextRandomBool() -> Bool {
        return random?.nextBoolean() ?? true
    }

    /// Read an Int property that might be stored as Double (from JSON parsing).
    private static func _intProperty(_ graph: LGraph, _ key: String) -> Int? {
        if let i = graph.getProperty(key) as? Int { return i }
        if let d = graph.getProperty(key) as? Double { return Int(d) }
        return nil
    }
}
