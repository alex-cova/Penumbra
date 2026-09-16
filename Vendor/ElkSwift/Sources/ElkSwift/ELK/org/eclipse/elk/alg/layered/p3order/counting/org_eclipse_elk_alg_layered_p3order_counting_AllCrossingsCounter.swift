// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/counting/AllCrossingsCounter.java

import Foundation

package final class org_eclipse_elk_alg_layered_p3order_counting_AllCrossingsCounter:
    org_eclipse_elk_alg_layered_p3order_counting_IInitializable
{
    package var crossingCounter: org_eclipse_elk_alg_layered_p3order_counting_CrossingsCounter?
    package var hasHyperEdgesEastOfIndex: [Bool]
    package var hyperedgeCrossingsCounter: org_eclipse_elk_alg_layered_p3order_counting_HyperedgeCrossingsCounter?

    package var inLayerEdgeCounts: [Int]
    package var hasNorthSouthPorts: [Bool]
    package var nPorts: Int

    package init(_ graph: [[org_eclipse_elk_alg_layered_graph_LNode]]) {
        inLayerEdgeCounts = Array(repeating: 0, count: graph.count)
        hasNorthSouthPorts = Array(repeating: false, count: graph.count)
        hasHyperEdgesEastOfIndex = Array(repeating: false, count: graph.count)
        nPorts = 0
    }

    package func countAllCrossings(_ currentOrder: [[org_eclipse_elk_alg_layered_graph_LNode]]) -> Int {
        if currentOrder.isEmpty {
            return 0
        }

        guard let crossingCounter else {
            return 0
        }

        var crossings = crossingCounter.countInLayerCrossingsOnSide(currentOrder[0], .WEST)
        let eastCross = crossingCounter.countInLayerCrossingsOnSide(currentOrder[currentOrder.count - 1], .EAST)
        crossings += eastCross

        for layerIndex in currentOrder.indices {
            let layerCross = countCrossingsAt(layerIndex, currentOrder)
            crossings += layerCross
        }

        return crossings
    }

    package func countCrossingsAt(_ layerIndex: Int, _ currentOrder: [[org_eclipse_elk_alg_layered_graph_LNode]]) -> Int {
        var totalCrossings = 0
        let leftLayer = currentOrder[layerIndex]

        if layerIndex < currentOrder.count - 1 {
            let rightLayer = currentOrder[layerIndex + 1]
            if hasHyperEdgesEastOfIndex[layerIndex] {
                totalCrossings = hyperedgeCrossingsCounter?.countCrossings(leftLayer, rightLayer) ?? 0
                if let crossingCounter {
                    totalCrossings += crossingCounter.countInLayerCrossingsOnSide(leftLayer, .EAST)
                    totalCrossings += crossingCounter.countInLayerCrossingsOnSide(rightLayer, .WEST)
                }
            } else {
                totalCrossings = crossingCounter?.countCrossingsBetweenLayers(leftLayer, rightLayer) ?? 0
            }
        }

        if hasNorthSouthPorts[layerIndex] {
            totalCrossings += crossingCounter?.countNorthSouthPortCrossingsInLayer(leftLayer) ?? 0
        }

        return totalCrossings
    }

    package func initAtNodeLevel(
        _ l: Int,
        _ n: Int,
        _ nodeOrder: [[org_eclipse_elk_alg_layered_graph_LNode]]
    ) {
        guard l >= 0, l < nodeOrder.count, n >= 0, n < nodeOrder[l].count else {
            return
        }
        if nodeOrder[l][n].getType() == .NORTH_SOUTH_PORT {
            hasNorthSouthPorts[l] = true
        }
    }

    package func initAtPortLevel(
        _ l: Int,
        _ n: Int,
        _ p: Int,
        _ nodeOrder: [[org_eclipse_elk_alg_layered_graph_LNode]]
    ) {
        guard l >= 0, l < nodeOrder.count, n >= 0, n < nodeOrder[l].count else {
            return
        }
        let ports = nodeOrder[l][n].getPorts()
        guard p >= 0, p < ports.count else {
            return
        }

        let port = ports[p]
        port.id = nPorts
        nPorts += 1

        if port.getOutgoingEdges().count + port.getIncomingEdges().count > 1 {
            if port.getSide() == .EAST {
                hasHyperEdgesEastOfIndex[l] = true
            } else if port.getSide() == .WEST, l > 0 {
                hasHyperEdgesEastOfIndex[l - 1] = true
            }
        }
    }

    package func initAtEdgeLevel(
        _ l: Int,
        _ n: Int,
        _ p: Int,
        _ e: Int,
        _ edge: org_eclipse_elk_alg_layered_graph_LEdge,
        _ nodeOrder: [[org_eclipse_elk_alg_layered_graph_LNode]]
    ) {
        _ = e
        guard l >= 0, l < nodeOrder.count, n >= 0, n < nodeOrder[l].count else {
            return
        }
        let ports = nodeOrder[l][n].getPorts()
        guard p >= 0, p < ports.count else {
            return
        }

        let port = ports[p]
        if edge.getSource() === port,
           let sourceLayer = edge.getSource()?.getNode()?.getLayer(),
           let targetLayer = edge.getTarget()?.getNode()?.getLayer(),
           sourceLayer === targetLayer
        {
            inLayerEdgeCounts[l] += 1
        }
    }

    package func initAfterTraversal() {
        let portPos = Array(repeating: 0, count: nPorts)
        hyperedgeCrossingsCounter = org_eclipse_elk_alg_layered_p3order_counting_HyperedgeCrossingsCounter(
            inLayerEdgeCounts,
            hasNorthSouthPorts,
            portPos
        )
        crossingCounter = org_eclipse_elk_alg_layered_p3order_counting_CrossingsCounter(portPos)
    }
}
