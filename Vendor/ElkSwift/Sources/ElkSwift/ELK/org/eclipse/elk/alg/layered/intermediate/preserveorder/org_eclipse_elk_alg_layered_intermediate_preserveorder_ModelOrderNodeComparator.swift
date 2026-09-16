// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/preserveorder/ModelOrderNodeComparator.java
import Foundation

package class org_eclipse_elk_alg_layered_intermediate_preserveorder_ModelOrderNodeComparator {
    package var previousLayer: [LNode] = []
    package var graph: LGraph
    package let orderingStrategy: OrderingStrategy
    package let groupOrderStrategy: GroupOrderStrategy

    // Transitive ordering cache: node -> nodes that must come before/after it.
    package var biggerThan: [ObjectIdentifier: Set<ObjectIdentifier>] = [:]
    package var smallerThan: [ObjectIdentifier: Set<ObjectIdentifier>] = [:]

    package var longEdgeNodeOrder: LongEdgeOrderingStrategy = .EQUAL
    package var beforePorts: Bool

    package convenience init(
        _ graph: LGraph,
        _ thePreviousLayer: Layer,
        _ orderingStrategy: OrderingStrategy,
        _ longEdgeOrderingStrategy: LongEdgeOrderingStrategy,
        _ groupOrderStrategy: GroupOrderStrategy,
        _ beforePorts: Bool
    ) {
        self.init(graph, orderingStrategy, longEdgeOrderingStrategy, groupOrderStrategy, beforePorts)
        self.previousLayer = thePreviousLayer.getNodes()
    }

    package convenience init(
        _ graph: LGraph,
        _ previousLayer: [LNode],
        _ orderingStrategy: OrderingStrategy,
        _ longEdgeOrderingStrategy: LongEdgeOrderingStrategy,
        _ groupOrderStrategy: GroupOrderStrategy,
        _ beforePorts: Bool
    ) {
        self.init(graph, orderingStrategy, longEdgeOrderingStrategy, groupOrderStrategy, beforePorts)
        self.previousLayer = previousLayer
    }

    private init(
        _ graph: LGraph,
        _ orderingStrategy: OrderingStrategy,
        _ longEdgeOrderingStrategy: LongEdgeOrderingStrategy,
        _ groupOrderStrategy: GroupOrderStrategy,
        _ beforePorts: Bool
    ) {
        self.graph = graph
        self.orderingStrategy = orderingStrategy
        self.groupOrderStrategy = groupOrderStrategy
        self.longEdgeNodeOrder = longEdgeOrderingStrategy
        self.beforePorts = beforePorts
    }

    package func compare(
        _ n1: LNode,
        _ n2: LNode
    ) -> Int {
        ensureNodeInMaps(n1)
        ensureNodeInMaps(n2)

        if biggerThan[id(n1), default: []].contains(id(n2)) {
            return 1
        }
        if biggerThan[id(n2), default: []].contains(id(n1)) {
            return -1
        }
        if smallerThan[id(n1), default: []].contains(id(n2)) {
            return -1
        }
        // Java implementation checks biggerThan(n2) here; keep behavior identical.
        if biggerThan[id(n2), default: []].contains(id(n1)) {
            return 1
        }

        if orderingStrategy == .PREFER_EDGES
            || !n1.hasProperty(InternalProperties.MODEL_ORDER)
            || !n2.hasProperty(InternalProperties.MODEL_ORDER)
        {
            var p1SourcePort: LPort?
            for p in n1.getPorts() {
                let incoming = p.getIncomingEdges()
                if !incoming.isEmpty,
                   let sourceNodeLayerId = incoming[0].getSource()?.getNode()?.getLayer()?.id,
                   let n1LayerId = n1.getLayer()?.id,
                   sourceNodeLayerId == n1LayerId - 1
                {
                    p1SourcePort = incoming[0].getSource()
                    break
                }
            }

            var p2SourcePort: LPort?
            for p in n2.getPorts() {
                let incoming = p.getIncomingEdges()
                if !incoming.isEmpty,
                   let sourceNodeLayerId = incoming[0].getSource()?.getNode()?.getLayer()?.id,
                   let n2LayerId = n2.getLayer()?.id,
                   sourceNodeLayerId == n2LayerId - 1
                {
                    p2SourcePort = incoming[0].getSource()
                    break
                }
            }

            if let p1SourcePort, let p2SourcePort,
               let p1Node = p1SourcePort.getNode(), let p2Node = p2SourcePort.getNode()
            {
                if p1Node === p2Node {
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
                    }
                    updateBiggerAndSmallerAssociations(n2, n1)
                    return -1
                }

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

            if (p1SourcePort != nil && p2SourcePort == nil) || (p1SourcePort == nil && p2SourcePort != nil) {
                let comparedWithLongEdgeFeedback = handleHelperDummyNodes(n1, n2)
                if comparedWithLongEdgeFeedback != 0 {
                    if comparedWithLongEdgeFeedback > 0 {
                        updateBiggerAndSmallerAssociations(n1, n2)
                    } else {
                        updateBiggerAndSmallerAssociations(n2, n1)
                    }
                    return comparedWithLongEdgeFeedback
                }

                if !n1.hasProperty(InternalProperties.MODEL_ORDER)
                    || !n2.hasProperty(InternalProperties.MODEL_ORDER)
                {
                    let n1ModelOrder = getModelOrderFromConnectedEdges(n1)
                    let n2ModelOrder = getModelOrderFromConnectedEdges(n2)
                    if n1ModelOrder > n2ModelOrder {
                        updateBiggerAndSmallerAssociations(n1, n2)
                        return 1
                    }
                    updateBiggerAndSmallerAssociations(n2, n1)
                    return -1
                }
            }

            if p1SourcePort == nil && p2SourcePort == nil {
                let comparedWithLongEdgeFeedback = handleHelperDummyNodes(n1, n2)
                if comparedWithLongEdgeFeedback != 0 {
                    if comparedWithLongEdgeFeedback > 0 {
                        updateBiggerAndSmallerAssociations(n1, n2)
                    } else {
                        updateBiggerAndSmallerAssociations(n2, n1)
                    }
                    return comparedWithLongEdgeFeedback
                }
            }
        }

        if n1.hasProperty(InternalProperties.MODEL_ORDER),
           n2.hasProperty(InternalProperties.MODEL_ORDER)
        {
            let maxModelOrder = graph.getProperty(InternalProperties.MAX_MODEL_ORDER_NODES) as? Int ?? 0
            let n1ModelOrder = org_eclipse_elk_alg_layered_intermediate_preserveorder_CMGroupModelOrderCalculator
                .calculateModelOrderOrGroupModelOrder(n1, n2, graph, maxModelOrder)
            let n2ModelOrder = org_eclipse_elk_alg_layered_intermediate_preserveorder_CMGroupModelOrderCalculator
                .calculateModelOrderOrGroupModelOrder(n2, n1, graph, maxModelOrder)
            if n1ModelOrder > n2ModelOrder {
                updateBiggerAndSmallerAssociations(n1, n2)
                return 1
            }
            updateBiggerAndSmallerAssociations(n2, n1)
            return -1
        }

        updateBiggerAndSmallerAssociations(n2, n1)
        return -1
    }

    package func getModelOrderFromConnectedEdges(_ n: LNode) -> Int {
        let sourcePort = n.getPorts().first { !$0.getIncomingEdges().isEmpty }
        if let sourcePort {
            let incoming = sourcePort.getIncomingEdges()
            if !incoming.isEmpty {
                if let modelOrder = incoming[0].getProperty(InternalProperties.MODEL_ORDER) as? Int {
                    return modelOrder
                }
            }
        }
        return longEdgeNodeOrder.returnValue()
    }

    package func updateBiggerAndSmallerAssociations(
        _ bigger: LNode,
        _ smaller: LNode
    ) {
        ensureNodeInMaps(bigger)
        ensureNodeInMaps(smaller)

        let biggerId = id(bigger)
        let smallerId = id(smaller)

        var biggerNodeBiggerThan = biggerThan[biggerId, default: []]
        let smallerNodeBiggerThan = biggerThan[smallerId, default: []]
        let biggerNodeSmallerThan = smallerThan[biggerId, default: []]
        var smallerNodeSmallerThan = smallerThan[smallerId, default: []]

        biggerNodeBiggerThan.insert(smallerId)
        smallerNodeSmallerThan.insert(biggerId)

        for verySmall in smallerNodeBiggerThan {
            biggerNodeBiggerThan.insert(verySmall)
            var verySmallSmaller = smallerThan[verySmall, default: []]
            verySmallSmaller.insert(biggerId)
            verySmallSmaller.formUnion(biggerNodeSmallerThan)
            smallerThan[verySmall] = verySmallSmaller
        }

        for veryBig in biggerNodeSmallerThan {
            smallerNodeSmallerThan.insert(veryBig)
            var veryBigBigger = biggerThan[veryBig, default: []]
            veryBigBigger.insert(smallerId)
            veryBigBigger.formUnion(smallerNodeBiggerThan)
            biggerThan[veryBig] = veryBigBigger
        }

        biggerThan[biggerId] = biggerNodeBiggerThan
        biggerThan[smallerId] = smallerNodeBiggerThan
        smallerThan[biggerId] = biggerNodeSmallerThan
        smallerThan[smallerId] = smallerNodeSmallerThan
    }

    package func handleHelperDummyNodes(
        _ n1: LNode,
        _ n2: LNode
    ) -> Int {
        if n1.getType() == .LONG_EDGE && n2.getType() == .NORMAL {
            guard let dummyNodeSourcePort = getFirstIncomingSourcePortOfNode(n1),
                  let dummyNodeSourceNode = dummyNodeSourcePort.getNode(),
                  let dummyNodeTargetPort = getFirstOutgoingTargetPortOfNode(n1),
                  let dummyNodeTargetNode = dummyNodeTargetPort.getNode(),
                  let dummyLayerId = n1.getLayer()?.id
            else {
                return 0
            }

            let sourceInLayer = dummyNodeSourceNode.getLayer()?.id == dummyLayerId
            let targetInLayer = dummyNodeTargetNode.getLayer()?.id == dummyLayerId
            if !sourceInLayer && !targetInLayer {
                return 0
            }
            if dummyNodeSourceNode === n2 {
                updateBiggerAndSmallerAssociations(n1, n2)
                return 1
            }
            if dummyNodeTargetNode === n2 {
                updateBiggerAndSmallerAssociations(n1, n2)
                return 1
            }
            return compare(dummyNodeSourceNode, n2)
        } else if n1.getType() == .NORMAL && n2.getType() == .LONG_EDGE {
            guard let dummyNodeSourcePort = getFirstIncomingSourcePortOfNode(n2),
                  let dummyNodeSourceNode = dummyNodeSourcePort.getNode(),
                  let dummyNodeTargetPort = getFirstOutgoingTargetPortOfNode(n2),
                  let dummyNodeTargetNode = dummyNodeTargetPort.getNode(),
                  let dummyLayerId = n1.getLayer()?.id
            else {
                return 0
            }

            let sourceInLayer = dummyNodeSourceNode.getLayer()?.id == dummyLayerId
            let targetInLayer = dummyNodeTargetNode.getLayer()?.id == dummyLayerId
            if !sourceInLayer && !targetInLayer {
                return 0
            }
            if dummyNodeSourceNode === n1 {
                updateBiggerAndSmallerAssociations(n2, n1)
                return -1
            }
            if dummyNodeTargetNode === n1 {
                updateBiggerAndSmallerAssociations(n2, n1)
                return -1
            }
            return compare(n1, dummyNodeSourceNode)
        } else if n1.getType() == .LONG_EDGE && n2.getType() == .LONG_EDGE {
            guard let n1dummyNodeSourcePort = getFirstIncomingSourcePortOfNode(n1),
                  let n1dummyNodeTargetPort = getFirstOutgoingTargetPortOfNode(n1),
                  let n1dummySourceNode = n1dummyNodeSourcePort.getNode(),
                  let n1dummyTargetNode = n1dummyNodeTargetPort.getNode(),
                  let n1LayerId = n1.getLayer()?.id,
                  let n2dummyNodeSourcePort = getFirstIncomingSourcePortOfNode(n2),
                  let n2dummyNodeTargetPort = getFirstOutgoingTargetPortOfNode(n2),
                  let n2dummySourceNode = n2dummyNodeSourcePort.getNode(),
                  let n2dummyTargetNode = n2dummyNodeTargetPort.getNode(),
                  let n2LayerId = n2.getLayer()?.id
            else {
                return 0
            }

            var n1SourceFeedbackNode = false
            var n1TargetFeedbackNode = false
            var n2SourceFeedbackNode = false
            var n2TargetFeedbackNode = false

            var n1ReferenceNode = n1
            var n2ReferenceNode = n2

            if n1dummySourceNode.getLayer()?.id == n1LayerId {
                n1SourceFeedbackNode = true
                n1ReferenceNode = n1dummySourceNode
            } else if n1dummyTargetNode.getLayer()?.id == n1LayerId {
                n1TargetFeedbackNode = true
                n1ReferenceNode = n1dummyTargetNode
            }

            if n2dummySourceNode.getLayer()?.id == n2LayerId {
                n2SourceFeedbackNode = true
                n2ReferenceNode = n2dummySourceNode
            } else if n2dummyTargetNode.getLayer()?.id == n2LayerId {
                n2TargetFeedbackNode = true
                n2ReferenceNode = n2dummyTargetNode
            }

            if n1ReferenceNode === n2ReferenceNode {
                if beforePorts {
                    if n1SourceFeedbackNode && n2SourceFeedbackNode {
                        let returnValue = org_eclipse_elk_alg_layered_intermediate_preserveorder_ModelOrderPortComparator(
                            graph,
                            previousLayer,
                            orderingStrategy,
                            nil,
                            n2TargetFeedbackNode
                        ).compare(n1dummyNodeSourcePort, n2dummyNodeSourcePort)
                        if returnValue > 0 {
                            updateBiggerAndSmallerAssociations(n2, n1)
                            return 1
                        }
                        updateBiggerAndSmallerAssociations(n1, n2)
                        return -1
                    } else if n1SourceFeedbackNode && n2TargetFeedbackNode {
                        updateBiggerAndSmallerAssociations(n2, n1)
                        return 1
                    } else if n1TargetFeedbackNode && n2SourceFeedbackNode {
                        updateBiggerAndSmallerAssociations(n1, n2)
                        return -1
                    } else if n1TargetFeedbackNode && n2TargetFeedbackNode {
                        return 0
                    }
                } else {
                    for port in n1ReferenceNode.getPorts() {
                        if n1dummyNodeSourcePort === port {
                            updateBiggerAndSmallerAssociations(n2, n1)
                            return -1
                        } else if n2dummyNodeSourcePort === port {
                            updateBiggerAndSmallerAssociations(n1, n2)
                            return 1
                        }
                    }
                }
            }

            return compare(n1ReferenceNode, n2ReferenceNode)
        }

        return 0
    }

    package func getFirstIncomingPortOfNode(
        _ node: LNode
    ) -> LPort? {
        node.getPorts().first { !$0.getIncomingEdges().isEmpty }
    }

    package func getFirstIncomingSourcePortOfNode(
        _ node: LNode
    ) -> LPort? {
        guard let incomingPort = getFirstIncomingPortOfNode(node) else {
            return nil
        }
        let incoming = incomingPort.getIncomingEdges()
        return incoming.isEmpty ? nil : incoming[0].getSource()
    }

    package func getFirstOutgoingPortOfNode(
        _ node: LNode
    ) -> LPort? {
        node.getPorts().first { !$0.getOutgoingEdges().isEmpty }
    }

    package func getFirstOutgoingTargetPortOfNode(
        _ node: LNode
    ) -> LPort? {
        guard let outgoingPort = getFirstOutgoingPortOfNode(node) else {
            return nil
        }
        let outgoing = outgoingPort.getOutgoingEdges()
        return outgoing.isEmpty ? nil : outgoing[0].getTarget()
    }

    package func clearTransitiveOrdering() {
        biggerThan = [:]
        smallerThan = [:]
    }

    package func id(_ node: LNode) -> ObjectIdentifier {
        ObjectIdentifier(node)
    }

    package func ensureNodeInMaps(_ node: LNode) {
        let nodeId = id(node)
        if biggerThan[nodeId] == nil {
            biggerThan[nodeId] = []
        }
        if smallerThan[nodeId] == nil {
            smallerThan[nodeId] = []
        }
    }
}
