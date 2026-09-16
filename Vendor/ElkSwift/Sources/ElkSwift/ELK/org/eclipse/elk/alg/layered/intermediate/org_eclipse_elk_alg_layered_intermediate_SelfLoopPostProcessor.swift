import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_SelfLoopPostProcessor: ILayoutProcessor {
    package typealias G = LGraph

    package init() {}

    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {
        progressMonitor.begin("Self-Loop post-processing", 1)

        for layer in graph.getLayers() {
            for lNode in layer.getNodes() {
                if lNode.getType() == .NORMAL && lNode.hasProperty(InternalProperties.SELF_LOOP_HOLDER) {
                    processNode(lNode)
                }
            }
        }

        progressMonitor.done()
    }

    private func processNode(_ lNode: LNode) {
        guard let slHolder = lNode.getProperty(InternalProperties.SELF_LOOP_HOLDER) as? SelfLoopHolder else { return }

        for slLoop in slHolder.getSLHyperLoops() {
            for slEdge in slLoop.getSLEdges() {
                restoreEdge(lNode, slEdge)
            }
        }

        for slLoop in slHolder.getSLHyperLoops() {
            if let slLabels = slLoop.getSLLabels() {
                slLabels.applyPlacement(lNode.getPosition())
            }
        }
    }

    private func restoreEdge(_ lNode: LNode, _ slEdge: SelfLoopEdge) {
        let lEdge = slEdge.getLEdge()
        lEdge.setSource(slEdge.getSLSource().getLPort())
        lEdge.setTarget(slEdge.getSLTarget().getLPort())

        _ = lEdge.getBendPoints().offset(lNode.getPosition())
    }
}
