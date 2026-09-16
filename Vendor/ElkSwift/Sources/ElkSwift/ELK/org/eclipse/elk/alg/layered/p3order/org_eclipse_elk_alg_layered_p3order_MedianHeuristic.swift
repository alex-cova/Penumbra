// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/MedianHeuristic.java
import Foundation

package class org_eclipse_elk_alg_layered_p3order_MedianHeuristic: org_eclipse_elk_alg_layered_p3order_ICrossingMinimizationHeuristic {
    package static let WEIGHT_KEY = "weight"

    package init(_ random: Any? = nil) {
        _ = random
    }

    package func alwaysImproves() -> Bool {
        false
    }

    package func setFirstLayerOrder(_ order: inout [[org_eclipse_elk_alg_layered_graph_LNode]], _ forwardSweep: Bool) -> Bool {
        guard !order.isEmpty else {
            return false
        }

        let firstIndex = forwardSweep ? 0 : max(0, order.count - 1)
        var firstLayer = order[firstIndex]

        for node in firstLayer {
            node.setProperty(Self.WEIGHT_KEY, Double.random(in: 0.0..<1.0))
        }

        firstLayer = stableSortByWeight(firstLayer)

        var index = 0
        while index < firstLayer.count {
            let node = firstLayer[index]
            order[firstIndex][index] = node
            node.setProperty(Self.WEIGHT_KEY, Double(index + 1))
            index += 1
        }

        return false
    }

    package func setFirstLayerOrder(_ order: [[org_eclipse_elk_alg_layered_graph_LNode]], _ forwardSweep: Bool) -> Bool {
        var mutableOrder = order
        return setFirstLayerOrder(&mutableOrder, forwardSweep)
    }

    package func minimizeCrossings(
        _ order: inout [[org_eclipse_elk_alg_layered_graph_LNode]],
        _ freeLayerIndex: Int,
        _ forwardSweep: Bool,
        _ isFirstSweep: Bool
    ) -> Bool {
        _ = isFirstSweep

        guard freeLayerIndex >= 0, freeLayerIndex < order.count else {
            return false
        }

        var freeLayer = order[freeLayerIndex]
        let referenceLayer = forwardSweep ? freeLayerIndex - 1 : freeLayerIndex + 1
        calculateMedians(freeLayer, referenceLayer)
        freeLayer = stableSortByWeight(freeLayer)

        for (index, node) in freeLayer.enumerated() {
            order[freeLayerIndex][index] = node
        }

        return false
    }

    package func minimizeCrossings(
        _ order: [[org_eclipse_elk_alg_layered_graph_LNode]],
        _ freeLayerIndex: Int,
        _ forwardSweep: Bool,
        _ isFirstSweep: Bool
    ) -> Bool {
        var mutableOrder = order
        return minimizeCrossings(&mutableOrder, freeLayerIndex, forwardSweep, isFirstSweep)
    }

    package func calculateMedians(_ nodes: [org_eclipse_elk_alg_layered_graph_LNode], _ referenceLayer: Int) {
        var minWeight = Double.leastNonzeroMagnitude
        var maxWeight = Double.greatestFiniteMagnitude
        var toRevisit: [org_eclipse_elk_alg_layered_graph_LNode] = []

        for node in nodes {
            var connectedNodes: [org_eclipse_elk_alg_layered_graph_LNode] = []

            for edge in node.getIncomingEdges() {
                if let target = edge.getTarget()?.getNode(), target.getLayer()?.id == referenceLayer {
                    connectedNodes.append(target)
                }
                if let source = edge.getSource()?.getNode(), source.getLayer()?.id == referenceLayer {
                    connectedNodes.append(source)
                }
            }

            for edge in node.getOutgoingEdges() {
                if let target = edge.getTarget()?.getNode(), target.getLayer()?.id == referenceLayer {
                    connectedNodes.append(target)
                }
                if let source = edge.getSource()?.getNode(), source.getLayer()?.id == referenceLayer {
                    connectedNodes.append(source)
                }
            }

            if connectedNodes.isEmpty {
                toRevisit.append(node)
            } else {
                let sortedConnected = stableSortByWeight(connectedNodes)
                let medianNode = sortedConnected[sortedConnected.count / 2]
                let newWeight = medianNode.getProperty(Self.WEIGHT_KEY) as? Double ?? 0.0
                node.setProperty(Self.WEIGHT_KEY, newWeight)
                minWeight = min(minWeight, newWeight)
                maxWeight = max(maxWeight, newWeight)
            }
        }

        let avgWeight = (maxWeight + minWeight) / 2.0
        for node in toRevisit {
            node.setProperty(Self.WEIGHT_KEY, avgWeight)
        }
    }

    package func isDeterministic() -> Bool {
        true
    }

    package func weightCompare(_ n1: org_eclipse_elk_alg_layered_graph_LNode, _ n2: org_eclipse_elk_alg_layered_graph_LNode) -> Int {
        if !n1.hasProperty(Self.WEIGHT_KEY) {
            return 1
        }
        if !n2.hasProperty(Self.WEIGHT_KEY) {
            return -1
        }

        let w1 = n1.getProperty(Self.WEIGHT_KEY) as? Double
        let w2 = n2.getProperty(Self.WEIGHT_KEY) as? Double

        if let w1, let w2 {
            if w1 < w2 {
                return -1
            }
            if w1 > w2 {
                return 1
            }
            return 0
        }

        if w1 != nil {
            return -1
        }
        if w2 != nil {
            return 1
        }
        return 0
    }

    package func stableSortByWeight(_ nodes: [org_eclipse_elk_alg_layered_graph_LNode]) -> [org_eclipse_elk_alg_layered_graph_LNode] {
        nodes.enumerated().sorted { lhs, rhs in
            let comparison = weightCompare(lhs.element, rhs.element)
            if comparison == 0 {
                return lhs.offset < rhs.offset
            }
            return comparison < 0
        }.map(\.element)
    }
}
