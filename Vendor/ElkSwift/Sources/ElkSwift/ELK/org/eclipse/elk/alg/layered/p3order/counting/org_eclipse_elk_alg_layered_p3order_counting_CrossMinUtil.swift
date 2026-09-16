// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/counting/CrossMinUtil.java
import Foundation

package final class org_eclipse_elk_alg_layered_p3order_counting_CrossMinUtil {
    private init() {}

    package static func inNorthSouthEastWestOrder(
        _ node: org_eclipse_elk_alg_layered_graph_LNode,
        _ side: PortSide
    ) -> [org_eclipse_elk_alg_layered_graph_LPort] {
        switch side {
        case .EAST, .NORTH:
            return node.getPortSideView(side)
        case .SOUTH, .WEST:
            return node.getPortSideView(side).reversed()
        default:
            return []
        }
    }
}
