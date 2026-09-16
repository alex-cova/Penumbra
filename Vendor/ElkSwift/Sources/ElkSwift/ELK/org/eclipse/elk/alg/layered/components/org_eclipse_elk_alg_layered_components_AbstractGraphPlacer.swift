import Foundation

/**
 * Takes a list of layered graphs and combines them into a single graph, placing them according to some
 * algorithm.
 */
package class AbstractGraphPlacer {

    /**
     * Computes a proper placement for the given graphs and combines them into a single graph.
     *
     * @param components the graphs to be combined.
     * @param target the target graph into which the others shall be combined
     */
    package func combine(_ components: [LGraph], target: LGraph) { assertionFailure("Subclass must override") }

    /**
     * Move the source graphs into the destination graph using a specified offset.
     */
    package func moveGraphs(_ destGraph: LGraph, _ sourceGraphs: [LGraph], _ offsetx: Double, _ offsety: Double) {
        for sourceGraph in sourceGraphs {
            moveGraph(destGraph, sourceGraph, offsetx, offsety)
        }
    }

    /**
     * Move the source graph into the destination graph using a specified offset.
     */
    package func moveGraph(_ destGraph: LGraph, _ sourceGraph: LGraph, _ offsetx: Double, _ offsety: Double) {
        let graphOffset = sourceGraph.offset.clone().add(KVector(x: offsetx, y: offsety))

        for node in sourceGraph.layerlessNodes {
            node.position.add(graphOffset)
            for port in node.ports {
                for edge in port.outgoingEdges {
                    edge.bendPoints.offset(graphOffset)
                    if let junctionPoints: KVectorChain = edge.getProperty(LayeredOptions.JUNCTION_POINTS) {
                        junctionPoints.offset(graphOffset)
                    }
                    for label in edge.labels {
                        label.position.add(graphOffset)
                    }
                }
            }
            destGraph.layerlessNodes.append(node)
            node.graph = destGraph
        }
    }

    /**
     * Offsets the given graphs by a given offset without moving their nodes to another graph.
     */
    package func offsetGraphs(_ graphs: [LGraph], _ offsetx: Double, _ offsety: Double) {
        for graph in graphs {
            offsetGraph(graph, offsetx, offsety)
        }
    }

    /**
     * Offsets the given graph by a given offset without moving its nodes to another graph.
     */
    package func offsetGraph(_ graph: LGraph, _ offsetx: Double, _ offsety: Double) {
        let graphOffset = KVector(x: offsetx, y: offsety)

        for node in graph.layerlessNodes {
            node.position.add(graphOffset)
            for port in node.ports {
                for edge in port.outgoingEdges {
                    edge.bendPoints.offset(graphOffset)
                    if let junctionPoints: KVectorChain = edge.getProperty(LayeredOptions.JUNCTION_POINTS) {
                        junctionPoints.offset(graphOffset)
                    }
                    for label in edge.labels {
                        label.position.add(graphOffset)
                    }
                }
            }
        }
    }
}
