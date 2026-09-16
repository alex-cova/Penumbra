// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/preserveorder/CMGroupModelOrderCalculator.java
import Foundation

package class org_eclipse_elk_alg_layered_intermediate_preserveorder_CMGroupModelOrderCalculator {
    package init() {}

    package class func calculateModelOrderOrGroupModelOrder(
        _ element: LGraphElement,
        _ other: LGraphElement,
        _ parent: LGraph,
        _ offset: Int
    ) -> Int {
        let enforceGroupModelOrder =
            (parent.getProperty(
                LayeredOptions.CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CM_GROUP_ORDER_STRATEGY
            ) as? GroupOrderStrategy) == .ENFORCED

        let enforcedOrders = parent.getProperty(
            LayeredOptions.CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CM_ENFORCED_GROUP_ORDERS
        ) as? [Int] ?? []

        guard let elementModelOrder = element.getProperty(InternalProperties.MODEL_ORDER) as? Int else {
            return -1
        }

        if enforceGroupModelOrder {
            let elementGroupId = element.getProperty(
                LayeredOptions.CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CROSSING_MINIMIZATION_ID
            ) as? Int
            let otherGroupId = other.getProperty(
                LayeredOptions.CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CROSSING_MINIMIZATION_ID
            ) as? Int

            if let elementGroupId, let otherGroupId,
               enforcedOrders.contains(elementGroupId),
               enforcedOrders.contains(otherGroupId)
            {
                return offset * elementGroupId + elementModelOrder
            }
        }

        return elementModelOrder
    }
}
