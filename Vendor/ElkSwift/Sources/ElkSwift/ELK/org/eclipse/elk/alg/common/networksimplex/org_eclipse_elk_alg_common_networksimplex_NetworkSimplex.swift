// Copyright (c) 2016 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

import Foundation

// MARK: - Supporting Types and Protocols
// MARK: - NetworkSimplex Class

/**
 The main class of the network simplex layerer component. It offers an algorithm to determine an
 optimal layering of all nodes in the graph concerning a minimal length of all edges using the
 network simplex algorithm described in
 <ul>
 <li>Emden R. Gansner, Eleftherios Koutsofios, Stephen C. North, Kiem-Phong Vo, A technique for
 drawing directed graphs. <i>Software Engineering</i> 19(3), pp. 214-230, 1993.</li>
 </ul>

 <dl>
 <dt>Precondition:</dt>
 <dd>the graph has no cycles</dd>
 <dt>Postcondition:</dt>
 <dd>all nodes have been assigned a layer such that edges connect only nodes from layers with
 increasing indices</dd>
 </dl>
 */
package final class NetworkSimplex {
    
    // MARK: - Configuration
    
    /** The number of nodes in each layer of a previous layering to be considered during `normalize()` 
     * and `balance(int[])`. That is, for an index `i`, `previousLayeringNodeCounts[i]` holds 
     * the number of nodes that are have previously been placed in layer `i`. */
    package var previousLayeringNodeCounts: [Int]?
    /** Whether to apply `balance(int[])`. */
    package var balance = false
    /** A limit on the number of iterations. */
    package var iterationLimit = Int.max
    /** Empirically determined threshold when removing subtrees pays off. */
    package static let REMOVE_SUBTREES_THRESH = 40
    
    /** Small value smaller than zero. Used to check whether cut values are small than zero and to deal with 
     *  imprecision of double computations. */
    package static let FUZZY_ST_ZERO = -1e-10
    
    // MARK: - Attributes
    
    /** The graph all methods in this class operate on. */
    package var graph: NGraph?

    /** An `Array` containing all edges in the graph. */
    package var edges: [NEdge]?

    /** A `Set` containing all edges that are part of the spanning tree. */
    package var treeEdges: Set<NEdge>?
    
    /**
     An `Array` containing all source nodes of the graph, i.e. all nodes that have no
     incident incoming edges.
     */
    package var sources: [NNode]?
    
    /**
     A flag indicating whether a specified edge has been visited during DFS-traversal. This array
     has to be filled with `false` each time, before a DFS-based method is invoked.
     */
    package var edgeVisited: [Bool]?
    
    /**
     The current postorder traversal number used by `postorderTraversal()` to assign an
     unique traversal ID to each node.
     
     - SeeAlso: `postorderTraversal(NNode)`
     */
    package var postOrder = 0
    
    /**
     The postorder traversal ID of each node determined by `postorderTraversal()`.
     
     - SeeAlso: `postorderTraversal(NNode)`
     */
    package var poID: [Int]?
    
    /**
     The lowest postorder traversal ID of each nodes reachable through a node lower in the
     traversal tree determined by `postorderTraversal`.
     
     - SeeAlso: `postorderTraversal(NNode)`
     */
    package var lowestPoID: [Int]?
    
    /**
     The cut value of every edge defined as follows: If the edge is deleted, the spanning tree
     breaks into two connected components, the head component containing the target node of the
     edge and the tail component containing the source node of the edge. The cut value is the sum
     of the weight (here `1`) of all edges going from the tail to the head component,
     including the tree edge, minus the sum of the weights of all edges from the head to the tail
     component.
     
     - SeeAlso: `cutvalues()`
     */
    package var cutvalue: [Double]?
    
    /**
     Nodes that are part of subtrees of the graph. They will be removed prior to the actual
     execution of the network simplex since positioning them with minimal edge length is trivial.
     
     - SeeAlso: `removeSubtrees()`
     - SeeAlso: `reattachSubtrees()`
     */
    package var subtreeNodesStack: [(node: NNode, edge: NEdge)]?
    
    // MARK: - Initialization
    
    private init() {}
    
    /**
     - Parameter graph: the graph for which to execute the network simplex
     - Returns: a new instance of a `NetworkSimplex` algorithm.
     */
    package static func forGraph(_ graph: NGraph) -> NetworkSimplex {
        let ns = NetworkSimplex()
        ns.graph = graph
        return ns
    }
    
    /**
     It balances the layering concerning its width, i.e. the number of nodes in each layer. If the
     graph allows multiple optimal layerings regarding a minimal edge length, this method moves
     separate nodes to a layer with a minimal amount of currently contained nodes with respect to
     the retention of feasibility and optimality of the given layering.
     
     - Parameter doBalance: whether to apply a balancing
     - Returns: the `NetworkSimplex` instance for further configuration or execution.
     */
    package func withBalancing(_ doBalance: Bool) -> NetworkSimplex {
        self.balance = doBalance
        return self
    }
    
    /**
     Previously layered nodes may become relevant when moving nodes to layers with fewer nodes
     during balancing.
     
     - Parameter considerPreviousLayering: whether previously layered nodes should be considered during.
     - Returns: the `NetworkSimplex` instance for further configuration or execution.
     - SeeAlso: `withBalancing(_:)`
     */
    package func withPreviousLayering(_ considerPreviousLayering: [Int]?) -> NetworkSimplex {
        self.previousLayeringNodeCounts = considerPreviousLayering
        return self
    }
    
    /**
     Since there is a theoretical possibility that the network simplex does not terminate Gansner
     et al. propose to incorporate an iteration limit. However, in practice this shouldn't happen.
     
     - Parameter limit: the maximum number of iterations of the network simplex algorithm.
     - Returns: the `NetworkSimplex` instance for further configuration or execution.
     */
    package func withIterationLimit(_ limit: Int) -> NetworkSimplex {
        self.iterationLimit = limit
        return self
    }
    
    // MARK: - Initialization Methods
    
    /**
     Helper method for the network simplex layerer. It instantiates all necessary attributes for
     the execution of the network simplex layerer and initializes them with their default values.
     All edges in the connected component given by the input argument will be determined, as well
     as the number of incoming and outgoing edges of each node ( `inDegree`, respectively
     `outDegree`). All sinks and source nodes in the connected component identified in this
     step will be added to `sinks`, respectively `sources`.
     */
    package func initialize() {
        guard let graph = graph else { assertionFailure("NetworkSimplex: graph not set"); return }
        // initialize node attributes
        let numNodes = graph.nodes.count
        for n in graph.nodes {
            n.treeNode = false
        }
        poID = Array(repeating: 0, count: numNodes)
        lowestPoID = Array(repeating: 0, count: numNodes)
        sources = []

        // determine edges and re-index nodes
        var index = 0
        var theEdges: [NEdge] = []
        for node in graph.nodes {
            node.internalId = index
            index += 1
            // add node to sinks, resp. sources
            if node.incomingEdges.size() == 0 {
                sources?.append(node)
            }
            theEdges.append(contentsOf: node.outgoingEdges.list)
        }
        // re-index edges
        var counter = 0
        for edge in theEdges {
            edge.internalId = counter
            edge.treeEdge = false
            counter += 1
        }
        // initialize edge attributes
        let numEdges = theEdges.count
        if let cv = cutvalue, cv.count >= numEdges {
            edgeVisited = Array(repeating: false, count: numEdges)
        } else {
            cutvalue = Array(repeating: 0.0, count: numEdges)
            edgeVisited = Array(repeating: false, count: numEdges)
        }
        edges = theEdges
        treeEdges = Set<NEdge>()
        postOrder = 1
    }
    
    /**
     Release all created resources so the GC can reap them.
     */
    package func dispose() {
        cutvalue = nil
        edges = nil
        treeEdges = nil
        edgeVisited = nil
        lowestPoID = nil
        poID = nil
        sources = nil
        subtreeNodesStack = nil
    }
    
    // MARK: - Network-Simplex Algorithm
    
    /**
     Determine the optimal layering.
     */
    package func execute() {
        execute(BasicProgressMonitor())
    }
    
    /**
     Determine the optimal layering.
     
     - Parameter monitor: a progress monitor
     */
    package func execute(_ monitor: IElkProgressMonitor) {
        monitor.begin("Network simplex", 1)

        guard let graph = graph else {
            monitor.done()
            return
        }

        if graph.nodes.count < 1 {
            monitor.done()
            return
        }

        // reset any old layering
        for node in graph.nodes {
            node.layer = 0
        }

        // remove leafs
        let shouldRemoveSubtrees = graph.nodes.count >= NetworkSimplex.REMOVE_SUBTREES_THRESH
        if shouldRemoveSubtrees {
            removeSubtrees()
        }

        // init all the data structures we use
        initialize()
        // determine an initial feasible layering
        feasibleTree()
        // improve the initial layering until it is optimal
        var e = leaveEdge()
        var iter = 0
        while let currentEdge = e, iter < iterationLimit {
            // current layering is not optimal
            exchange(leave: currentEdge, enter: enterEdge(currentEdge))
            e = leaveEdge()
            iter += 1
        }

        // re-attach leafs
        if shouldRemoveSubtrees {
            reattachSubtrees()
        }

        // normalize and, if desired, balance
        //   both methods must work on the NNode#layer field
        if balance {
            balance(normalize())
        } else {
            normalize()
        }

        // release the created resources
        dispose()
        monitor.done()
    }
    
    /**
     Recursively removes subtrees. In other words, removes leafs from the graph until no more
     leafs are present.
     */
    package func removeSubtrees() {
        guard let graph = graph else { return }
        subtreeNodesStack = []

        // find initial leafs
        var leafs = ArrayDeque<NNode>()
        for node in graph.nodes {
            if node.connectedEdges.count == 1 {
                leafs.append(node)
            }
        }

        // remove them from the graph like there's no tomorrow
        while !leafs.isEmpty {
            let node = leafs.removeFirst()
            // was the edge already removed?
            if node.connectedEdges.count == 0 {
                continue
            }
            let edge = node.connectedEdges[0]
            let isOutEdge = node.outgoingEdges.size() > 0

            let other = edge.getOther(node)
            if isOutEdge {
                other.incomingEdges.remove(edge)
            } else {
                other.outgoingEdges.remove(edge)
            }

            if other.connectedEdges.count == 1 {
                leafs.append(other)
            }

            subtreeNodesStack?.append((node, edge))
            if let index = graph.nodes.firstIndex(of: node) {
                graph.nodes.remove(at: index)
            }
        }
    }
    
    /**
     Re-attaches the previously removed tree nodes. It is important that
     the nodes are re-attached in the opposite order than they were removed.
     */
    package func reattachSubtrees() {
        guard let graph = graph else { return }
        while let leafy = subtreeNodesStack?.popLast() {
            let node = leafy.node
            let edge = leafy.edge

            let placed = edge.getOther(node)

            if edge.target === node {
                placed.outgoingEdges.append(edge)
                node.layer = placed.layer + edge.delta
            } else {
                placed.incomingEdges.append(edge)
                node.layer = placed.layer - edge.delta
            }

            graph.nodes.append(node)
        }
    }
    
    /**
     Helper method for the network simplex layerer. It determines an initial feasible spanning
     tree of the graph. This graph will be tight by construction. For determination, an initial
     feasible tree is being computed. If all tree edges contained are tight (i.e. their minimal
     length corresponds with their actual length), a tight tree has already been found. If not,
     this method iteratively determines a non-tree edge incident to the tree with a minimal amount
     of slack (i.e. the edge with the lowest difference between its current and minimal length)
     and shifts all tree edges accordingly to shorten the edge to its minimal size. The edge has
     become tight and will be added to the spanning tree together with all tight edges leading to
     non-tree nodes as well. If all nodes of the graph are contained in the spanning tree, a tight
     tree has been found. A concluding computation of each edge's initial cut value takes place.
     
     - SeeAlso: `tightTreeDFS(NNode)`
     */
    package func feasibleTree() {
        guard let graph = graph, let sources = sources, var edgeVisited = edgeVisited, let edges = edges else { return }
        // determine initial layering
        layeringTopologicalNumbering(sources)

        if edges.count > 0 {
            edgeVisited = Array(repeating: false, count: edgeVisited.count)
            self.edgeVisited = edgeVisited
            while tightTreeDFS(graph.nodes[0]) < graph.nodes.count {
                // some nodes are still not part of the tree
                guard let e = minimalSlack(), let eTgt = e.target, let eSrc = e.source else { break }
                let slack = eTgt.layer - eSrc.layer - e.delta
                let actualSlack = eTgt.treeNode ? -slack : slack

                // update tree
                for node in graph.nodes {
                    if node.treeNode {
                        node.layer += actualSlack
                    }
                }
                self.edgeVisited = Array(repeating: false, count: self.edgeVisited?.count ?? 0)
            }
            // update tree-related attributes
            self.edgeVisited = Array(repeating: false, count: self.edgeVisited?.count ?? 0)
            postorderTraversal(graph.nodes[0])
            cutvalues()
        }
    }
    
    /**
     Helper method for the network simplex layerer. It determines an (initial) feasible layering
     for the graph by traversing it by a minimal topological numbering. Dependently of
     the chosen mode indicated by `reverse`, this method traverses incoming edges (if
     `reverse = true`), or outgoing edges, if `reverse = false`, only. Therefore, this
     method should only be called with source nodes as argument in the first-mentioned case and
     only with sink nodes in the latter case.
     
     - Parameter initialRootNodes: the roots of the topological numbering (sources or sinks, depending on the direction)
     */
    package func layeringTopologicalNumbering(_ initialRootNodes: [NNode]) {
        guard let graph = graph else { return }
        // initialize the number of incident edges for each node
        var incident = Array(repeating: 0, count: graph.nodes.count)
        for node in graph.nodes {
            incident[node.internalId] += node.incomingEdges.size()
        }

        var roots = ArrayDeque<NNode>(initialRootNodes)
        while !roots.isEmpty {
            let node = roots.removeFirst()

            for edge in node.outgoingEdges {
                guard let tgt = edge.target else { continue }
                tgt.layer = max(tgt.layer, node.layer + edge.delta)
                incident[tgt.internalId] -= 1
                if incident[tgt.internalId] == 0 {
                    roots.append(tgt)
                }
            }
        }
    }
    
    /**
     Helper method for the network simplex layerer. It determines the length of the currently
     shortest incoming or outgoing edge of the input node.
     
     - Parameter node: the node to determine the length of its shortest incoming or outgoing edge
     - Returns: a pair containing the length of the shortest incoming (first element) and outgoing
     edge (second element) incident to the input node or `-1` as the length, if no
     such edge is incident
     */
    package func minimalSpan(_ node: NNode) -> (Int, Int) {
        var minSpanOut = Int.max
        var minSpanIn = Int.max
        var currentSpan: Int
        
        for edge in node.connectedEdges {
            guard let tgt = edge.target, let src = edge.source else { continue }
            currentSpan = tgt.layer - src.layer
            if tgt === node && currentSpan < minSpanIn {
                minSpanIn = currentSpan
            } else if currentSpan < minSpanOut {
                minSpanOut = currentSpan
            }
        }
        
        if minSpanIn == Int.max {
            minSpanIn = -1
        }
        if minSpanOut == Int.max {
            minSpanOut = -1
        }
        
        return (minSpanIn, minSpanOut)
    }
    
    /**
     Helper method for the network simplex layerer. It determines a DFS-subtree of the graph by
     traversing tight edges only (i.e. edges whose current length matches their minimal length in
     the layering) and returns the number of nodes in this. If this number is equal to the total
     number of nodes in the graph, a tight spanning tree has been determined.
     
     - Parameter node: the root of the DFS-subtree
     - Returns: the number of nodes in the determined tight DFS-tree
     */
    package func tightTreeDFS(_ node: NNode) -> Int {
        var nodeCount = 1
        node.treeNode = true
        for edge in node.connectedEdges {
            guard let ev = edgeVisited, !ev[edge.internalId] else { continue }
            edgeVisited?[edge.internalId] = true
            let opposite = edge.getOther(node)
            if edge.treeEdge {
                nodeCount += tightTreeDFS(opposite)
            } else if let tgt = edge.target, let src = edge.source, !opposite.treeNode && edge.delta == tgt.layer - src.layer {
                edge.treeEdge = true
                treeEdges?.insert(edge)
                nodeCount += tightTreeDFS(opposite)
            }
        }
        return nodeCount
    }
    
    /**
     Helper method for the network simplex layerer. It returns the non-tree edge incident on the
     tree and incident to a non-tree node with a minimal amount of slack (i.e. an edge with the
     lowest difference between its current and minimal length) or `nil`, if no such edge
     exists. Note, that the returned edge's slack is never `0`, since otherwise, the edge
     would be a tree-edge.
     
     - Returns: a non-tree edge incident on the tree with a minimal amount of slack or `nil`,
     if no such edge exists
     */
    package func minimalSlack() -> NEdge? {
        guard let edges = edges else { return nil }
        var minSlack = Int.max
        var minSlackEdge: NEdge?
        var curSlack: Int
        for edge in edges {
            guard let src = edge.source, let tgt = edge.target else { continue }
            if src.treeNode != tgt.treeNode {
                curSlack = tgt.layer - src.layer - edge.delta
                if curSlack < minSlack {
                    minSlack = curSlack
                    minSlackEdge = edge
                }
            }
        }
        return minSlackEdge
    }
    
    /**
     Helper method for the network simplex layerer. It performs a postorder DFS-traversal of the
     graph beginning with the input node. Each node will be assigned a unique traversal ID, which
     will be stored in `poID`. Furthermore, the lowest postorder traversal ID of any node in
     a descending path relative to the input node will be computed and stored in
     `lowestPoID`, which is also the return value of this method.
     
     - Parameter node: the root of the DFS-subtree
     - Returns: the lowest post-order ID of any descending edge in the depth-first-search
     
     - SeeAlso: `poID`
     - SeeAlso: `lowestPoID`
     - SeeAlso: `postOrder`
     */
    @discardableResult
    package func postorderTraversal(_ node: NNode) -> Int {
        var lowest = Int.max
        for edge in node.connectedEdges {
            guard let ev = edgeVisited, edge.treeEdge && !ev[edge.internalId] else { continue }
            edgeVisited?[edge.internalId] = true
            lowest = min(lowest, postorderTraversal(edge.getOther(node)))
        }
        poID?[node.internalId] = postOrder
        let lpid = min(lowest, postOrder)
        lowestPoID?[node.internalId] = lpid
        postOrder += 1
        return lpid
    }
    
    /**
     Helper method for the the network simplex layerer. It determines, whether an node is part of
     the head component of the given edge defined as follows: If the input edge is deleted, the
     spanning tree breaks into to connected components. The head component is that component,
     which contains the edge's target node, and the tail component is the component, which
     contains the edge's source node. Note that a node either belongs to the head or tail
     component. Therefore, if the node is not part of the head component, it must be part of the
     tail component and vice versa.
     
     - Parameter node: the node to determine, whether it belongs to the edges head (or tail) component
     - Parameter edge: the edge to determine, whether the node is in the head (or tail) component
     - Returns: `true`, if node is in the head component or `false`, if the node is in
     the tail component of the edge
     */
    package func isInHead(_ node: NNode, _ edge: NEdge) -> Bool {
        guard let source = edge.source, let target = edge.target,
              let poID = poID, let lowestPoID = lowestPoID else {
            assertionFailure("isInHead called with incomplete state")
            return false
        }

        if lowestPoID[source.internalId] <= poID[node.internalId] &&
            poID[node.internalId] <= poID[source.internalId] &&
            lowestPoID[target.internalId] <= poID[node.internalId] &&
            poID[node.internalId] <= poID[target.internalId] {
            if poID[source.internalId] < poID[target.internalId] {
                return false
            }
            return true
        }
        if poID[source.internalId] < poID[target.internalId] {
            return true
        }
        return false
    }
    
    /**
     Helper method for the network simplex layerer. It determines the cut value of each tree edge,
     which is defined as follows: If the edge is deleted, the spanning tree breaks into two
     connected components, the head component containing the target node of the edge and the tail
     component containing the source node of the edge. The cut value is the sum of the weights of
     all edges going from the tail to the head component, including the tree edge itself, minus
     the sum of the weights of all edges from the head to the tail component.
     
     - SeeAlso: `cutvalue`
     */
    package func cutvalues() {
        guard let graph = graph else { return }
        // determine incident tree edges for each node
        var leafs: [NNode] = []
        var treeEdgeCount = 0
        for node in graph.nodes {
            treeEdgeCount = 0
            node.unknownCutvalues.removeAll()
            for edge in node.connectedEdges {
                if edge.treeEdge {
                    node.unknownCutvalues.append(edge)
                    treeEdgeCount += 1
                }
            }
            if treeEdgeCount == 1 {
                leafs.append(node)
            }
        }

        // determine cut values
        guard var cv = cutvalue else { return }
        for leafNode in leafs {
            var currentNode: NNode = leafNode
            while currentNode.unknownCutvalues.count == 1 {
                let toDetermine = currentNode.unknownCutvalues[0]
                cv[toDetermine.internalId] = Double(toDetermine.weight)
                guard let src = toDetermine.source, let tgt = toDetermine.target else { break }
                for edge in currentNode.connectedEdges {
                    if edge !== toDetermine {
                        if edge.treeEdge {
                            if src === edge.source || tgt === edge.target {
                                cv[toDetermine.internalId] -= cv[edge.internalId] - Double(edge.weight)
                            } else {
                                cv[toDetermine.internalId] += cv[edge.internalId] - Double(edge.weight)
                            }
                        } else {
                            if currentNode === src {
                                if edge.source === currentNode {
                                    cv[toDetermine.internalId] += Double(edge.weight)
                                } else {
                                    cv[toDetermine.internalId] -= Double(edge.weight)
                                }
                            } else {
                                if edge.source === currentNode {
                                    cv[toDetermine.internalId] -= Double(edge.weight)
                                } else {
                                    cv[toDetermine.internalId] += Double(edge.weight)
                                }
                            }
                        }
                    }
                }

                if let index = src.unknownCutvalues.firstIndex(where: { $0 === toDetermine }) {
                    src.unknownCutvalues.remove(at: index)
                }
                if let index = tgt.unknownCutvalues.firstIndex(where: { $0 === toDetermine }) {
                    tgt.unknownCutvalues.remove(at: index)
                }

                if src === currentNode {
                    guard let nextNode = toDetermine.target else { break }
                    currentNode = nextNode
                } else {
                    guard let nextNode = toDetermine.source else { break }
                    currentNode = nextNode
                }
            }
        }
        cutvalue = cv
    }
    
    /**
     Helper method for the network simplex layerer. It returns a tree edge with a negative cut
     value or `nil`, if no such edge exists, meaning that the current layer assignment of
     all nodes is optimal. Note, that this method returns any edge with a negative cut value. A
     special preference to an edge with lowest value will not be given.
     
     - Returns: a tree edge with negative cut value or `nil`, if no such edge exists
     */
    package func leaveEdge() -> NEdge? {
        guard let treeEdges = treeEdges, let cutvalue = cutvalue else { return nil }
        for edge in treeEdges {
            if edge.treeEdge && cutvalue[edge.internalId] < NetworkSimplex.FUZZY_ST_ZERO {
                return edge
            }
        }
        return nil
    }
    
    /**
     Helper method for the network simplex layerer. It determines an non-tree edge to replace the
     given tree edge in the spanning tree. All edges going from the head component to the tail
     component of the edge will be considered. The edge with a minimal amount of slack (i.e. the
     lowest difference between its current to its minimal length) will be returned.
     
     - Parameter leave: the tree edge to determine a non-tree edge to be replaced with
     - Returns: a non-tree edge with a minimal amount of slack to replace the given edge
     - Throws: IllegalArgumentException if the input edge is not a tree edge
     */
    package func enterEdge(_ leave: NEdge) -> NEdge {
        if !leave.treeEdge {
            assertionFailure("The input edge is not a tree edge.")
        }

        guard let edges = edges else { assertionFailure("enterEdge called with no edges"); return leave }
        var replace: NEdge?
        var repSlack = Int.max
        var slack: Int
        for edge in edges {
            guard let src = edge.source, let tgt = edge.target else { continue }
            if isInHead(src, leave) && !isInHead(tgt, leave) {
                slack = tgt.layer - src.layer - edge.delta
                if slack < repSlack {
                    repSlack = slack
                    replace = edge
                }
            }
        }
        guard let result = replace else { assertionFailure("No replacement edge found"); return leave }
        return result
    }
    
    /**
     Helper method for the network simplex layerer. It exchanges the tree-edge `leave` by
     the non-tree edge `enter` and updates all values based on the tree (i.e. performs a new
     postorder DFS-traversal and updates the cut values).
     
     - Parameter leave: the tree-edge to be replaced
     - Parameter enter: the non-tree edge to replace the tree edge
     - Throws: IllegalArgumentException if either `leave` is no tree edge or `enter` is a tree edge already
     
     - SeeAlso: `enterEdge(_:)`
     - SeeAlso: `leaveEdge()`
     */
    package func exchange(leave: NEdge, enter: NEdge) {
        if !leave.treeEdge {
            assertionFailure("Given leave edge is no tree edge.")
            return
        }
        if enter.treeEdge {
            assertionFailure("Given enter edge is a tree edge already.")
            return
        }
        guard let graph = graph,
              let enterTgt = enter.target,
              let enterSrc = enter.source else {
            assertionFailure("exchange called with incomplete state")
            return
        }

        // update tree
        leave.treeEdge = false
        treeEdges?.remove(leave)
        enter.treeEdge = true
        treeEdges?.insert(enter)
        var delta = enterTgt.layer - enterSrc.layer - enter.delta
        if !isInHead(enterTgt, leave) {
            delta = -delta
        }
        for node in graph.nodes {
            if !isInHead(node, leave) {
                node.layer += delta
            }
        }

        // TODO it should be possible to do this incrementally right?
        // update tree-based values
        postOrder = 1
        edgeVisited = Array(repeating: false, count: edgeVisited?.count ?? 0)
        postorderTraversal(graph.nodes[0])
        cutvalues()
    }
    
    /**
     Helper method for the network simplex layerer. It normalizes the layering, i.e. determines
     the lowest layer assigned to a node and shifts all nodes up or down in the layers
     accordingly. After termination, the lowest layer assigned to a node will be zeroth (and
     therefore first) layer. This method returns an integer array indicating how many nodes are
     assigned to which layer. Note that the total number of layers necessary to layer the graph is
     indicated thereby, which is the size if the array.
     
     - Returns: an integer array indicating how many nodes are assigned to which layer
     */
    @discardableResult
    package func normalize() -> [Int] {
        guard let graph = graph else { return [] }
        // determine lowest assigned layer and layer count
        var highest = Int.min
        var lowest = Int.max
        for node in graph.nodes {
            lowest = min(lowest, node.layer)
            highest = max(highest, node.layer)
        }
        // normalize and determine layer filling
        let fillingSize = highest - lowest + 1
        var filling = Array(repeating: 0, count: fillingSize)
        for node in graph.nodes {
            node.layer -= lowest
            filling[node.layer] += 1
        }
        
        // also consider nodes of already layered connected components
        var layerID = 0
        if let previousLayeringNodeCounts = previousLayeringNodeCounts {
            for nodeCntInLayer in previousLayeringNodeCounts {
                if layerID < filling.count {
                    filling[layerID] += nodeCntInLayer
                }
                layerID += 1
                if layerID == filling.count {
                    break
                }
            }
        }
        return filling
    }
    
    /**
     Helper method for the network simplex layerer. It balances the layering concerning its width,
     i.e. the number of nodes in each layer. If the graph allows multiple optimal layerings
     regarding a minimal edge length, this method moves separate nodes to a layer with a minimal
     amount of currently contained nodes with respect to the retention of feasibility and
     optimality of the given layering.
     
     - Parameter filling: an integer array indicating how many nodes are currently assigned to each layer
     */
    package func balance(_ filling: [Int]) {
        guard let graph = graph else { return }
        // determine possible layers
        var mutableFilling = filling
        var newLayer: Int
        var range: (Int, Int)
        for node in graph.nodes {
            if node.incomingEdges.size() == node.outgoingEdges.size() {
                // node might get shifted
                newLayer = node.layer
                range = minimalSpan(node)
                let lo = node.layer - range.0 + 1
                let hi = node.layer + range.1
                if lo < hi {
                    for i in lo ..< hi {
                        if i < mutableFilling.count && mutableFilling[i] < mutableFilling[newLayer] {
                            newLayer = i
                        }
                    }
                }
                // assign new layer
                if mutableFilling[newLayer] < mutableFilling[node.layer] {
                    mutableFilling[node.layer] -= 1
                    mutableFilling[newLayer] += 1
                    node.layer = newLayer
                }
            }
        }
    }
}
