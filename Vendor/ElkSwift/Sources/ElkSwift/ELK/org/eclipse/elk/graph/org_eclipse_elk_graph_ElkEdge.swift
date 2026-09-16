/**
 * Copyright (c) 2016 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 */

import Foundation

/**
 A representation of the model object '<b>Elk Edge</b>'.
 
 An edge connects one or more source elements (`ElkConnectableShape`s) with one or more target elements (`ElkConnectableShape`s). If an edge connects at most one source with at most one target, it is called a _regular edge_ (although it is usually simply called an _edge_). If an edge has more than a single source or more than a single target, it is called a _hyperedge_. If all of the edge's sources and targets have the same parent node, it is a _simple edge_; otherwise, it is called a _hierarchical edge_.

 Each edge must be assigned to a containing node. The containing node defines the point where it is hooked into the graph's object hierarchy, which is important for serializing the graph. The containing node's origin is the point the edge's source, target, and bend points are relative to. As a rule of thumb, edges should always be contained in the lowest common representing node of the graphs of all elements it connects, with one exception: if an edge connects a node with one of its descendants, that node should be the edge's containing node.

 The routing of an edge is specified by the `ElkEdgeSection` objects it contains. If the edge is a regular edge (as opposed to a hyperedge), it contains at most a single `ElkEdgeSection` which specifies a single source point, a single end point, and an arbitrary number of bend points. If the edge is a hyperedge, it contains at least one `ElkEdgeSection` for each of its sources and targets (_outer edge sections_) as well as an arbitrary number of `ElkEdgeSection` objects to connect the outer sections (_inner edge sections_).
 */
package protocol ElkEdge: ElkGraphElement {
    
    /// The node the edge is contained in.
    var containingNode: ElkNode? { get set }
    
    /// The edge's list of source elements.
    var sources: [ElkConnectableShape] { get set }

    /// The edge's list of target elements.
    var targets: [ElkConnectableShape] { get set }

    /// All edge sections that define the routing of this edge.
    var sections: [ElkEdgeSection] { get set }
    
    /// Whether this edge is a hyperedge or not.
    func isHyperedge() -> Bool

    /// Whether the edge is a hierarchical edge or not.
    func isHierarchical() -> Bool

    /// Whether the edge is a self loop or not.
    func isSelfloop() -> Bool

    /// Whether the edge has at least one source and one target.
    func isConnected() -> Bool
}
