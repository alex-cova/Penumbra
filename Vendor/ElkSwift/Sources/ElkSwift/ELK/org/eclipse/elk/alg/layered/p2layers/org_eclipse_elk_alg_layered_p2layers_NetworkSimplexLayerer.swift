import Foundation

package final class org_eclipse_elk_alg_layered_p2layers_NetworkSimplexLayerer {

    private static let ITER_LIMIT_FACTOR = 4

    private static let BASELINE_PROCESSING_CONFIGURATION: LayoutProcessorConfiguration<LayeredPhases, LGraph> = {
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(LayeredPhases.P1_CYCLE_BREAKING,
                IntermediateProcessorStrategy.EDGE_AND_LAYER_CONSTRAINT_EDGE_REVERSER)
            .addBefore(LayeredPhases.P2_LAYERING,
                IntermediateProcessorStrategy.LAYER_CONSTRAINT_PREPROCESSOR)
            .addBefore(LayeredPhases.P3_NODE_ORDERING,
                IntermediateProcessorStrategy.LAYER_CONSTRAINT_POSTPROCESSOR)
    }()

    private var componentNodes: [LNode] = []
    private var nodeVisited: [Bool] = []

    package init() {}

    package func getLayoutProcessorConfiguration(_ graph: LGraph) -> LayoutProcessorConfiguration<LayeredPhases, LGraph>? {
        return Self.BASELINE_PROCESSING_CONFIGURATION
    }

    package func process(_ graph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("Network simplex layering", 1)

        let thoroughness = (graph.getProperty(LayeredOptions.THOROUGHNESS) as? Int ?? 7) * Self.ITER_LIMIT_FACTOR

        let theNodes = graph.layerlessNodes
        if theNodes.count < 1 {
            monitor.done()
            return
        }

        // Layer graph, each connected component separately
        let connectedComps = connectedComponents(theNodes)
        var previousLayeringNodeCounts: [Int]? = nil

        for connComp in connectedComps {
            let iterLimit = thoroughness * Int(Double(connComp.count).squareRoot())

            let nGraph = initialize(connComp)

            // Execute the network simplex algorithm
            let ns = NetworkSimplex.forGraph(nGraph)
                .withIterationLimit(iterLimit)
                .withPreviousLayering(previousLayeringNodeCounts)
                .withBalancing(true)

            if let subMonitor = monitor.subTask(1) {
                ns.execute(subMonitor)
            } else {
                ns.execute()
            }

            // The layers are stored in the NNode's layer field
            for nNode in nGraph.nodes {
                while graph.layers.count <= nNode.layer {
                    graph.layers.append(Layer(graph))
                }
                guard let lNode = nNode.origin as? LNode else { continue }
                lNode.setLayer(graph.layers[nNode.layer])
            }

            if connectedComps.count > 1 {
                var counts = [Int](repeating: 0, count: graph.layers.count)
                for (layerIdx, l) in graph.layers.enumerated() {
                    counts[layerIdx] = l.nodes.count
                }
                previousLayeringNodeCounts = counts
            }
        }

        // Empty the list of unlayered nodes
        graph.layerlessNodes.removeAll()

        // Release resources
        dispose()
        monitor.done()
    }

    // MARK: - Connected Components

    private func connectedComponents(_ theNodes: [LNode]) -> [[LNode]] {
        if nodeVisited.count < theNodes.count {
            nodeVisited = [Bool](repeating: false, count: theNodes.count)
        } else {
            for i in 0..<nodeVisited.count {
                nodeVisited[i] = false
            }
        }
        componentNodes = []

        // Re-index nodes
        var counter = 0
        for node in theNodes {
            node.id = counter
            counter += 1
        }

        // Determine connected components
        var components = [[LNode]]()
        for node in theNodes {
            if !nodeVisited[node.id] {
                connectedComponentsDFS(node)
                // Connected component with the most nodes should be layered first
                if components.isEmpty || components[0].count < componentNodes.count {
                    components.insert(componentNodes, at: 0)
                } else {
                    components.append(componentNodes)
                }
                componentNodes = []
            }
        }
        return components
    }

    private func connectedComponentsDFS(_ node: LNode) {
        nodeVisited[node.id] = true
        componentNodes.append(node)

        for port in node.getPorts() {
            for edge in port.getConnectedEdges() {
                guard let opposite = getOpposite(port, edge).node else { continue }
                // Safety: skip nodes from a different graph (e.g. cross-hierarchy edges)
                guard opposite.id >= 0, opposite.id < nodeVisited.count else { continue }
                if !nodeVisited[opposite.id] {
                    connectedComponentsDFS(opposite)
                }
            }
        }
    }

    // MARK: - Initialize NGraph

    private func initialize(_ theNodes: [LNode]) -> NGraph {
        var nodeMap = [ObjectIdentifier: NNode]()

        let graph = NGraph()
        for lNode in theNodes {
            let nNode = NNode.of()
                .origin(lNode)
                .create(graph)
            nodeMap[ObjectIdentifier(lNode)] = nNode
        }

        for lNode in theNodes {
            for lEdge in lNode.getOutgoingEdges() {
                if lEdge.isSelfLoop() { continue }

                let priority = lEdge.getProperty(LayeredOptions.PRIORITY_SHORTNESS) as? Int ?? 0
                let weight = Double(1 * max(1, priority))

                guard let sourceNode = lEdge.source?.node,
                      let targetNode = lEdge.target?.node,
                      let nSource = nodeMap[ObjectIdentifier(sourceNode)],
                      let nTarget = nodeMap[ObjectIdentifier(targetNode)] else { continue }

                NEdge.of(lEdge)
                    .weight(weight)
                    .delta(1)
                    .source(nSource)
                    .target(nTarget)
                    .create()
            }
        }

        return graph
    }

    private func dispose() {
        componentNodes = []
        nodeVisited = []
    }

    private func getOpposite(_ port: LPort, _ edge: LEdge) -> LPort {
        if edge.source === port {
            guard let target = edge.target else { return port }
            return target
        } else {
            guard let source = edge.source else { return port }
            return source
        }
    }
}
