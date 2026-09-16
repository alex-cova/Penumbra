// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p1cycles/GreedyModelOrderCycleBreaker.java

import Foundation

package final class org_eclipse_elk_alg_layered_p1cycles_GreedyModelOrderCycleBreaker: org_eclipse_elk_alg_layered_p1cycles_GreedyCycleBreaker {
    package override init() {
        super.init()
    }

    package override func chooseNodeWithMaxOutflow(
        _ nodes: [org_eclipse_elk_alg_layered_graph_LNode]
    ) -> org_eclipse_elk_alg_layered_graph_LNode {
        guard !nodes.isEmpty else {
            assertionFailure("chooseNodeWithMaxOutflow called with empty nodes")
            return LNode(LGraph())
        }

        var returnNode: org_eclipse_elk_alg_layered_graph_LNode?
        var minimumModelOrder = Int.max

        let graph = nodes.first?.getGraph()
        let maxModelOrderNodes =
            org_eclipse_elk_alg_layered_p1cycles_ModelOrderPropertyScaffolding
                .maxModelOrderNodes(for: graph) ?? 1
        let cbNumModelOrderGroups =
            org_eclipse_elk_alg_layered_p1cycles_ModelOrderPropertyScaffolding
                .cbNumModelOrderGroups(for: graph) ?? 1
        let offset = max(nodes.count, maxModelOrderNodes)
        let bigOffset = offset * max(cbNumModelOrderGroups, 1)

        let moCalculator = org_eclipse_elk_alg_layered_p1cycles_GroupModelOrderCalculator()
        let enforceGroupModelOrder = shouldEnforceGroupModelOrder(graph)

        for node in nodes {
            let modelOrder = enforceGroupModelOrder
                ? moCalculator.computeConstraintGroupModelOrder(node, bigOffset, offset)
                : moCalculator.computeConstraintModelOrder(node, offset)

            if minimumModelOrder > modelOrder {
                minimumModelOrder = modelOrder
                returnNode = node
            }
        }

        return returnNode ?? nodes[0]
    }

    package func shouldEnforceGroupModelOrder(
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph?
    ) -> Bool {
        org_eclipse_elk_alg_layered_p1cycles_ModelOrderPropertyScaffolding
            .groupOrderStrategy(for: graph) == .ENFORCED
    }
}
