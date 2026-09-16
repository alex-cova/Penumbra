// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/greedyswitch/SwitchDecider.java
import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_greedyswitch_SwitchDecider {

    package enum CrossingCountSide {
        case WEST
        case EAST
    }

    // In Java, LNode[] freeLayer is a reference to the same array object in the graph.
    // When GreedySwitchHeuristic.exchangeNodes swaps entries, the SwitchDecider sees the
    // update. In Swift, [LNode] is a value type (snapshot). We make it mutable and
    // expose notifyOfSwitch to update it when nodes are exchanged.
    private var freeLayer: [LNode]
    private let leftInLayerCounter: org_eclipse_elk_alg_layered_p3order_counting_CrossingsCounter
    private let rightInLayerCounter: org_eclipse_elk_alg_layered_p3order_counting_CrossingsCounter
    private let northSouthCounter: org_eclipse_elk_alg_layered_intermediate_greedyswitch_NorthSouthEdgeNeighbouringNodeCrossingsCounter
    private let crossingMatrixFiller: org_eclipse_elk_alg_layered_intermediate_greedyswitch_CrossingMatrixFiller
    private let graphData: org_eclipse_elk_alg_layered_p3order_GraphInfoHolder
    private var parentCrossCounter: org_eclipse_elk_alg_layered_p3order_counting_CrossingsCounter?
    private let countCrossingsCausedByPortSwitch: Bool

    package init(
        _ freeLayerIndex: Int,
        _ graph: [[LNode]],
        _ crossingMatrixFiller: org_eclipse_elk_alg_layered_intermediate_greedyswitch_CrossingMatrixFiller,
        _ portPositions: SharedIntArray,
        _ graphData: org_eclipse_elk_alg_layered_p3order_GraphInfoHolder,
        _ oneSided: Bool
    ) {
        self.crossingMatrixFiller = crossingMatrixFiller
        self.graphData = graphData

        guard freeLayerIndex < graph.count else {
            assertionFailure("Greedy SwitchDecider: Free layer not in graph.")
            freeLayer = []
            leftInLayerCounter = org_eclipse_elk_alg_layered_p3order_counting_CrossingsCounter(portPositions)
            rightInLayerCounter = org_eclipse_elk_alg_layered_p3order_counting_CrossingsCounter(portPositions)
            northSouthCounter = org_eclipse_elk_alg_layered_intermediate_greedyswitch_NorthSouthEdgeNeighbouringNodeCrossingsCounter([])
            countCrossingsCausedByPortSwitch = false
            return
        }
        freeLayer = graph[freeLayerIndex]

        leftInLayerCounter = org_eclipse_elk_alg_layered_p3order_counting_CrossingsCounter(portPositions)
        leftInLayerCounter.initPortPositionsForInLayerCrossings(freeLayer, .WEST)
        rightInLayerCounter = org_eclipse_elk_alg_layered_p3order_counting_CrossingsCounter(portPositions)
        rightInLayerCounter.initPortPositionsForInLayerCrossings(freeLayer, .EAST)
        northSouthCounter = org_eclipse_elk_alg_layered_intermediate_greedyswitch_NorthSouthEdgeNeighbouringNodeCrossingsCounter(freeLayer)

        countCrossingsCausedByPortSwitch = !oneSided && graphData.hasParent() && !graphData.dontSweepInto()
            && !freeLayer.isEmpty && freeLayer[0].getType() == .EXTERNAL_PORT

        if countCrossingsCausedByPortSwitch {
            initParentCrossingsCounters(freeLayerIndex, graph.count)
        }
    }

    private func initParentCrossingsCounters(_ freeLayerIndex: Int, _ length: Int) {
        guard let parentGraphData = graphData.parentGraphData() else { return }
        let parentNodeOrder = parentGraphData.currentNodeOrder()
        let portPos = parentGraphData.portPositions()
        parentCrossCounter = org_eclipse_elk_alg_layered_p3order_counting_CrossingsCounter(portPos)
        let parentNodeLayerPos = graphData.parent().getLayer()?.id ?? 0
        let leftLayer = parentNodeLayerPos > 0 ? parentNodeOrder[parentNodeLayerPos - 1] : []
        let middleLayer = parentNodeOrder[parentNodeLayerPos]
        let rightLayer = parentNodeLayerPos < parentNodeOrder.count - 1 ? parentNodeOrder[parentNodeLayerPos + 1] : []
        let rightMostLayer = freeLayerIndex == length - 1
        if rightMostLayer {
            parentCrossCounter?.initForCountingBetween(middleLayer, rightLayer)
        } else {
            parentCrossCounter?.initForCountingBetween(leftLayer, middleLayer)
        }
    }

    package func notifyOfSwitch(_ upperNode: LNode, _ lowerNode: LNode) {
        // Update freeLayer to reflect the swap (Java's LNode[] is a reference type,
        // so swaps in GreedySwitchHeuristic.exchangeNodes are visible here automatically;
        // Swift's [LNode] is a value type so we must update our copy).
        if let upperIdx = freeLayer.firstIndex(where: { $0 === upperNode }),
           let lowerIdx = freeLayer.firstIndex(where: { $0 === lowerNode }) {
            freeLayer.swapAt(upperIdx, lowerIdx)
        }
        leftInLayerCounter.switchNodes(upperNode, lowerNode, .WEST)
        rightInLayerCounter.switchNodes(upperNode, lowerNode, .EAST)
        if countCrossingsCausedByPortSwitch {
            if let upperPort = upperNode.getProperty(InternalProperties.ORIGIN) as? LPort,
               let lowerPort = lowerNode.getProperty(InternalProperties.ORIGIN) as? LPort {
                parentCrossCounter?.switchPorts(upperPort, lowerPort)
            }
        }
    }

    package func doesSwitchReduceCrossings(_ upperNodeIndex: Int, _ lowerNodeIndex: Int) -> Bool {
        if constraintsPreventSwitch(upperNodeIndex, lowerNodeIndex) {
            return false
        }

        let upperNode = freeLayer[upperNodeIndex]
        let lowerNode = freeLayer[lowerNodeIndex]

        let leftInlayer = leftInLayerCounter.countInLayerCrossingsBetweenNodesInBothOrders(upperNode, lowerNode, .WEST)
        let rightInlayer = rightInLayerCounter.countInLayerCrossingsBetweenNodesInBothOrders(upperNode, lowerNode, .EAST)
        northSouthCounter.countCrossings(upperNode, lowerNode)

        var upperLowerCrossings = crossingMatrixFiller.getCrossingMatrixEntry(upperNode, lowerNode)
            + (leftInlayer.getFirst() ?? 0) + (rightInlayer.getFirst() ?? 0)
            + northSouthCounter.getUpperLowerCrossings()
        var lowerUpperCrossings = crossingMatrixFiller.getCrossingMatrixEntry(lowerNode, upperNode)
            + (leftInlayer.getSecond() ?? 0) + (rightInlayer.getSecond() ?? 0)
            + northSouthCounter.getLowerUpperCrossings()

        if countCrossingsCausedByPortSwitch {
            if let upperPort = upperNode.getProperty(InternalProperties.ORIGIN) as? LPort,
               let lowerPort = lowerNode.getProperty(InternalProperties.ORIGIN) as? LPort,
               let parentCC = parentCrossCounter {
                let crossingNumbers = parentCC.countCrossingsBetweenPortsInBothOrders(upperPort, lowerPort)
                upperLowerCrossings += crossingNumbers.getFirst() ?? 0
                lowerUpperCrossings += crossingNumbers.getSecond() ?? 0
            }
        }

        let shouldSwitch = upperLowerCrossings > lowerUpperCrossings
        return shouldSwitch
    }

    private func constraintsPreventSwitch(_ nodeIndex: Int, _ lowerNodeIndex: Int) -> Bool {
        let upperNode = freeLayer[nodeIndex]
        let lowerNode = freeLayer[lowerNodeIndex]

        return haveSuccessorConstraints(upperNode, lowerNode)
            || haveLayoutUnitConstraints(upperNode, lowerNode)
            || areNormalAndNorthSouthPortDummy(upperNode, lowerNode)
    }

    private func haveSuccessorConstraints(_ upperNode: LNode, _ lowerNode: LNode) -> Bool {
        guard let constraints = upperNode.getProperty(InternalProperties.IN_LAYER_SUCCESSOR_CONSTRAINTS) as? [LNode] else {
            return false
        }
        return !constraints.isEmpty && constraints.contains(where: { $0 === lowerNode })
    }

    private func haveLayoutUnitConstraints(_ upperNode: LNode, _ lowerNode: LNode) -> Bool {
        let neitherNodeIsLongEdgeDummy = upperNode.getType() != .LONG_EDGE && lowerNode.getType() != .LONG_EDGE

        let upperLayoutUnit = upperNode.getProperty(InternalProperties.IN_LAYER_LAYOUT_UNIT) as? LNode
        let lowerLayoutUnit = lowerNode.getProperty(InternalProperties.IN_LAYER_LAYOUT_UNIT) as? LNode

        let areInDifferentLayoutUnits = upperLayoutUnit !== lowerLayoutUnit

        var nodesHaveLayoutUnits = partOfMultiNodeLayoutUnit(upperNode, upperLayoutUnit)
            || partOfMultiNodeLayoutUnit(lowerNode, lowerLayoutUnit)

        let upperNodeHasNorthernEdges = hasEdgesOnSide(upperNode, .NORTH)
        let lowerNodeHasSouthernEdges = hasEdgesOnSide(lowerNode, .SOUTH)

        // hotfix for #162
        nodesHaveLayoutUnits = nodesHaveLayoutUnits
            || hasEdgesOnSide(upperNode, .SOUTH) || hasEdgesOnSide(lowerNode, .NORTH)

        let hasLayoutUnitConstraint = (nodesHaveLayoutUnits && areInDifferentLayoutUnits)
            || (upperNodeHasNorthernEdges || lowerNodeHasSouthernEdges)

        return neitherNodeIsLongEdgeDummy && hasLayoutUnitConstraint
    }

    private func hasEdgesOnSide(_ node: LNode, _ side: PortSide) -> Bool {
        for port in node.getPortSideView(side) {
            if port.getProperty(InternalProperties.PORT_DUMMY) != nil
                || !port.getConnectedEdges().isEmpty {
                return true
            }
        }
        return false
    }

    private func partOfMultiNodeLayoutUnit(_ node: LNode, _ layoutUnit: LNode?) -> Bool {
        layoutUnit != nil && layoutUnit !== node
    }

    private func areNormalAndNorthSouthPortDummy(_ upperNode: LNode, _ lowerNode: LNode) -> Bool {
        (isNorthSouthPortNode(upperNode) && isNormalNode(lowerNode))
            || (isNorthSouthPortNode(lowerNode) && isNormalNode(upperNode))
    }

    private func isNormalNode(_ node: LNode) -> Bool {
        node.getType() == .NORMAL
    }

    private func isNorthSouthPortNode(_ node: LNode) -> Bool {
        node.getType() == .NORTH_SOUTH_PORT
    }
}
