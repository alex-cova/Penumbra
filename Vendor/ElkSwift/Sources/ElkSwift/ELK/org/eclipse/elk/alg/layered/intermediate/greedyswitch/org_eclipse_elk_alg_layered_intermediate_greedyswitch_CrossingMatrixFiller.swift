// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/greedyswitch/CrossingMatrixFiller.java
import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_greedyswitch_CrossingMatrixFiller {

    private var isCrossingMatrixFilled: [[Bool]]
    private var crossingMatrix: [[Int]]
    private let inBetweenLayerCrossingCounter: org_eclipse_elk_alg_layered_intermediate_greedyswitch_BetweenLayerEdgeTwoNodeCrossingsCounter
    private let direction: org_eclipse_elk_alg_layered_intermediate_greedyswitch_SwitchDecider.CrossingCountSide
    private let oneSided: Bool

    package init(
        _ greedySwitchType: org_eclipse_elk_alg_layered_p3order_CrossMinType,
        _ graph: [[LNode]],
        _ freeLayerIndex: Int,
        _ direction: org_eclipse_elk_alg_layered_intermediate_greedyswitch_SwitchDecider.CrossingCountSide
    ) {
        self.direction = direction
        oneSided = greedySwitchType == .ONE_SIDED_GREEDY_SWITCH

        let freeLayerLength = graph[freeLayerIndex].count
        isCrossingMatrixFilled = Array(repeating: Array(repeating: false, count: freeLayerLength), count: freeLayerLength)
        crossingMatrix = Array(repeating: Array(repeating: 0, count: freeLayerLength), count: freeLayerLength)

        inBetweenLayerCrossingCounter = org_eclipse_elk_alg_layered_intermediate_greedyswitch_BetweenLayerEdgeTwoNodeCrossingsCounter(graph, freeLayerIndex)
    }

    package func getCrossingMatrixEntry(_ upperNode: LNode, _ lowerNode: LNode) -> Int {
        if !isCrossingMatrixFilled[upperNode.id][lowerNode.id] {
            fillCrossingMatrix(upperNode, lowerNode)
            isCrossingMatrixFilled[upperNode.id][lowerNode.id] = true
            isCrossingMatrixFilled[lowerNode.id][upperNode.id] = true
        }
        return crossingMatrix[upperNode.id][lowerNode.id]
    }

    private func fillCrossingMatrix(_ upperNode: LNode, _ lowerNode: LNode) {
        if oneSided {
            switch direction {
            case .EAST:
                inBetweenLayerCrossingCounter.countEasternEdgeCrossings(upperNode, lowerNode)
            case .WEST:
                inBetweenLayerCrossingCounter.countWesternEdgeCrossings(upperNode, lowerNode)
            }
        } else {
            inBetweenLayerCrossingCounter.countBothSideCrossings(upperNode, lowerNode)
        }
        crossingMatrix[upperNode.id][lowerNode.id] = inBetweenLayerCrossingCounter.getUpperLowerCrossings()
        crossingMatrix[lowerNode.id][upperNode.id] = inBetweenLayerCrossingCounter.getLowerUpperCrossings()
    }
}
