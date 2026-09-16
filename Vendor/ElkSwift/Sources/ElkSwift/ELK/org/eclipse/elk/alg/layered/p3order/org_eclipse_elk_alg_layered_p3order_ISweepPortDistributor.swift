// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/ISweepPortDistributor.java

import Foundation

package protocol org_eclipse_elk_alg_layered_p3order_ISweepPortDistributor: org_eclipse_elk_alg_layered_p3order_counting_IInitializable {
    func distributePortsWhileSweeping(
        _ order: [[org_eclipse_elk_alg_layered_graph_LNode]],
        _ freeLayerIndex: Int,
        _ isForwardSweep: Bool
    ) -> Bool
}

package extension org_eclipse_elk_alg_layered_p3order_ISweepPortDistributor {
    package static func create<R: RandomNumberGenerator>(
        _ cmt: org_eclipse_elk_alg_layered_p3order_CrossMinType,
        _ r: inout R,
        _ currentOrder: [[org_eclipse_elk_alg_layered_graph_LNode]]
    ) -> any org_eclipse_elk_alg_layered_p3order_ISweepPortDistributor {
        if cmt == .TWO_SIDED_GREEDY_SWITCH {
            return org_eclipse_elk_alg_layered_p3order_GreedyPortDistributor()
        } else if Bool.random(using: &r) {
            return org_eclipse_elk_alg_layered_p3order_NodeRelativePortDistributor(currentOrder.count)
        } else {
            return org_eclipse_elk_alg_layered_p3order_LayerTotalPortDistributor(currentOrder.count)
        }
    }
}
