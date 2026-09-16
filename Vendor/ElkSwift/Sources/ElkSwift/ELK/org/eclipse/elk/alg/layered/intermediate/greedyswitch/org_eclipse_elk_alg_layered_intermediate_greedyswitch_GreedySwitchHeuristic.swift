// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/greedyswitch/GreedySwitchHeuristic.java
import Foundation

package class org_eclipse_elk_alg_layered_intermediate_greedyswitch_GreedySwitchHeuristic:
    org_eclipse_elk_alg_layered_p3order_ICrossingMinimizationHeuristic
{
    private let greedySwitchType: org_eclipse_elk_alg_layered_p3order_CrossMinType
    private var currentNodeOrder: [[LNode]] = []
    private var switchDecider: org_eclipse_elk_alg_layered_intermediate_greedyswitch_SwitchDecider?
    private var portPositions = SharedIntArray()
    private let graphData: org_eclipse_elk_alg_layered_p3order_GraphInfoHolder
    private var nPorts: Int = 0

    package init(
        _ greedyType: org_eclipse_elk_alg_layered_p3order_CrossMinType,
        _ graphData: org_eclipse_elk_alg_layered_p3order_GraphInfoHolder
    ) {
        self.graphData = graphData
        self.greedySwitchType = greedyType
    }

    package func minimizeCrossings(
        _ order: inout [[LNode]],
        _ freeLayerIndex: Int,
        _ forwardSweep: Bool,
        _ isFirstSweep: Bool
    ) -> Bool {
        setUp(&order, freeLayerIndex, forwardSweep)
        let result = continueSwitchingUntilNoImprovementInLayer(freeLayerIndex)
        // Write back: in Java, currentNodeOrder = order is a reference copy,
        // but in Swift arrays are value types so swaps in exchangeNodes only
        // modify self.currentNodeOrder. Propagate changes back to the caller.
        order = currentNodeOrder
        return result
    }

    package func setFirstLayerOrder(
        _ currentOrder: inout [[LNode]],
        _ isForwardSweep: Bool
    ) -> Bool {
        let startIndex = startIndex(isForwardSweep, currentOrder.count)
        setUp(&currentOrder, startIndex, isForwardSweep)
        let result = sweepDownwardInLayer(startIndex)
        currentOrder = currentNodeOrder
        return result
    }

    private func setUp(_ order: inout [[LNode]], _ freeLayerIndex: Int, _ forwardSweep: Bool) {
        currentNodeOrder = order
        let side: org_eclipse_elk_alg_layered_intermediate_greedyswitch_SwitchDecider.CrossingCountSide =
            forwardSweep ? .WEST : .EAST
        switchDecider = getNewSwitchDecider(freeLayerIndex, side)
    }

    private func getNewSwitchDecider(
        _ freeLayerIndex: Int,
        _ side: org_eclipse_elk_alg_layered_intermediate_greedyswitch_SwitchDecider.CrossingCountSide
    ) -> org_eclipse_elk_alg_layered_intermediate_greedyswitch_SwitchDecider {
        let crossingMatrixFiller = org_eclipse_elk_alg_layered_intermediate_greedyswitch_CrossingMatrixFiller(
            greedySwitchType, currentNodeOrder, freeLayerIndex, side)
        return org_eclipse_elk_alg_layered_intermediate_greedyswitch_SwitchDecider(
            freeLayerIndex, currentNodeOrder, crossingMatrixFiller, portPositions, graphData,
            greedySwitchType == .ONE_SIDED_GREEDY_SWITCH)
    }

    private func continueSwitchingUntilNoImprovementInLayer(_ freeLayerIndex: Int) -> Bool {
        var improved = false
        var continueSwitching: Bool
        repeat {
            continueSwitching = sweepDownwardInLayer(freeLayerIndex)
            improved = improved || continueSwitching
        } while continueSwitching
        return improved
    }

    private func sweepDownwardInLayer(_ layerIndex: Int) -> Bool {
        var continueSwitching = false
        let lengthOfFreeLayer = currentNodeOrder[layerIndex].count
        for upperNodeIndex in 0..<(lengthOfFreeLayer - 1) {
            let lowerNodeIndex = upperNodeIndex + 1
            continueSwitching = switchIfImproves(layerIndex, upperNodeIndex, lowerNodeIndex) || continueSwitching
        }
        return continueSwitching
    }

    private func switchIfImproves(_ layerIndex: Int, _ upperNodeIndex: Int, _ lowerNodeIndex: Int) -> Bool {
        guard let switchDecider else { return false }
        if switchDecider.doesSwitchReduceCrossings(upperNodeIndex, lowerNodeIndex) {
            exchangeNodes(upperNodeIndex, lowerNodeIndex, layerIndex)
            return true
        }
        return false
    }

    private func exchangeNodes(_ indexOne: Int, _ indexTwo: Int, _ layerIndex: Int) {
        switchDecider?.notifyOfSwitch(
            currentNodeOrder[layerIndex][indexOne],
            currentNodeOrder[layerIndex][indexTwo])
        let temp = currentNodeOrder[layerIndex][indexTwo]
        currentNodeOrder[layerIndex][indexTwo] = currentNodeOrder[layerIndex][indexOne]
        currentNodeOrder[layerIndex][indexOne] = temp
    }

    private func startIndex(_ isForwardSweep: Bool, _ length: Int) -> Int {
        isForwardSweep ? 0 : length - 1
    }

    package func alwaysImproves() -> Bool {
        !(greedySwitchType == .ONE_SIDED_GREEDY_SWITCH)
    }

    package func isDeterministic() -> Bool {
        true
    }

    package func initAtPortLevel(_ l: Int, _ n: Int, _ p: Int, _ nodeOrder: [[LNode]]) {
        nPorts += 1
    }

    package func initAtLayerLevel(_ l: Int, _ nodeOrder: [[LNode]]) {
        nodeOrder[l][0].getLayer()?.id = l
    }

    package func initAfterTraversal() {
        portPositions = SharedIntArray(repeating: 0, count: nPorts)
    }

}
