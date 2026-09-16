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
 * A node in the graph. Edges can be connected to the node directly or through one of its ports.
 *
 * All nodes except one must have an assigned parent node. The node that does not have a parent node is the graph's root node and represents the graph itself. There can only be one root node for each graph. The parent-child relationship of nodes induces hierarchy in nested graphs: a node's children constitute the graph contained in and represented by that node.
 *
 * The following features are supported:
 * - Ports
 * - Children
 * - Parent
 * - ContainedEdges
 * - Hierarchical
 */
package protocol ElkNode: ElkConnectableShape {
    
    /// The node's list of ports.
    ///
    /// Adding or removing a port to/from this list automatically sets its parent node.
    var ports: [ElkPort] { get set }
    
    /// Child nodes contained in this node. If the node contains at least one child node, the node is a hierarchical node.
    ///
    /// Adding or removing a node to/from this list automatically sets its parent node.
    var children: [ElkNode] { get set }
    
    /// The node's parent node, if any.
    ///
    /// Setting the node's parent node automatically updates the parent node's list of child nodes.
    var parent: ElkNode? { get set }
    
    /// The edges contained in this node.
    ///
    /// Adding or removing an edge to/from this list automatically sets its containing node.
    var containedEdges: [ElkEdge] { get set }
    
    /// Whether or not this node is considered to be a hierarchical node.
    ///
    /// The value of this attribute is computed dynamically and not persistent.
    func isHierarchical() -> Bool
}
