import Foundation

/**
 * Compares cross-hierarchy edge segments such that they can be sorted from the start to the end
 * segment.
 */
package final class CrossHierarchyEdgeComparator {
    package let graph: LGraph

    /**
     * Creates a new comparator for sorting cross-hierarchy edge segments for the given top-level
     * compound graph.
     *
     * @param graph the top-level compound graph.
     */
    package init(_ graph: LGraph) {
        self.graph = graph
    }

    package func compare(_ edge1: CrossHierarchyEdge, _ edge2: CrossHierarchyEdge) -> ComparisonResult {
        if edge1.type == PortType.output && edge2.type == PortType.input {
            return .orderedAscending
        } else if edge1.type == PortType.input && edge2.type == PortType.output {
            return .orderedDescending
        }

        let level1 = CrossHierarchyEdgeComparator.hierarchyLevel(edge1.graph, top: graph)
        let level2 = CrossHierarchyEdgeComparator.hierarchyLevel(edge2.graph, top: graph)

        let diff: Int
        if edge1.type == PortType.output {
            // from deeper level to higher level
            diff = level2 - level1
        } else {
            // from higher level to deeper level
            diff = level1 - level2
        }

        if diff < 0 { return .orderedAscending }
        if diff > 0 { return .orderedDescending }
        return .orderedSame
    }

    /**
     * Compute the hierarchy level of the given nested graph.
     *
     * @param nestedGraph a nested graph
     * @param topLevelGraph the top-level graph
     * @return the hierarchy level (higher number means the node is nested deeper)
     */
    package static func hierarchyLevel(_ nestedGraph: LGraph, top topLevelGraph: LGraph) -> Int {
        var currentGraph = nestedGraph
        var level = 0

        while true {
            if currentGraph === topLevelGraph {
                return level
            }

            guard let currentNode = currentGraph.parentNode else {
                // the given node is not an ancestor of the graph node
                assertionFailure("Invalid hierarchy: nestedGraph is not nested within topLevelGraph")
                return level
            }

            guard let graph = currentNode.graph else {
                assertionFailure("Invalid hierarchy: node has no graph")
                return level
            }
            currentGraph = graph
            level += 1
        }
    }
}
