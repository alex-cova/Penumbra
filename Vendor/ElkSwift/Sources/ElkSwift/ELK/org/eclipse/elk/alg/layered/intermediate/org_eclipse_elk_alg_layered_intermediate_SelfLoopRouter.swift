import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_SelfLoopRouter: ILayoutProcessor {
    package typealias G = LGraph

    private let routingDirector = RoutingDirector()
    private let labelPlacer = org_eclipse_elk_alg_layered_intermediate_loops_routing_LabelPlacer()
    private let routingSlotAssigner = RoutingSlotAssigner()

    package init() {}

    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {
        progressMonitor.begin("Self-Loop routing", 1)

        let router = routerForGraph(graph)
        let labelManager = graph.getProperty(LabelManagementOptions.LABEL_MANAGER) as? ILabelManager

        for layer in graph.getLayers() {
            for lNode in layer.getNodes() {
                if lNode.getType() == .NORMAL && lNode.hasProperty(InternalProperties.SELF_LOOP_HOLDER) {
                    if let slHolder = lNode.getProperty(InternalProperties.SELF_LOOP_HOLDER) as? SelfLoopHolder {
                        processNode(slHolder, labelManager, router, progressMonitor)
                    }
                }
            }
        }

        progressMonitor.done()
    }

    private func routerForGraph(_ graph: LGraph) -> AbstractSelfLoopRouter {
        if let edgeRouting = graph.getProperty(LayeredOptions.EDGE_ROUTING) as? EdgeRouting {
            switch edgeRouting {
            case .POLYLINE:
                return PolylineSelfLoopRouter()
            case .SPLINES:
                // Spline routing not supported (mermaid hard-codes ORTHOGONAL); fall through to orthogonal
                return OrthogonalSelfLoopRouter()
            default:
                return OrthogonalSelfLoopRouter()
            }
        }
        return OrthogonalSelfLoopRouter()
    }

    private func processNode(_ slHolder: SelfLoopHolder, _ labelManager: ILabelManager?,
                               _ slRouter: AbstractSelfLoopRouter, _ monitor: IElkProgressMonitor) {
        routingDirector.determineLoopRoutes(slHolder)
        labelPlacer.placeLabels(slHolder, labelManager, monitor)
        routingSlotAssigner.assignRoutingSlots(slHolder)
        slRouter.routeSelfLoops(slHolder)
    }
}
