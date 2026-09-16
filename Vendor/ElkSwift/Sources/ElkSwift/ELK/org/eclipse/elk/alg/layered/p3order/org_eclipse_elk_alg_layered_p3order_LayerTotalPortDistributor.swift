// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/LayerTotalPortDistributor.java

import Foundation

package final class org_eclipse_elk_alg_layered_p3order_LayerTotalPortDistributor:
    org_eclipse_elk_alg_layered_p3order_AbstractBarycenterPortDistributor
{
    package convenience init() {
        self.init(0)
    }

    package override init(_ numLayers: Int) {
        super.init(numLayers)
    }

    @discardableResult
    package override func calculatePortRanks(
        _ node: org_eclipse_elk_alg_layered_graph_LNode,
        _ rankSum: Float,
        _ type: org_eclipse_elk_alg_layered_options_PortType
    ) -> Float {
        switch type {
        case .INPUT:
            var inputCount = 0
            var northInputCount = 0
            for port in node.getPorts() {
                if !port.getIncomingEdges().isEmpty {
                    inputCount += 1
                    if port.getSide() == .NORTH {
                        northInputCount += 1
                    }
                }
            }

            var northPos = rankSum + Float(northInputCount)
            var restPos = rankSum + Float(inputCount)
            for port in node.getPorts(.INPUT) {
                if port.getSide() == .NORTH {
                    setPortRank(port.id, northPos)
                    northPos -= 1
                } else {
                    setPortRank(port.id, restPos)
                    restPos -= 1
                }
            }
            return Float(inputCount)

        case .OUTPUT:
            var pos = 0
            for port in node.getPorts(.OUTPUT) {
                pos += 1
                let rank = rankSum + Float(pos)
                setPortRank(port.id, rank)
            }
            return Float(pos)

        case .UNDEFINED:
            return 0
        }
    }
}
