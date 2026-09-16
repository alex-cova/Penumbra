// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p1cycles/SCCNodeTypeCycleBreaker.java

import Foundation

package class org_eclipse_elk_alg_layered_p1cycles_SCCNodeTypeCycleBreaker: org_eclipse_elk_alg_layered_p1cycles_SCCModelOrderCycleBreaker {
    package override init() {
        super.init()
    }

    /// Java: SCCNodeTypeCycleBreaker#findNodes(int offset, int bigOffset)
    package override func findNodes(_ offset: Int, _ bigOffset: Int) {
        guard let graph else {
            return
        }

        let preferredSourceId = graph.getProperty(
            org_eclipse_elk_alg_layered_options_LayeredOptions
                .CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CB_PREFERRED_SOURCE_ID
        ) as? AnyHashable
        let preferredTargetId = graph.getProperty(
            org_eclipse_elk_alg_layered_options_LayeredOptions
                .CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CB_PREFERRED_TARGET_ID
        ) as? AnyHashable
        let enforceGroupModelOrder = org_eclipse_elk_alg_layered_p1cycles_ModelOrderPropertyScaffolding
            .groupOrderStrategy(for: graph) == .ENFORCED

        for component in stronglyConnectedComponents where component.count > 1 {
            let calculator = org_eclipse_elk_alg_layered_p1cycles_GroupModelOrderCalculator()
            let edges = Self.selectEdgesForStronglyConnectedComponent(
                component,
                { node in
                    enforceGroupModelOrder
                        ? calculator.computeConstraintGroupModelOrder(node, bigOffset, offset)
                        : calculator.computeConstraintModelOrder(node, offset)
                },
                { node in
                    node.getProperty(
                        org_eclipse_elk_alg_layered_options_LayeredOptions
                            .CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CYCLE_BREAKING_ID
                    ) as? AnyHashable
                },
                preferredSourceId,
                preferredTargetId
            )
            revEdges.append(contentsOf: edges)
        }
    }

    /// Faithful core logic from Java with explicit preferred-source/target handling.
    package static func selectEdgesForStronglyConnectedComponent(
        _ component: [org_eclipse_elk_alg_layered_graph_LNode],
        _ modelOrder: (org_eclipse_elk_alg_layered_graph_LNode) -> Int,
        _ nodeTypeId: (org_eclipse_elk_alg_layered_graph_LNode) -> AnyHashable?,
        _ preferredSourceId: AnyHashable?,
        _ preferredTargetId: AnyHashable?
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
        if nodeTypeId(minNode) == preferredSourceId {
            for edge in minNode.getIncomingEdges() {
                if let sourceNode = edge.getSource()?.getNode(), containsIdentity(sourceNode, in: component) {
                    reversed.append(edge)
                }
            }
            return reversed
        }

        if nodeTypeId(maxNode) == preferredTargetId {
            for edge in maxNode.getOutgoingEdges() {
                // NOTE: intentionally mirrors Java source check against edge source node.
                if let sourceNode = edge.getSource()?.getNode(), containsIdentity(sourceNode, in: component) {
                    reversed.append(edge)
                }
            }
            return reversed
        }

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
