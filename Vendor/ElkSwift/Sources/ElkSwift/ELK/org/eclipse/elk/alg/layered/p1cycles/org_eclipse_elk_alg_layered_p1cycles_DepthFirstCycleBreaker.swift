// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p1cycles/DepthFirstCycleBreaker.java

import Foundation

package class org_eclipse_elk_alg_layered_p1cycles_DepthFirstCycleBreaker {
    package static let INTERMEDIATE_PROCESSING_CONFIGURATION =
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addAfter(
                org_eclipse_elk_alg_layered_LayeredPhases.P5_EDGE_ROUTING,
                org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy.REVERSED_EDGE_RESTORER
            )

    package var sources: [org_eclipse_elk_alg_layered_graph_LNode]?
    package var visited: [Bool]?
    package var active: [Bool]?
    package var edgesToBeReversed: [org_eclipse_elk_alg_layered_graph_LEdge]?

    package init() {}

    package func getLayoutProcessorConfiguration(
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph
    ) -> LayoutProcessorConfiguration<LayeredPhases, LGraph>? {
        _ = graph
        return Self.INTERMEDIATE_PROCESSING_CONFIGURATION
    }

    package func process(
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ monitor: any org_eclipse_elk_core_util_IElkProgressMonitor
    ) {
        beginMonitor(monitor, "Depth-first cycle removal", 1)

        let nodes = graph.getLayerlessNodes()
        let nodeCount = nodes.count

        sources = []
        visited = Array(repeating: false, count: nodeCount)
        active = Array(repeating: false, count: nodeCount)
        edgesToBeReversed = []

        for (index, node) in nodes.enumerated() {
            node.id = index
            if node.getIncomingEdges().isEmpty {
                sources?.append(node)
            }
        }

        if let localSources = sources {
            for source in localSources {
                dfs(source)
            }
        }

        for index in 0..<nodeCount {
            guard let seen = visited, !seen[index] else {
                continue
            }
            let node = nodes[index]
            dfs(node)
        }

        if let reversed = edgesToBeReversed {
            for edge in reversed {
                reverse(edge, in: graph)
                graph.setProperty(org_eclipse_elk_alg_layered_options_InternalProperties.CYCLIC, true)
            }
        }

        sources = nil
        visited = nil
        active = nil
        edgesToBeReversed = nil
        doneMonitor(monitor)
    }

    package func dfs(_ node: org_eclipse_elk_alg_layered_graph_LNode) {
        guard var seen = visited, var activeFlags = active else {
            return
        }
        if seen[node.id] {
            return
        }

        seen[node.id] = true
        activeFlags[node.id] = true
        visited = seen
        active = activeFlags

        for outgoing in node.getOutgoingEdges() {
            if outgoing.isSelfLoop() {
                continue
            }
            guard let target = outgoing.getTarget()?.getNode() else {
                continue
            }

            if active?[target.id] == true {
                edgesToBeReversed?.append(outgoing)
            } else {
                dfs(target)
            }
        }

        active?[node.id] = false
    }

    package func reverse(
        _ edge: org_eclipse_elk_alg_layered_graph_LEdge,
        in graph: org_eclipse_elk_alg_layered_graph_LGraph
    ) {
        edge.reverse(graph, true)
    }

    package func beginMonitor(
        _ monitor: any org_eclipse_elk_core_util_IElkProgressMonitor,
        _ taskName: String,
        _ totalWork: Int
    ) {
        (monitor as? _DepthFirstCycleBreakerProgressMonitorCompat)?.begin(taskName, totalWork)
    }

    package func doneMonitor(_ monitor: any org_eclipse_elk_core_util_IElkProgressMonitor) {
        (monitor as? _DepthFirstCycleBreakerProgressMonitorCompat)?.done()
    }
}

package protocol _DepthFirstCycleBreakerProgressMonitorCompat {
    func begin(_ taskName: String, _ totalWork: Int)
    func done()
}
