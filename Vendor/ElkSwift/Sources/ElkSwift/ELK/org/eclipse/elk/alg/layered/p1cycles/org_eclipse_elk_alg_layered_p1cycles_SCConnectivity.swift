// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p1cycles/SCConnectivity.java

import Foundation

package class org_eclipse_elk_alg_layered_p1cycles_SCConnectivity: org_eclipse_elk_alg_layered_p1cycles_SCCModelOrderCycleBreaker {
    package override init() {
        super.init()
    }

    /// Java: SCConnectivity#findNodes(int offset, int bigOffset)
    package override func findNodes(_ offset: Int, _ bigOffset: Int) {
        guard let graph else {
            return
        }

        let enforceGroupModelOrder = org_eclipse_elk_alg_layered_p1cycles_ModelOrderPropertyScaffolding
            .groupOrderStrategy(for: graph) == .ENFORCED

        for component in stronglyConnectedComponents where component.count > 1 {
            let calculator = org_eclipse_elk_alg_layered_p1cycles_GroupModelOrderCalculator()
            let edges = Self.selectEdgesForStronglyConnectedComponent(component) { node in
                enforceGroupModelOrder
                    ? calculator.computeConstraintGroupModelOrder(node, bigOffset, offset)
                    : calculator.computeConstraintModelOrder(node, offset)
            }
            revEdges.append(contentsOf: edges)
        }
    }

    /// Faithful core selection logic from Java, extracted so it can be reused once SCC/runtime dependencies exist.
    package static func selectEdgesForStronglyConnectedComponent(
        _ component: [org_eclipse_elk_alg_layered_graph_LNode],
        _ modelOrder: (org_eclipse_elk_alg_layered_graph_LNode) -> Int
    ) -> [org_eclipse_elk_alg_layered_graph_LEdge] {
        if component.count <= 1 {
            return []
        }

        var minNode: org_eclipse_elk_alg_layered_graph_LNode?
        var maxNode: org_eclipse_elk_alg_layered_graph_LNode?
        var modelOrderMin = Int.max
        var modelOrderMax = Int.min

        for node in component {
            let currentOrder = modelOrder(node)

            if minNode == nil || maxNode == nil {
                minNode = node
                maxNode = node
                modelOrderMin = currentOrder
                modelOrderMax = currentOrder
            } else {
                if modelOrderMin > currentOrder {
                    minNode = node
                    modelOrderMin = currentOrder
                }
                if modelOrderMax < currentOrder {
                    maxNode = node
                    modelOrderMax = currentOrder
                }
            }
        }

        guard let minNode, let maxNode else {
            return []
        }

        var reversed: [org_eclipse_elk_alg_layered_graph_LEdge] = []
        if minNode.getIncomingEdges().count > maxNode.getOutgoingEdges().count {
            for edge in minNode.getIncomingEdges() {
                if let sourceNode = edge.getSource()?.getNode(), containsIdentity(sourceNode, in: component) {
                    reversed.append(edge)
                }
            }
        } else {
            for edge in maxNode.getOutgoingEdges() {
                if let targetNode = edge.getTarget()?.getNode(), containsIdentity(targetNode, in: component) {
                    reversed.append(edge)
                }
            }
        }
        return reversed
    }

    package static func containsIdentity(
        _ node: org_eclipse_elk_alg_layered_graph_LNode,
        in component: [org_eclipse_elk_alg_layered_graph_LNode]
    ) -> Bool {
        component.contains(where: { $0 === node })
    }
}
