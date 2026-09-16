import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_PortSideProcessor {
    package init() {}

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("Port side processing", 1)

        // IF USED BEFORE PHASE 1
        for node in layeredGraph.layerlessNodes {
            processNode(node)
        }

        // IF USED BEFORE PHASE 3
        for layer in layeredGraph.layers {
            for node in layer.nodes {
                processNode(node)
            }
        }

        monitor.done()
    }

    private func processNode(_ node: LNode) {
        if (node.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .UNDEFINED).isSideFixed() {
            for port in node.ports {
                if port.side == PortSide.UNDEFINED {
                    org_eclipse_elk_alg_layered_intermediate_PortSideProcessor.setPortSide(port)
                }
            }
        } else {
            for port in node.ports {
                org_eclipse_elk_alg_layered_intermediate_PortSideProcessor.setPortSide(port)
            }
            node.setProperty(LayeredOptions.PORT_CONSTRAINTS, value: PortConstraints.FIXED_SIDE)
        }
    }

    package static func setPortSide(_ port: LPort) {
        let portDummy: LNode? = port.getProperty(InternalProperties.PORT_DUMMY)
        if let portDummy = portDummy {
            port.side = portDummy.getProperty(InternalProperties.EXT_PORT_SIDE) as? PortSide ?? .UNDEFINED
        } else if port.getNetFlow() < 0 {
            port.side = .EAST
        } else {
            port.side = .WEST
        }
    }
}
