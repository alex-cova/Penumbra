import Foundation

package class org_eclipse_elk_alg_layered_intermediate_SortByInputModelProcessor {
    package enum _Keys {
        static let portConstraints = "org.eclipse.elk.portConstraints"
        static let considerModelOrderStrategy = "org.eclipse.elk.layered.considerModelOrder.strategy"
        static let considerModelOrderLongEdgeStrategy = "org.eclipse.elk.layered.considerModelOrder.longEdgeStrategy"
        static let considerModelOrderPortModelOrder = "org.eclipse.elk.layered.considerModelOrder.portModelOrder"
        static let longEdgeTargetNode = "longEdgeTargetNode"
        static let targetNodeModelOrder = "targetNode.modelOrder"
    }

    package init() {}

    package func process(
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ progressMonitor: any org_eclipse_elk_core_util_IElkProgressMonitor
    ) {
        let ordering = graph.getProperty(_Keys.considerModelOrderStrategy)
            as? org_eclipse_elk_alg_layered_options_OrderingStrategy ?? .NONE
        progressMonitor.begin("Sort By Input Model \(ordering)", 1)

        // SBIM active for all graphs

        let strategy = ordering
        let longEdgeStrategy = graph.getProperty(_Keys.considerModelOrderLongEdgeStrategy)
            as? org_eclipse_elk_alg_layered_options_LongEdgeOrderingStrategy ?? .EQUAL
        let groupStrategy = graph.getProperty(
            org_eclipse_elk_alg_layered_options_LayeredOptions
                .CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CM_GROUP_ORDER_STRATEGY
        ) as? org_eclipse_elk_alg_layered_options_GroupOrderStrategy ?? .ONLY_WITHIN_GROUP
        let portModelOrder = graph.getProperty(_Keys.considerModelOrderPortModelOrder) as? Bool ?? false

        var layerIndex = 0
        for layer in graph {
            layer.id = layerIndex
            let previousLayerIndex = layerIndex == 0 ? 0 : layerIndex - 1
            let previousLayer = graph.getLayers()[previousLayerIndex]

            var nodes = layer.getNodes()
            let firstComparator = _NodeComparator(
                graph,
                previousLayer,
                strategy,
                longEdgeStrategy,
                groupStrategy,
                true
            )
            Self.insertionSort(&nodes, firstComparator)
            layer.setNodes(nodes)

            for node in layer.getNodes() {
                let constraints = node.getProperty(_Keys.portConstraints) as? org_eclipse_elk_core_options_PortConstraints ?? .UNDEFINED
                if constraints != .FIXED_ORDER && constraints != .FIXED_POS {
                    let targetNodeModelOrder = Self.longEdgeTargetNodePreprocessing(node)
                    var ports = node.getPorts()
                    let portComparator = _PortComparator(
                        graph,
                        previousLayer,
                        strategy,
                        targetNodeModelOrder,
                        portModelOrder
                    )
                    Self.insertionSortPort(&ports, portComparator)
                    node.ports = ports
                }
            }

            nodes = layer.getNodes()
            let secondComparator = _NodeComparator(
                graph,
                previousLayer,
                strategy,
                longEdgeStrategy,
                groupStrategy,
                false
            )
            Self.insertionSort(&nodes, secondComparator)
            layer.setNodes(nodes)

            layerIndex += 1
        }
        progressMonitor.done()
    }

    package static func longEdgeTargetNodePreprocessing(
        _ node: org_eclipse_elk_alg_layered_graph_LNode
    ) -> [ObjectIdentifier: Int] {
        if let existing = node.getProperty(_Keys.targetNodeModelOrder) as? [ObjectIdentifier: Int] {
            return existing
        }

        var targetNodeModelOrder: [ObjectIdentifier: Int] = [:]
        for port in node.getPorts() where !port.getOutgoingEdges().isEmpty {
            let targetNode = Self.getTargetNode(port)
            port.setProperty(_Keys.longEdgeTargetNode, targetNode)

            guard let targetNode else { continue }
            let key = ObjectIdentifier(targetNode)
            let previousOrder = targetNodeModelOrder[key] ?? Int.max
            let edge = port.getOutgoingEdges()[0]
            let reversed = edge.getProperty(org_eclipse_elk_alg_layered_options_InternalProperties.REVERSED) as? Bool ?? false
            guard !reversed else { continue }

            if let modelOrder = edge.getProperty(org_eclipse_elk_alg_layered_options_InternalProperties.MODEL_ORDER) as? Int {
                targetNodeModelOrder[key] = min(previousOrder, modelOrder)
            }
        }

        node.setProperty(_Keys.targetNodeModelOrder, targetNodeModelOrder)
        return targetNodeModelOrder
    }

    package static func getTargetNode(
        _ port: org_eclipse_elk_alg_layered_graph_LPort
    ) -> org_eclipse_elk_alg_layered_graph_LNode? {
        guard !port.getOutgoingEdges().isEmpty else {
            return nil
        }

        var edge = port.getOutgoingEdges()[0]
        var node: org_eclipse_elk_alg_layered_graph_LNode?
        repeat {
            node = edge.getTarget()?.getNode()
            guard let node else { return nil }

            if let longEdgeTargetPort = node.getProperty(org_eclipse_elk_alg_layered_options_InternalProperties.LONG_EDGE_TARGET)
                as? org_eclipse_elk_alg_layered_graph_LPort
            {
                return longEdgeTargetPort.getNode()
            }

            if node.getType() != .normal {
                if let next = node.getOutgoingEdges().first {
                    edge = next
                } else {
                    return nil
                }
            }
        } while node?.getType() != .normal

        return node
    }

    package static func insertionSort(
        _ layer: inout [org_eclipse_elk_alg_layered_graph_LNode],
        _ comparator: _NodeComparator
    ) {
        guard layer.count > 1 else {
            comparator.clearTransitiveOrdering()
            return
        }

        for i in 1..<layer.count {
            let temp = layer[i]
            var j = i
            while j > 0 && comparator.compare(layer[j - 1], temp) > 0 {
                layer[j] = layer[j - 1]
                j -= 1
            }
            layer[j] = temp
        }
        comparator.clearTransitiveOrdering()
    }

    package static func insertionSortPort(
        _ layer: inout [org_eclipse_elk_alg_layered_graph_LPort],
        _ comparator: _PortComparator
    ) {
        guard layer.count > 1 else {
            comparator.clearTransitiveOrdering()
            return
        }

        for i in 1..<layer.count {
            let temp = layer[i]
            var j = i
            while j > 0 && comparator.compare(layer[j - 1], temp) > 0 {
                layer[j] = layer[j - 1]
                j -= 1
            }
            layer[j] = temp
        }
        comparator.clearTransitiveOrdering()
    }

    package final class _NodeComparator {
        package let graph: org_eclipse_elk_alg_layered_graph_LGraph
        package let previousLayer: [org_eclipse_elk_alg_layered_graph_LNode]
        package let orderingStrategy: org_eclipse_elk_alg_layered_options_OrderingStrategy
        package let groupOrderStrategy: org_eclipse_elk_alg_layered_options_GroupOrderStrategy
        package let longEdgeNodeOrder: org_eclipse_elk_alg_layered_options_LongEdgeOrderingStrategy
        package let beforePorts: Bool

        package var biggerThan: [ObjectIdentifier: Set<ObjectIdentifier>] = [:]
        package var smallerThan: [ObjectIdentifier: Set<ObjectIdentifier>] = [:]

        init(
            _ graph: org_eclipse_elk_alg_layered_graph_LGraph,
            _ previousLayer: org_eclipse_elk_alg_layered_graph_Layer,
            _ orderingStrategy: org_eclipse_elk_alg_layered_options_OrderingStrategy,
            _ longEdgeOrderingStrategy: org_eclipse_elk_alg_layered_options_LongEdgeOrderingStrategy,
            _ groupOrderStrategy: org_eclipse_elk_alg_layered_options_GroupOrderStrategy,
            _ beforePorts: Bool
        ) {
            self.graph = graph
            self.previousLayer = previousLayer.getNodes()
            self.orderingStrategy = orderingStrategy
            self.groupOrderStrategy = groupOrderStrategy
            self.longEdgeNodeOrder = longEdgeOrderingStrategy
            self.beforePorts = beforePorts
        }

        package func clearTransitiveOrdering() {
            biggerThan.removeAll()
            smallerThan.removeAll()
        }

        package func compare(
            _ n1: org_eclipse_elk_alg_layered_graph_LNode,
            _ n2: org_eclipse_elk_alg_layered_graph_LNode
        ) -> Int {
            let n1Id = ObjectIdentifier(n1)
            let n2Id = ObjectIdentifier(n2)
            if biggerThan[n1Id] == nil {
                biggerThan[n1Id] = []
            } else if biggerThan[n1Id, default: Set()].contains(n2Id) {
                return 1
            }
            if biggerThan[n2Id] == nil {
                biggerThan[n2Id] = []
            } else if biggerThan[n2Id, default: Set()].contains(n1Id) {
                return -1
            }
            if smallerThan[n1Id] == nil {
                smallerThan[n1Id] = []
            } else if smallerThan[n1Id, default: Set()].contains(n2Id) {
                return -1
            }
            if smallerThan[n2Id] == nil {
                smallerThan[n2Id] = []
            } else if biggerThan[n2Id, default: Set()].contains(n1Id) {
                return 1
            }

            let n1HasModelOrder = n1.hasProperty(org_eclipse_elk_alg_layered_options_InternalProperties.MODEL_ORDER)
            let n2HasModelOrder = n2.hasProperty(org_eclipse_elk_alg_layered_options_InternalProperties.MODEL_ORDER)
            if orderingStrategy == .PREFER_EDGES || !n1HasModelOrder || !n2HasModelOrder {
                let p1SourcePort = sourcePortConnectedToPreviousLayer(of: n1)
                let p2SourcePort = sourcePortConnectedToPreviousLayer(of: n2)


                if let p1SourcePort, let p2SourcePort {
                    let p1Node = p1SourcePort.getNode()
                    let p2Node = p2SourcePort.getNode()
                    if let p1Node, let p2Node, p1Node === p2Node {
                        for port in p1Node.getPorts() {
                            if port === p1SourcePort {
                                updateBiggerAndSmallerAssociations(n2, n1)
                                return -1
                            } else if port === p2SourcePort {
                                updateBiggerAndSmallerAssociations(n1, n2)
                                return 1
                            }
                        }
                        let n1EdgeOrder = getModelOrderFromConnectedEdges(n1)
                        let n2EdgeOrder = getModelOrderFromConnectedEdges(n2)
                        if n1EdgeOrder > n2EdgeOrder {
                            updateBiggerAndSmallerAssociations(n1, n2)
                            return 1
                        } else {
                            updateBiggerAndSmallerAssociations(n2, n1)
                            return -1
                        }
                    }

                    if let p1Node, let p2Node {
                        for previousNode in previousLayer {
                            if previousNode === p1Node {
                                updateBiggerAndSmallerAssociations(n2, n1)
                                return -1
                            } else if previousNode === p2Node {
                                updateBiggerAndSmallerAssociations(n1, n2)
                                return 1
                            }
                        }
                    }
                }

                if (p1SourcePort != nil) != (p2SourcePort != nil) {
                    let helper = handleHelperDummyNodes(n1, n2)
                    if helper != 0 {
                        if helper > 0 {
                            updateBiggerAndSmallerAssociations(n1, n2)
                        } else {
                            updateBiggerAndSmallerAssociations(n2, n1)
                        }
                        return helper
                    }

                    if !n1HasModelOrder || !n2HasModelOrder {
                        let n1ModelOrder = getModelOrderFromConnectedEdges(n1)
                        let n2ModelOrder = getModelOrderFromConnectedEdges(n2)
                        if n1ModelOrder > n2ModelOrder {
                            updateBiggerAndSmallerAssociations(n1, n2)
                            return 1
                        } else {
                            updateBiggerAndSmallerAssociations(n2, n1)
                            return -1
                        }
                    }
                }

                if p1SourcePort == nil && p2SourcePort == nil {
                    let helper = handleHelperDummyNodes(n1, n2)
                    if helper != 0 {
                        if helper > 0 {
                            updateBiggerAndSmallerAssociations(n1, n2)
                        } else {
                            updateBiggerAndSmallerAssociations(n2, n1)
                        }
                        return helper
                    }
                }
            }

            if n1HasModelOrder && n2HasModelOrder {
                let maxModelOrderNodes = graph.getProperty(org_eclipse_elk_alg_layered_options_InternalProperties.MAX_MODEL_ORDER_NODES) as? Int ?? 0
                let n1ModelOrder = org_eclipse_elk_alg_layered_intermediate_preserveorder_CMGroupModelOrderCalculator
                    .calculateModelOrderOrGroupModelOrder(n1, n2, graph, maxModelOrderNodes)
                let n2ModelOrder = org_eclipse_elk_alg_layered_intermediate_preserveorder_CMGroupModelOrderCalculator
                    .calculateModelOrderOrGroupModelOrder(n2, n1, graph, maxModelOrderNodes)
                if groupOrderStrategy == .ONLY_WITHIN_GROUP {
                    if n1ModelOrder > n2ModelOrder {
                        updateBiggerAndSmallerAssociations(n1, n2)
                        return 1
                    } else {
                        updateBiggerAndSmallerAssociations(n2, n1)
                        return -1
                    }
                } else {
                    if n1ModelOrder > n2ModelOrder {
                        updateBiggerAndSmallerAssociations(n1, n2)
                        return 1
                    } else {
                        updateBiggerAndSmallerAssociations(n2, n1)
                        return -1
                    }
                }
            }

            updateBiggerAndSmallerAssociations(n2, n1)
            return -1
        }

        package func sourcePortConnectedToPreviousLayer(
            of node: org_eclipse_elk_alg_layered_graph_LNode
        ) -> org_eclipse_elk_alg_layered_graph_LPort? {
            for p in node.getPorts() where !p.getIncomingEdges().isEmpty {
                let edge = p.getIncomingEdges()[0]
                let sourceLayerId = edge.getSource()?.getNode()?.getLayer()?.id
                let nodeLayerId = node.getLayer()?.id
                if let sourceLayerId, let nodeLayerId, sourceLayerId == (nodeLayerId - 1) {
                    return edge.getSource()
                }
            }
            return nil
        }

        package func getModelOrderFromConnectedEdges(_ n: org_eclipse_elk_alg_layered_graph_LNode) -> Int {
            for sourcePort in n.getPorts() where !sourcePort.getIncomingEdges().isEmpty {
                let edge = sourcePort.getIncomingEdges()[0]
                if let order = edge.getProperty(org_eclipse_elk_alg_layered_options_InternalProperties.MODEL_ORDER) as? Int {
                    return order
                }
            }
            return longEdgeNodeOrder.returnValue()
        }

        package func updateBiggerAndSmallerAssociations(
            _ bigger: org_eclipse_elk_alg_layered_graph_LNode,
            _ smaller: org_eclipse_elk_alg_layered_graph_LNode
        ) {
            let biggerID = ObjectIdentifier(bigger)
            let smallerID = ObjectIdentifier(smaller)
            let biggerNodeBiggerThan = biggerThan[biggerID] ?? []
            let smallerNodeBiggerThan = biggerThan[smallerID] ?? []
            let biggerNodeSmallerThan = smallerThan[biggerID] ?? []
            let smallerNodeSmallerThan = smallerThan[smallerID] ?? []

            var newBiggerNodeBiggerThan = biggerNodeBiggerThan
            newBiggerNodeBiggerThan.insert(smallerID)
            biggerThan[biggerID] = newBiggerNodeBiggerThan

            var newSmallerNodeSmallerThan = smallerNodeSmallerThan
            newSmallerNodeSmallerThan.insert(biggerID)
            smallerThan[smallerID] = newSmallerNodeSmallerThan

            for verySmall in smallerNodeBiggerThan {
                biggerThan[biggerID, default: []].insert(verySmall)
                smallerThan[verySmall, default: []].insert(biggerID)
                smallerThan[verySmall, default: []].formUnion(biggerNodeSmallerThan)
            }

            for veryBig in biggerNodeSmallerThan {
                smallerThan[smallerID, default: []].insert(veryBig)
                biggerThan[veryBig, default: []].insert(smallerID)
                biggerThan[veryBig, default: []].formUnion(smallerNodeBiggerThan)
            }
        }

        package func handleHelperDummyNodes(
            _ n1: org_eclipse_elk_alg_layered_graph_LNode,
            _ n2: org_eclipse_elk_alg_layered_graph_LNode
        ) -> Int {
            if n1.getType() == .longEdge, n2.getType() == .normal {
                guard
                    let dummySourcePort = getFirstIncomingSourcePortOfNode(n1),
                    let dummySourceNode = dummySourcePort.getNode(),
                    let dummyTargetPort = getFirstOutgoingTargetPortOfNode(n1),
                    let dummyTargetNode = dummyTargetPort.getNode(),
                    let dummyLayerId = n1.getLayer()?.id
                else {
                    return 0
                }

                if dummySourceNode.getLayer()?.id != dummyLayerId, dummyTargetNode.getLayer()?.id != dummyLayerId {
                    return 0
                }
                if dummySourceNode === n2 || dummyTargetNode === n2 {
                    updateBiggerAndSmallerAssociations(n1, n2)
                    return 1
                }
                return compare(dummySourceNode, n2)
            } else if n1.getType() == .normal, n2.getType() == .longEdge {
                guard
                    let dummySourcePort = getFirstIncomingSourcePortOfNode(n2),
                    let dummySourceNode = dummySourcePort.getNode(),
                    let dummyTargetPort = getFirstOutgoingTargetPortOfNode(n2),
                    let dummyTargetNode = dummyTargetPort.getNode(),
                    let dummyLayerId = n1.getLayer()?.id
                else {
                    return 0
                }

                if dummySourceNode.getLayer()?.id != dummyLayerId, dummyTargetNode.getLayer()?.id != dummyLayerId {
                    return 0
                }
                if dummySourceNode === n1 || dummyTargetNode === n1 {
                    updateBiggerAndSmallerAssociations(n2, n1)
                    return -1
                }
                return compare(n1, dummySourceNode)
            } else if n1.getType() == .longEdge, n2.getType() == .longEdge {
                if beforePorts {
                    return compareLongEdgeSourcesByModelOrder(n1, n2)
                }

                guard
                    let n1RefNode = getReferenceNodeInCurrentLayer(n1),
                    let n2RefNode = getReferenceNodeInCurrentLayer(n2)
                else {
                    return 0
                }
                return compare(n1RefNode, n2RefNode)
            }
            return 0
        }

        package func getReferenceNodeInCurrentLayer(
            _ dummy: org_eclipse_elk_alg_layered_graph_LNode
        ) -> org_eclipse_elk_alg_layered_graph_LNode? {
            let currentLayerId = dummy.getLayer()?.id
            for edge in dummy.getIncomingEdges() {
                if let sourceNode = edge.getSource()?.getNode(), sourceNode.getLayer()?.id == currentLayerId {
                    return sourceNode
                }
            }
            for edge in dummy.getOutgoingEdges() {
                if let targetNode = edge.getTarget()?.getNode(), targetNode.getLayer()?.id == currentLayerId {
                    return targetNode
                }
            }
            return nil
        }

        package func compareLongEdgeSourcesByModelOrder(
            _ n1: org_eclipse_elk_alg_layered_graph_LNode,
            _ n2: org_eclipse_elk_alg_layered_graph_LNode
        ) -> Int {
            let n1MO = getModelOrderFromConnectedEdges(n1)
            let n2MO = getModelOrderFromConnectedEdges(n2)
            if n1MO > n2MO {
                updateBiggerAndSmallerAssociations(n1, n2)
                return 1
            }
            updateBiggerAndSmallerAssociations(n2, n1)
            return -1
        }

        package func getFirstIncomingSourcePortOfNode(
            _ n: org_eclipse_elk_alg_layered_graph_LNode
        ) -> org_eclipse_elk_alg_layered_graph_LPort? {
            for p in n.getPorts() where !p.getIncomingEdges().isEmpty {
                return p.getIncomingEdges()[0].getSource()
            }
            return nil
        }

        package func getFirstOutgoingTargetPortOfNode(
            _ n: org_eclipse_elk_alg_layered_graph_LNode
        ) -> org_eclipse_elk_alg_layered_graph_LPort? {
            for p in n.getPorts() where !p.getOutgoingEdges().isEmpty {
                return p.getOutgoingEdges()[0].getTarget()
            }
            return nil
        }
    }

    package final class _PortComparator {
        package let graph: org_eclipse_elk_alg_layered_graph_LGraph
        package let previousLayer: [org_eclipse_elk_alg_layered_graph_LNode]
        package let strategy: org_eclipse_elk_alg_layered_options_OrderingStrategy
        package let targetNodeModelOrder: [ObjectIdentifier: Int]
        package let portModelOrder: Bool

        // Transitive ordering maps (matches Java's biggerThan/smallerThan HashMaps)
        package var biggerThan: [ObjectIdentifier: Set<ObjectIdentifier>] = [:]
        package var smallerThan: [ObjectIdentifier: Set<ObjectIdentifier>] = [:]

        init(
            _ graph: org_eclipse_elk_alg_layered_graph_LGraph,
            _ previousLayer: org_eclipse_elk_alg_layered_graph_Layer,
            _ strategy: org_eclipse_elk_alg_layered_options_OrderingStrategy,
            _ targetNodeModelOrder: [ObjectIdentifier: Int],
            _ portModelOrder: Bool
        ) {
            self.graph = graph
            self.previousLayer = previousLayer.getNodes()
            self.strategy = strategy
            self.targetNodeModelOrder = targetNodeModelOrder
            self.portModelOrder = portModelOrder
        }

        package func clearTransitiveOrdering() {
            biggerThan.removeAll()
            smallerThan.removeAll()
        }

        private func updateBiggerAndSmallerAssociations(
            _ biggerOri: org_eclipse_elk_alg_layered_graph_LPort,
            _ smallerOri: org_eclipse_elk_alg_layered_graph_LPort,
            _ reverseOrder: Int
        ) {
            let bigger: org_eclipse_elk_alg_layered_graph_LPort
            let smaller: org_eclipse_elk_alg_layered_graph_LPort
            if reverseOrder < 0 {
                bigger = smallerOri
                smaller = biggerOri
            } else {
                bigger = biggerOri
                smaller = smallerOri
            }
            let biggerID = ObjectIdentifier(bigger)
            let smallerID = ObjectIdentifier(smaller)

            // Ensure entries exist
            if biggerThan[biggerID] == nil { biggerThan[biggerID] = [] }
            if biggerThan[smallerID] == nil { biggerThan[smallerID] = [] }
            if smallerThan[biggerID] == nil { smallerThan[biggerID] = [] }
            if smallerThan[smallerID] == nil { smallerThan[smallerID] = [] }

            biggerThan[biggerID, default: Set()].insert(smallerID)
            smallerThan[smallerID, default: Set()].insert(biggerID)

            // Transitive closure: everything smaller than `smaller` is also smaller than `bigger`
            let smallerNodeBiggerThan = biggerThan[smallerID] ?? []
            let biggerNodeSmallerThan = smallerThan[biggerID] ?? []
            for verySmallID in smallerNodeBiggerThan {
                biggerThan[biggerID, default: Set()].insert(verySmallID)
                smallerThan[verySmallID, default: Set()].insert(biggerID)
                smallerThan[verySmallID, default: Set()].formUnion(biggerNodeSmallerThan)
            }

            // Transitive closure: everything bigger than `bigger` is also bigger than `smaller`
            let smallerNodeBiggerThan2 = biggerThan[smallerID] ?? []
            for veryBigID in biggerNodeSmallerThan {
                smallerThan[smallerID, default: Set()].insert(veryBigID)
                biggerThan[veryBigID, default: Set()].insert(smallerID)
                biggerThan[veryBigID, default: Set()].formUnion(smallerNodeBiggerThan2)
            }
        }

        private func checkReferenceLayer(
            _ layer: [org_eclipse_elk_alg_layered_graph_LNode],
            _ p1Node: org_eclipse_elk_alg_layered_graph_LNode,
            _ p2Node: org_eclipse_elk_alg_layered_graph_LNode,
            _ p1: org_eclipse_elk_alg_layered_graph_LPort,
            _ p2: org_eclipse_elk_alg_layered_graph_LPort
        ) -> Int {
            for node in layer {
                if node === p1Node {
                    return -1
                } else if node === p2Node {
                    return 1
                }
            }
            return 0
        }

        package func compare(
            _ p1: org_eclipse_elk_alg_layered_graph_LPort,
            _ p2: org_eclipse_elk_alg_layered_graph_LPort
        ) -> Int {
            let p1ID = ObjectIdentifier(p1)
            let p2ID = ObjectIdentifier(p2)

            // Check transitive ordering first (Java lines 106-125)
            if biggerThan[p1ID] == nil {
                biggerThan[p1ID] = []
            } else if biggerThan[p1ID, default: Set()].contains(p2ID) {
                return 1
            }
            if biggerThan[p2ID] == nil {
                biggerThan[p2ID] = []
            } else if biggerThan[p2ID, default: Set()].contains(p1ID) {
                return -1
            }
            if smallerThan[p1ID] == nil {
                smallerThan[p1ID] = []
            } else if smallerThan[p1ID, default: Set()].contains(p2ID) {
                return -1
            }
            if smallerThan[p2ID] == nil {
                smallerThan[p2ID] = []
            } else if biggerThan[p2ID, default: Set()].contains(p1ID) {
                return 1
            }

            // Sort by port side NORTH < EAST < SOUTH < WEST
            if p1.getSide() != p2.getSide() {
                let result = sideOrdinal(p1.getSide()) - sideOrdinal(p2.getSide())
                if result > 0 {
                    updateBiggerAndSmallerAssociations(p1, p2, 1)
                } else {
                    updateBiggerAndSmallerAssociations(p2, p1, 1)
                }
                return result
            }
            var reverseOrder = 1

            // Sort incoming edges by the order of source nodes in the previous layer
            if !p1.getIncomingEdges().isEmpty, !p2.getIncomingEdges().isEmpty {
                if (p1.getSide() == .WEST && p2.getSide() == .WEST)
                    || (p1.getSide() == .NORTH && p2.getSide() == .NORTH)
                    || (p1.getSide() == .SOUTH && p2.getSide() == .SOUTH)
                {
                    reverseOrder = -reverseOrder
                }

                let p1SourcePort = p1.getIncomingEdges()[0].getSource()
                let p2SourcePort = p2.getIncomingEdges()[0].getSource()
                let p1Node = p1SourcePort?.getNode()
                let p2Node = p2SourcePort?.getNode()

                // If both connect to the same node, check port occurrence order
                if let p1Node, let p2Node, p1Node === p2Node {
                    for port in p1Node.getPorts() {
                        if port === p1SourcePort {
                            updateBiggerAndSmallerAssociations(p2, p1, reverseOrder)
                            return -reverseOrder
                        } else if port === p2SourcePort {
                            updateBiggerAndSmallerAssociations(p1, p2, reverseOrder)
                            return reverseOrder
                        }
                    }
                }

                // If both connect to long edges in the same layer (Java lines 166-193)
                if let p1Node, let p2Node,
                   p1SourcePort?.getNode()?.getType() == .LONG_EDGE,
                   p2SourcePort?.getNode()?.getType() == .LONG_EDGE,
                   p1Node.getLayer()?.id == p2Node.getLayer()?.id,
                   p1Node.getLayer()?.id == p1.getNode()?.getLayer()?.id
                {
                    let sameLayerNodes = p1Node.getLayer()?.getNodes() ?? []
                    let inPreviousLayer = checkReferenceLayer(sameLayerNodes, p1Node, p2Node, p1, p2)
                    if inPreviousLayer != 0 {
                        var localReverse = reverseOrder
                        if p1.getSide() == .EAST && p2.getSide() == .EAST {
                            localReverse = -localReverse
                        }
                        if inPreviousLayer > 0 {
                            updateBiggerAndSmallerAssociations(p1, p2, localReverse)
                            return localReverse
                        } else {
                            updateBiggerAndSmallerAssociations(p2, p1, localReverse)
                            return -localReverse
                        }
                    }
                }

                // Check which node appears first in the previous layer
                if let p1Node, let p2Node {
                    let inPreviousLayer = checkReferenceLayer(previousLayer, p1Node, p2Node, p1, p2)
                    if inPreviousLayer != 0 {
                        if inPreviousLayer > 0 {
                            updateBiggerAndSmallerAssociations(p1, p2, reverseOrder)
                            return reverseOrder
                        } else {
                            updateBiggerAndSmallerAssociations(p2, p1, reverseOrder)
                            return -reverseOrder
                        }
                    }
                }

                if portModelOrder {
                    let result = compareByPortModelOrder(p1, p2)
                    if result != 0 {
                        if result > 0 {
                            updateBiggerAndSmallerAssociations(p1, p2, reverseOrder)
                            return reverseOrder
                        } else {
                            updateBiggerAndSmallerAssociations(p2, p1, reverseOrder)
                            return -reverseOrder
                        }
                    }
                }
            }

            // Sort outgoing edges by model order
            if !p1.getOutgoingEdges().isEmpty, !p2.getOutgoingEdges().isEmpty {
                if (p1.getSide() == .WEST && p2.getSide() == .WEST)
                    || (p1.getSide() == .SOUTH && p2.getSide() == .SOUTH)
                {
                    reverseOrder = -reverseOrder
                }

                let p1TargetNode = p1.getProperty(_Keys.longEdgeTargetNode) as? org_eclipse_elk_alg_layered_graph_LNode
                let p2TargetNode = p2.getProperty(_Keys.longEdgeTargetNode) as? org_eclipse_elk_alg_layered_graph_LNode

                if strategy == .PREFER_NODES,
                   let p1TargetNode, let p2TargetNode,
                   p1TargetNode.hasProperty(org_eclipse_elk_alg_layered_options_InternalProperties.MODEL_ORDER),
                   p2TargetNode.hasProperty(org_eclipse_elk_alg_layered_options_InternalProperties.MODEL_ORDER)
                {
                    let maxModelOrderNodes = graph.getProperty(org_eclipse_elk_alg_layered_options_InternalProperties.MAX_MODEL_ORDER_NODES) as? Int ?? 0
                    let p1MO = org_eclipse_elk_alg_layered_intermediate_preserveorder_CMGroupModelOrderCalculator
                        .calculateModelOrderOrGroupModelOrder(p1TargetNode, p2TargetNode, graph, maxModelOrderNodes)
                    let p2MO = org_eclipse_elk_alg_layered_intermediate_preserveorder_CMGroupModelOrderCalculator
                        .calculateModelOrderOrGroupModelOrder(p2TargetNode, p1TargetNode, graph, maxModelOrderNodes)
                    if p1MO > p2MO {
                        updateBiggerAndSmallerAssociations(p1, p2, reverseOrder)
                        return reverseOrder
                    } else {
                        updateBiggerAndSmallerAssociations(p2, p1, reverseOrder)
                        return -reverseOrder
                    }
                }

                if portModelOrder {
                    let result = compareByPortModelOrder(p1, p2)
                    if result != 0 {
                        if result > 0 {
                            updateBiggerAndSmallerAssociations(p1, p2, reverseOrder)
                            return reverseOrder
                        } else {
                            updateBiggerAndSmallerAssociations(p2, p1, reverseOrder)
                            return -reverseOrder
                        }
                    }
                }

                var p1Order = 0
                var p2Order = 0
                if p1.getOutgoingEdges()[0].hasProperty(org_eclipse_elk_alg_layered_options_InternalProperties.MODEL_ORDER) {
                    let firstEdge = p1.getOutgoingEdges()[0]
                    let secondEdge = p2.getOutgoingEdges()[0]
                    p1Order = org_eclipse_elk_alg_layered_intermediate_preserveorder_CMGroupModelOrderCalculator
                        .calculateModelOrderOrGroupModelOrder(firstEdge, secondEdge, graph, p1.getOutgoingEdges().count + p1.getIncomingEdges().count)
                }
                if p2.getOutgoingEdges()[0].hasProperty(org_eclipse_elk_alg_layered_options_InternalProperties.MODEL_ORDER) {
                    let firstEdge = p2.getOutgoingEdges()[0]
                    let secondEdge = p1.getOutgoingEdges()[0]
                    p2Order = org_eclipse_elk_alg_layered_intermediate_preserveorder_CMGroupModelOrderCalculator
                        .calculateModelOrderOrGroupModelOrder(firstEdge, secondEdge, graph, p2.getOutgoingEdges().count + p2.getIncomingEdges().count)
                }

                if let p1TargetNode, let p2TargetNode, p1TargetNode === p2TargetNode {
                    if p1Order > p2Order {
                        updateBiggerAndSmallerAssociations(p1, p2, reverseOrder)
                        return reverseOrder
                    } else {
                        updateBiggerAndSmallerAssociations(p2, p1, reverseOrder)
                        return -reverseOrder
                    }
                }

                if let p1TargetNode {
                    p1Order = targetNodeModelOrder[ObjectIdentifier(p1TargetNode)] ?? p1Order
                }
                if let p2TargetNode {
                    p2Order = targetNodeModelOrder[ObjectIdentifier(p2TargetNode)] ?? p2Order
                }
                if p1Order > p2Order {
                    updateBiggerAndSmallerAssociations(p1, p2, reverseOrder)
                    return reverseOrder
                } else {
                    updateBiggerAndSmallerAssociations(p2, p1, reverseOrder)
                    return -reverseOrder
                }
            }

            // Sort outgoing ports before incoming ports
            if !p1.getIncomingEdges().isEmpty, !p2.getOutgoingEdges().isEmpty {
                updateBiggerAndSmallerAssociations(p1, p2, reverseOrder)
                return 1
            } else if !p1.getOutgoingEdges().isEmpty, !p2.getIncomingEdges().isEmpty {
                updateBiggerAndSmallerAssociations(p2, p1, reverseOrder)
                return -1
            } else if p1.hasProperty(org_eclipse_elk_alg_layered_options_InternalProperties.MODEL_ORDER),
                      p2.hasProperty(org_eclipse_elk_alg_layered_options_InternalProperties.MODEL_ORDER)
            {
                let numberOfPorts = p1.getNode()?.getPorts().count ?? 0
                let p1MO = org_eclipse_elk_alg_layered_intermediate_preserveorder_CMGroupModelOrderCalculator
                    .calculateModelOrderOrGroupModelOrder(p1, p2, graph, numberOfPorts)
                let p2MO = org_eclipse_elk_alg_layered_intermediate_preserveorder_CMGroupModelOrderCalculator
                    .calculateModelOrderOrGroupModelOrder(p2, p1, graph, numberOfPorts)
                if (p1.getSide() == .WEST && p2.getSide() == .WEST)
                    || (p1.getSide() == .SOUTH && p2.getSide() == .SOUTH)
                {
                    reverseOrder = -reverseOrder
                }
                if p1MO > p2MO {
                    updateBiggerAndSmallerAssociations(p1, p2, reverseOrder)
                    return reverseOrder
                } else {
                    updateBiggerAndSmallerAssociations(p2, p1, reverseOrder)
                    return -reverseOrder
                }
            } else {
                updateBiggerAndSmallerAssociations(p2, p1, reverseOrder)
                return -reverseOrder
            }
        }

        package func compareByPortModelOrder(
            _ p1: org_eclipse_elk_alg_layered_graph_LPort,
            _ p2: org_eclipse_elk_alg_layered_graph_LPort
        ) -> Int {
            let numberOfPorts = p1.getNode()?.getPorts().count ?? 0
            if p1.hasProperty(org_eclipse_elk_alg_layered_options_InternalProperties.MODEL_ORDER),
               p2.hasProperty(org_eclipse_elk_alg_layered_options_InternalProperties.MODEL_ORDER)
            {
                let p1MO = org_eclipse_elk_alg_layered_intermediate_preserveorder_CMGroupModelOrderCalculator
                    .calculateModelOrderOrGroupModelOrder(p1, p2, graph, numberOfPorts)
                let p2MO = org_eclipse_elk_alg_layered_intermediate_preserveorder_CMGroupModelOrderCalculator
                    .calculateModelOrderOrGroupModelOrder(p2, p1, graph, numberOfPorts)
                if p1MO == p2MO { return 0 }
                return p1MO > p2MO ? 1 : -1
            }
            return 0
        }

        package func sideOrdinal(_ side: org_eclipse_elk_core_options_PortSide) -> Int {
            switch side {
            case .UNDEFINED:
                return 0
            case .NORTH:
                return 1
            case .EAST:
                return 2
            case .SOUTH:
                return 3
            case .WEST:
                return 4
            }
        }
    }
}
