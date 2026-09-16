import Foundation

/**
 * A graph structure used by the NetworkSimplex algorithm.
 * The class holds a list of nodes and provides some convenient methods.
 */
package class NGraph {
    
    // SUPPRESS CHECKSTYLE NEXT 2 VisibilityModifier
    /** The nodes of the network simplex graph. */
    package var nodes = [NNode]()
    
    /**
     * Converts this NGraph to a KGraph and writes it to the specified file.
     * Note: Debug graph writing is not supported in Swift transpilation.
     *
     * - Parameter filePath: A path to a file on the filesystem
     */
    package func writeDebugGraph(filePath: String) {
        // Debug graph writing not available in Swift transpilation
    }
    
    /**
     * Checks if this NGraph is connected. If not, it identifies one representative per connected component
     * and connects each of them to a new artificial root node.
     *
     * - Returns: The artificial root node if created, otherwise nil.
     */
    package func makeConnected() -> NNode? {
        var id = 0
        for n in nodes {
            n.internalId = id
            id += 1
        }
        let ccRep = findConCompRepresentatives()
        var root: NNode? = nil
        if ccRep.count > 1 {
            root = createArtificialRootAndConnect(nodesToConnect: ccRep)
        }
        return root
    }
    
    /**
     * Creates and returns a new NNode and connects the passed nodesToConnect
     * to the new node with zero-weight, zero-delta edges.
     */
    package func createArtificialRootAndConnect(nodesToConnect: [NNode]) -> NNode {
        let root = NNode.of().create(self)
        for src in nodesToConnect {
            NEdge.of()
                .delta(0)
                .weight(0)
                .source(root)
                .target(src)
                .create()
        }
        return root
    }
    
    /**
     * Identifies and returns one representative NNode per connected component.
     */
    package func findConCompRepresentatives() -> [NNode] {
        var ccRep = [NNode]()
        var mark = Array(repeating: false, count: nodes.count)
        for node in nodes {
            if !mark[node.internalId] {
                ccRep.append(node)
                dfs(node: node, mark: &mark)
            }
        }
        return ccRep
    }
    
    package func dfs(node: NNode, mark: inout [Bool]) {
        if mark[node.internalId] {
            return
        }
        mark[node.internalId] = true
        for edge in node.getConnectedEdges() {
            let other = edge.getOther(node)
            dfs(node: other, mark: &mark)
        }
    }
    
    /**
     * Creates a topological ordering and checks for back edges.
     *
     * - Returns: true if the graph is acyclic, false if it is cyclic.
     */
    package func isAcyclic() -> Bool {
        
        var id = 0
        for n in nodes {
            n.internalId = id
            id += 1
        }
        
        // initialize the number of incident edges for each node
        var incident = Array(repeating: 0, count: nodes.count)
        var layer = Array(repeating: 0, count: nodes.count)
        for node in nodes {
            incident[node.internalId] += node.getIncomingEdges().count
        }
        
        var roots = ArrayDeque<NNode>()
        for node in nodes {
            if node.getIncomingEdges().isEmpty {
                roots.append(node)
            }
        }
        if roots.isEmpty && !nodes.isEmpty {
            return false
        }
        while !roots.isEmpty {
            let node = roots.removeFirst()
            
            for edge in node.getOutgoingEdges() {
                guard let tgt = edge.target else { continue }
                layer[tgt.internalId] = max(layer[tgt.internalId], layer[node.internalId] + 1)
                incident[tgt.internalId] -= 1
                if incident[tgt.internalId] == 0 {
                    roots.append(tgt)
                }
            }
        }

        // check for backward edges
        for node in nodes {
            for edge in node.getOutgoingEdges() {
                guard let tgt = edge.target, let src = edge.source else { continue }
                if layer[tgt.internalId] <= layer[src.internalId] {
                    return false
                }
            }
        }
        
        return true
    }
}
