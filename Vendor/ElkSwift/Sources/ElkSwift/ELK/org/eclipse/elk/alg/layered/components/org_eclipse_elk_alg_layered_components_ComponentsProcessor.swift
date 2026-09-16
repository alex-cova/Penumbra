import Foundation

/**
 * A processor that is able to split an input graph into connected components and to pack those
 * components after layout.
 */
package final class ComponentsProcessor {

    /** Cached instance of a ComponentGroupGraphPlacer. */
    package let componentGroupGraphPlacer = ComponentGroupGraphPlacer()
    /** Cached instance of a ComponentGroupModelOrderGraphPlacer. */
    package let componentGroupModelOrderGraphPlacer = ComponentGroupModelOrderGraphPlacer()
    /** Cached instance of a ModelOrderRowGraphPlacer. */
    package let modelOrderRowGraphPlacer = ModelOrderRowGraphPlacer()
    /** Cached instance of a SimpleRowGraphPlacer. */
    package let simpleRowGraphPlacer = SimpleRowGraphPlacer()
    /** Graph placer to be used to combine the different components back into a single graph. */
    package lazy var graphPlacer: AbstractGraphPlacer = simpleRowGraphPlacer

    /**
     * Split the given graph into its connected components.
     */
    package func split(_ graph: LGraph) -> [LGraph] {
        var result: [LGraph] = []

        // Default to the simple graph placer
        graphPlacer = simpleRowGraphPlacer

        // Whether separate components processing is requested
        let separateProperty: Bool? = graph.getProperty(LayeredOptions.SEPARATE_CONNECTED_COMPONENTS)
        let separate = separateProperty ?? true

        // Whether the graph contains external ports
        let graphProperties: Set<GraphProperties> = graph.getProperty(InternalProperties.GRAPH_PROPERTIES) ?? []
        let extPorts = graphProperties.contains(.EXTERNAL_PORTS)

        // The graph's external port constraints
        let extPortConstraints: PortConstraints = graph.getProperty(LayeredOptions.PORT_CONSTRAINTS) ?? .UNDEFINED
        let compatiblePortConstraints = !extPortConstraints.isOrderFixed()

        if separate && (compatiblePortConstraints || !extPorts) {
            // Set id of all nodes to 0
            for node in graph.layerlessNodes {
                node.id = 0
            }

            // Perform DFS starting on each node, collecting connected components
            result = []
            for node in graph.layerlessNodes {
                let componentData = dfs(node, data: nil)

                if let componentData {
                    let newGraph = LGraph()

                    newGraph.copyProperties(from: graph)
                    newGraph.setProperty(InternalProperties.EXT_PORT_CONNECTIONS, value: componentData.first)
                    newGraph.padding.copy(graph.padding)

                    // Remove minimum size on separated graphs
                    newGraph.setProperty(LayeredOptions.NODE_SIZE_MINIMUM, value: nil)

                    for n in componentData.second ?? [] {
                        newGraph.layerlessNodes.append(n)
                        n.setGraph(newGraph)
                    }

                    result.append(newGraph)
                }
            }

            if extPorts {
                let considerModelOrder: ComponentOrderingStrategy? = graph.getProperty(LayeredOptions.CONSIDER_MODEL_ORDER_COMPONENTS)
                if considerModelOrder == ComponentOrderingStrategy.GROUP_MODEL_ORDER {
                    graphPlacer = componentGroupModelOrderGraphPlacer
                } else if considerModelOrder == ComponentOrderingStrategy.MODEL_ORDER {
                    graphPlacer = modelOrderRowGraphPlacer
                } else {
                    graphPlacer = componentGroupGraphPlacer
                }
            }
        } else {
            result = [graph]
        }

        // Sort by model order if needed
        let considerModelOrder: ComponentOrderingStrategy? = graph.getProperty(LayeredOptions.CONSIDER_MODEL_ORDER_COMPONENTS)
        if considerModelOrder != nil && considerModelOrder != ComponentOrderingStrategy.NONE {
            result.sort { (g1, g2) -> Bool in
                let g1Order = LGraphUtil.getMinimalModelOrder(g1)
                let g2Order = LGraphUtil.getMinimalModelOrder(g2)
                return g1Order < g2Order
            }
        }

        return result
    }

    /**
     * Perform a DFS starting on the given node, collect all nodes that are found in the corresponding
     * connected component and return the set of external port sides the component connects to.
     */
    package func dfs(_ node: LNode, data: Pair<Set<PortSide>, [LNode]>?) -> Pair<Set<PortSide>, [LNode]>? {

        if node.id == 0 {
            // Mark the node as visited
            node.id = 1

            let mutableData = data ?? Pair(first: Set<PortSide>(), second: [LNode]())

            // Add this node to the component
            mutableData.second?.append(node)

            // Check if this node is an external port dummy and, if so, add its side
            if node.type == NodeType.EXTERNAL_PORT {
                if let extPortSide: PortSide = node.getProperty(InternalProperties.EXT_PORT_SIDE) {
                    mutableData.first?.insert(extPortSide)
                }
            }

            // DFS
            for port1 in node.ports {
                for port2 in port1.getConnectedPorts() {
                    if let connectedNode = port2.node {
                        _ = dfs(connectedNode, data: mutableData)
                    }
                }
            }

            return mutableData
        }

        return nil
    }

    /**
     * Combine the given components into a single graph.
     */
    package func combine(_ components: [LGraph], target: LGraph) {
        graphPlacer.combine(components, target: target)
    }
}
