import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_SelfLoopPreProcessor: ILayoutProcessor {
    package typealias G = LGraph

    package init() {}

    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {
        progressMonitor.begin("Self-Loop pre-processing", 1)

        for lnode in graph.getLayerlessNodes() {
            if SelfLoopHolder.needsSelfLoopProcessing(lnode) {
                let slHolder = SelfLoopHolder.install(lnode)
                hideSelfLoops(slHolder)
                hidePorts(slHolder)
            }
        }

        progressMonitor.done()
    }

    private func hideSelfLoops(_ slHolder: SelfLoopHolder) {
        for slLoop in slHolder.getSLHyperLoops() {
            for slEdge in slLoop.getSLEdges() {
                let lEdge = slEdge.getLEdge()
                lEdge.setSource(nil)
                lEdge.setTarget(nil)
            }
        }
    }

    private func hidePorts(_ slHolder: SelfLoopHolder) {
        let lNode = slHolder.getLNode()
        let nestedGraph = lNode.getNestedGraph()

        let orderFixed: Bool = (lNode.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints)?.isOrderFixed() ?? false
        let hierarchyMode: Bool = nestedGraph != nil
            && ((nestedGraph?.getProperty(InternalProperties.GRAPH_PROPERTIES) as? Set<GraphProperties>)?
                .contains(.EXTERNAL_PORTS) ?? false)

        if orderFixed || hierarchyMode {
            return
        }

        for slPort in slHolder.getSLPortValues() {
            if slPort.hadOnlySelfLoops() {
                let lPort = slPort.getLPort()
                lPort.setNode(nil)

                slPort.setHidden(true)
                slHolder.setPortsHidden(true)
            }
        }
    }
}
