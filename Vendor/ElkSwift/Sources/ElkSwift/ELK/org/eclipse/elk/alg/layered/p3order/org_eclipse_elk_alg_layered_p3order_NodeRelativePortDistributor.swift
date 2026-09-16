// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/NodeRelativePortDistributor.java

import Foundation

package final class org_eclipse_elk_alg_layered_p3order_NodeRelativePortDistributor:
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

            let incr = 1.0 as Float / Float(inputCount + 1)
            var northPos = rankSum + Float(northInputCount) * incr
            var restPos = rankSum + 1 - incr
            for port in node.getPorts(.INPUT) {
                if port.getSide() == .NORTH {
                    setPortRank(port.id, northPos)
                    northPos -= incr
                } else {
                    setPortRank(port.id, restPos)
                    restPos -= incr
                }
            }

        case .OUTPUT:
            var outputCount = 0
            for port in node.getPorts() {
                if !port.getOutgoingEdges().isEmpty {
                    outputCount += 1
                }
            }

            let incr = 1.0 as Float / Float(outputCount + 1)
            var pos = rankSum + incr
            for port in node.getPorts(.OUTPUT) {
                setPortRank(port.id, pos)
                pos += incr
            }

        case .UNDEFINED:
            break
        }

        // Java: consumed rank is always 1 for node-relative strategy.
        return 1
    }
}
