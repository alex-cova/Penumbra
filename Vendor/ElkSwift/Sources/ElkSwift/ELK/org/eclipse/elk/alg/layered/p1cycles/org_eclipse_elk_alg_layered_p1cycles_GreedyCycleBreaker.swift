// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p1cycles/GreedyCycleBreaker.java

import Foundation

package class org_eclipse_elk_alg_layered_p1cycles_GreedyCycleBreaker {
    package static let INTERMEDIATE_PROCESSING_CONFIGURATION =
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addAfter(
                org_eclipse_elk_alg_layered_LayeredPhases.P5_EDGE_ROUTING,
                org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy.REVERSED_EDGE_RESTORER
            )

    package var indeg: [Int]?
    package var outdeg: [Int]?
    package var mark: [Int]?
    package var sources = ArrayDeque<org_eclipse_elk_alg_layered_graph_LNode>()
    package var sinks = ArrayDeque<org_eclipse_elk_alg_layered_graph_LNode>()

    // Protected in Java; kept overridable for subclasses.
    internal var layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph?

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
        beginMonitor(monitor, "Greedy cycle removal", 1)
        self.layeredGraph = layeredGraph

        let nodes = layeredGraph.getLayerlessNodes()
        var unprocessedNodeCount = nodes.count

        indeg = Array(repeating: 0, count: unprocessedNodeCount)
        outdeg = Array(repeating: 0, count: unprocessedNodeCount)
        mark = Array(repeating: 0, count: unprocessedNodeCount)

        for (index, node) in nodes.enumerated() {
            node.id = index

            for port in node.getPorts() {
                for edge in port.getIncomingEdges() {
                    if edge.getSource()?.getNode() === node {
                        continue
                    }
                    indeg?[index] += edgeWeight(edge)
                }
                for edge in port.getOutgoingEdges() {
                    if edge.getTarget()?.getNode() === node {
                        continue
                    }
                    outdeg?[index] += edgeWeight(edge)
                }
            }

            if outdeg?[index] == 0 {
                sinks.append(node)
            } else if indeg?[index] == 0 {
                sources.append(node)
            }
        }

        var nextRight = -1
        var nextLeft = 1
        var maxNodes: [org_eclipse_elk_alg_layered_graph_LNode] = []

        while unprocessedNodeCount > 0 {
            while !sinks.isEmpty {
                let sink = sinks.removeFirst()
                mark?[sink.id] = nextRight
                nextRight -= 1
                updateNeighbors(sink)
                unprocessedNodeCount -= 1
            }

            while !sources.isEmpty {
                let source = sources.removeFirst()
                mark?[source.id] = nextLeft
                nextLeft += 1
                updateNeighbors(source)
                unprocessedNodeCount -= 1
            }

            if unprocessedNodeCount > 0 {
                var maxOutflow = Int.min
                maxNodes.removeAll(keepingCapacity: true)

                for node in nodes {
                    guard mark?[node.id] == 0, let out = outdeg?[node.id], let `in` = indeg?[node.id] else {
                        continue
                    }
                    let outflow = out - `in`
                    if outflow >= maxOutflow {
                        if outflow > maxOutflow {
                            maxNodes.removeAll(keepingCapacity: true)
                            maxOutflow = outflow
                        }
                        maxNodes.append(node)
                    }
                }

                if !maxNodes.isEmpty {
                    let maxNode = chooseNodeWithMaxOutflow(maxNodes)
                    mark?[maxNode.id] = nextLeft
                    nextLeft += 1
                    updateNeighbors(maxNode)
                    unprocessedNodeCount -= 1
                } else {
                    break
                }
            }
        }

        let shiftBase = nodes.count + 1
        for index in 0..<nodes.count {
            if let value = mark?[index], value < 0 {
                mark?[index] = value + shiftBase
            }
        }

        for node in nodes {
            let ports = LGraphUtil.toPortArray(node.getPorts())
            for port in ports {
                let outgoingEdges = LGraphUtil.toEdgeArray(port.getOutgoingEdges())
                for edge in outgoingEdges {
                    guard let targetIx = edge.getTarget()?.getNode()?.id,
                          let sourceMark = mark?[node.id],
                          let targetMark = mark?[targetIx] else {
                        continue
                    }
                    if sourceMark > targetMark {
                        reverse(edge, in: layeredGraph)
                        layeredGraph.setProperty(org_eclipse_elk_alg_layered_options_InternalProperties.CYCLIC, true)
                    }
                }
            }
        }

        dispose()
        doneMonitor(monitor)
    }

    package func chooseNodeWithMaxOutflow(
        _ nodes: [org_eclipse_elk_alg_layered_graph_LNode]
    ) -> org_eclipse_elk_alg_layered_graph_LNode {
        guard let first = nodes.first else {
            assertionFailure("chooseNodeWithMaxOutflow called with empty nodes")
            return LNode(LGraph())
        }
        if let rng = layeredGraph?.getProperty(org_eclipse_elk_alg_layered_options_InternalProperties.RANDOM) as? Random {
            return nodes[rng.nextInt(nodes.count)]
        }
        if nodes.count == 1 { return first }
        return nodes[Int.random(in: 0..<nodes.count)]
    }

    package func dispose() {
        indeg = nil
        outdeg = nil
        mark = nil
        sources.removeAll(keepingCapacity: false)
        sinks.removeAll(keepingCapacity: false)
    }

    package func updateNeighbors(_ node: org_eclipse_elk_alg_layered_graph_LNode) {
        for port in node.getPorts() {
            for edge in port.getConnectedEdges() {
                let connectedPort: org_eclipse_elk_alg_layered_graph_LPort?
                if edge.getSource() === port {
                    connectedPort = edge.getTarget()
                } else {
                    connectedPort = edge.getSource()
                }
                guard let endpointPort = connectedPort, let endpoint = endpointPort.getNode() else {
                    continue
                }

                if node === endpoint {
                    continue
                }

                let index = endpoint.id
                // Safety: skip nodes from a different graph (e.g. cross-hierarchy edges)
                guard index >= 0, index < (mark?.count ?? 0), mark?[index] == 0 else {
                    continue
                }

                let weight = edgeWeight(edge)
                if edge.getTarget() === endpointPort {
                    if let incoming = indeg?[index] {
                        indeg?[index] = incoming - weight
                    }
                    if (indeg?[index] ?? 0) <= 0, (outdeg?[index] ?? 0) > 0 {
                        sources.append(endpoint)
                    }
                } else {
                    if let outgoing = outdeg?[index] {
                        outdeg?[index] = outgoing - weight
                    }
                    if (outdeg?[index] ?? 0) <= 0, (indeg?[index] ?? 0) > 0 {
                        sinks.append(endpoint)
                    }
                }
            }
        }
    }

    package func edgeWeight(_ edge: org_eclipse_elk_alg_layered_graph_LEdge) -> Int {
        let priority = edge.getProperty(org_eclipse_elk_alg_layered_options_LayeredOptions.PRIORITY_DIRECTION) as? Int ?? 0
        return max(priority, 0) + 1
    }

    package func reverse(
        _ edge: org_eclipse_elk_alg_layered_graph_LEdge,
        in layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph
    ) {
        edge.reverse(layeredGraph, true)
    }

    package func beginMonitor(
        _ monitor: any org_eclipse_elk_core_util_IElkProgressMonitor,
        _ taskName: String,
        _ totalWork: Int
    ) {
        (monitor as? _GreedyCycleBreakerProgressMonitorCompat)?.begin(taskName, totalWork)
    }

    package func doneMonitor(_ monitor: any org_eclipse_elk_core_util_IElkProgressMonitor) {
        (monitor as? _GreedyCycleBreakerProgressMonitorCompat)?.done()
    }
}

package protocol _GreedyCycleBreakerProgressMonitorCompat {
    func begin(_ taskName: String, _ totalWork: Int)
    func done()
}
