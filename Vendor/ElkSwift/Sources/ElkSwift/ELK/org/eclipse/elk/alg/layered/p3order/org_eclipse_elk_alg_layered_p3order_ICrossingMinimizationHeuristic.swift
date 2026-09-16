// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/ICrossingMinimizationHeuristic.java

import Foundation

package protocol org_eclipse_elk_alg_layered_p3order_ICrossingMinimizationHeuristic: org_eclipse_elk_alg_layered_p3order_counting_IInitializable {
    func alwaysImproves() -> Bool
    func setFirstLayerOrder(
        _ order: inout [[org_eclipse_elk_alg_layered_graph_LNode]],
        _ forwardSweep: Bool
    ) -> Bool
    func minimizeCrossings(
        _ order: inout [[org_eclipse_elk_alg_layered_graph_LNode]],
        _ freeLayerIndex: Int,
        _ forwardSweep: Bool,
        _ isFirstSweep: Bool
    ) -> Bool
    func isDeterministic() -> Bool
}
