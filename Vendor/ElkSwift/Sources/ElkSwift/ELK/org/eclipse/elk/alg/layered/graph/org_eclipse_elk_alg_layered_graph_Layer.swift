import Foundation

/**
 * A layer in a layered graph.
 */
package final class Layer: LGraphElement {

    package var owner: LGraph
    package var size = KVector()
    package var nodes = [LNode]()

    package init(_ graph: LGraph) {
        self.owner = graph
    }

    package func getSize() -> KVector {
        return size
    }

    package func getNodes() -> [LNode] {
        return nodes
    }

    package func getGraph() -> LGraph {
        return owner
    }

    package func getIndex() -> Int {
        return owner.layers.firstIndex(where: { $0 === self }) ?? -1
    }

    /// Replaces the current nodes list with the given nodes, updating each node's layer reference.
    package func setNodes(_ nodes: [LNode]) {
        self.nodes = nodes
        for node in nodes {
            node.layer = self
        }
    }

    package func toString() -> String {
        return "L_\(getIndex())\(nodes)"
    }
}
