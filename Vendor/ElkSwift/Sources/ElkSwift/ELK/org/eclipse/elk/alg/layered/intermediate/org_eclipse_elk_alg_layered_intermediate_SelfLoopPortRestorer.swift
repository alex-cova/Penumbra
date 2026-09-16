import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_SelfLoopPortRestorer: ILayoutProcessor {
    package typealias G = LGraph

    private let portSideAssigner = PortSideAssigner()
    private let portRestorer = PortRestorer()

    package init() {}

    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {
        progressMonitor.begin("Self-Loop ordering", 1)

        for layer in graph.getLayers() {
            for lNode in layer.getNodes() {
                if lNode.getType() == .NORMAL && lNode.hasProperty(InternalProperties.SELF_LOOP_HOLDER) {
                    if let slHolder = lNode.getProperty(InternalProperties.SELF_LOOP_HOLDER) as? SelfLoopHolder {
                        processNode(slHolder, progressMonitor)
                    }
                }
            }
        }

        progressMonitor.done()
    }

    private func processNode(_ slHolder: SelfLoopHolder, _ monitor: IElkProgressMonitor) {
        if slHolder.arePortsHidden() {
            let originalPC = slHolder.getLNode().getProperty(InternalProperties.ORIGINAL_PORT_CONSTRAINTS) as? PortConstraints ?? .UNDEFINED
            switch originalPC {
            case .UNDEFINED, .FREE:
                // Assign port sides first, then fall through to restore
                portSideAssigner.assignPortSides(slHolder)
                fallthrough
            case .FIXED_SIDE:
                computeSelfLoopTypes(slHolder)
                portRestorer.restorePorts(slHolder, monitor)
            default:
                break
            }
        } else {
            computeSelfLoopTypes(slHolder)
        }
    }

    private func computeSelfLoopTypes(_ slHolder: SelfLoopHolder) {
        for slLoop in slHolder.getSLHyperLoops() {
            slLoop.computePortsPerSide()
        }
    }
}
