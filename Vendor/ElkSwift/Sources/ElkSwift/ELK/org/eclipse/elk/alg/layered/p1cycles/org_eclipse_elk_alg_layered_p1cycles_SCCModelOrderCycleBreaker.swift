// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p1cycles/SCCModelOrderCycleBreaker.java

import Foundation

package class org_eclipse_elk_alg_layered_p1cycles_SCCModelOrderCycleBreaker {
    /// List of strongly connected components calculated by tarjan.
    package var stronglyConnectedComponents: [[org_eclipse_elk_alg_layered_graph_LNode]] = []

    /// Maps node to id of its strongly connected component.
    package var nodeToSCCID: [LNode: Int] = [:]

    /// The edges to reverse.
    package var revEdges: [org_eclipse_elk_alg_layered_graph_LEdge] = []

    /// The graph.
    package var graph: org_eclipse_elk_alg_layered_graph_LGraph?

    package static let INTERMEDIATE_PROCESSING_CONFIGURATION =
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addAfter(
                org_eclipse_elk_alg_layered_LayeredPhases.P5_EDGE_ROUTING,
                org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy.REVERSED_EDGE_RESTORER
            )

    package init() {}

    package func getLayoutProcessorConfiguration(
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph
    ) -> LayoutProcessorConfiguration<LayeredPhases, LGraph>? {
        _ = graph
        return Self.INTERMEDIATE_PROCESSING_CONFIGURATION
    }

    package func process(
        _ layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ monitor: any org_eclipse_elk_core_util_IElkProgressMonitor
    ) {
        beginMonitor(monitor, "Model order cycle breaking", 1)

        graph = layeredGraph
        revEdges.removeAll(keepingCapacity: false)

        // One needs an offset to make sure that the model order of nodes with port constraints
        // is always lower/higher than that of other nodes.
        let offset = max(layeredGraph.getLayerlessNodes().count, maxModelOrderNodesFallback(for: layeredGraph))
        let bigOffset = offset * cbNumModelOrderGroupsFallback(for: layeredGraph)

        while true {
            var tarjan = Tarjan(
                edgesToBeReversed: revEdges,
                stronglyConnectedComponents: &stronglyConnectedComponents,
                nodeToSCCID: &nodeToSCCID
            )
            tarjan.resetTarjan(layeredGraph)
            tarjan.tarjan(layeredGraph)

            stronglyConnectedComponents = tarjan.stronglyConnectedComponents
            nodeToSCCID = tarjan.nodeToSCCID

            // If no strongly connected components remain, the graph is acyclic.
            if stronglyConnectedComponents.isEmpty {
                break
            }

            // highest model order only incoming
            findNodes(offset, bigOffset)

            // reverse the gathered edges
            for edge in revEdges {
                reverse(edge, in: layeredGraph)
                layeredGraph.setProperty(org_eclipse_elk_alg_layered_options_InternalProperties.CYCLIC, true)
            }

            stronglyConnectedComponents.removeAll(keepingCapacity: false)
            nodeToSCCID.removeAll(keepingCapacity: false)
            revEdges.removeAll(keepingCapacity: false)
        }

        doneMonitor(monitor)
    }

    /// Java: SCCModelOrderCycleBreaker#findNodes(int offset, int bigOffset)
    package func findNodes(_ offset: Int, _ bigOffset: Int) {
        let calculator = org_eclipse_elk_alg_layered_p1cycles_GroupModelOrderCalculator()
        let enforceGroupModelOrder = shouldEnforceGroupModelOrder()

        // All strongly connected components have one maximum element for which we can reverse all outgoing edges.
        for component in stronglyConnectedComponents {
            var maxNode: org_eclipse_elk_alg_layered_graph_LNode?
            var maxModelOrder = Int.min

            for node in component {
                let currentModelOrder = enforceGroupModelOrder
                    ? calculator.computeConstraintGroupModelOrder(node, bigOffset, offset)
                    : calculator.computeConstraintModelOrder(node, offset)

                if maxNode == nil || maxModelOrder < currentModelOrder {
                    maxNode = node
                    maxModelOrder = currentModelOrder
                }
            }

            guard let maxNode else {
                continue
            }

            for edge in maxNode.getOutgoingEdges() {
                // Reverse all edges to the same strongly connected component.
                if let targetNode = edge.getTarget()?.getNode(), containsIdentity(targetNode, in: component) {
                    revEdges.append(edge)
                }
            }
        }
    }

    package func shouldEnforceGroupModelOrder() -> Bool {
        org_eclipse_elk_alg_layered_p1cycles_ModelOrderPropertyScaffolding
            .groupOrderStrategy(for: graph) == .ENFORCED
    }

    package func maxModelOrderNodesFallback(for graph: org_eclipse_elk_alg_layered_graph_LGraph) -> Int {
        org_eclipse_elk_alg_layered_p1cycles_ModelOrderPropertyScaffolding
            .maxModelOrderNodes(for: graph) ?? 1
    }

    package func cbNumModelOrderGroupsFallback(for graph: org_eclipse_elk_alg_layered_graph_LGraph) -> Int {
        org_eclipse_elk_alg_layered_p1cycles_ModelOrderPropertyScaffolding
            .cbNumModelOrderGroups(for: graph) ?? 1
    }

    package func reverse(
        _ edge: org_eclipse_elk_alg_layered_graph_LEdge,
        in layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph
    ) {
        edge.reverse(layeredGraph, false)
    }

    package func containsIdentity(
        _ node: org_eclipse_elk_alg_layered_graph_LNode,
        in component: [org_eclipse_elk_alg_layered_graph_LNode]
    ) -> Bool {
        component.contains(where: { $0 === node })
    }

    package func beginMonitor(
        _ monitor: any org_eclipse_elk_core_util_IElkProgressMonitor,
        _ taskName: String,
        _ totalWork: Int
    ) {
        (monitor as? _SCCModelOrderCycleBreakerProgressMonitorCompat)?.begin(taskName, totalWork)
    }

    package func doneMonitor(_ monitor: any org_eclipse_elk_core_util_IElkProgressMonitor) {
        (monitor as? _SCCModelOrderCycleBreakerProgressMonitorCompat)?.done()
    }
}

package protocol _SCCModelOrderCycleBreakerProgressMonitorCompat {
    func begin(_ taskName: String, _ totalWork: Int)
    func done()
}
