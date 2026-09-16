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
 * A graph element that can be the end point of an edge.
 *
 * The following features are supported:
 * - [[ElkConnectableShape.outgoingEdges]]: List of edges that leave this connectable shape.
 * - [[ElkConnectableShape.incomingEdges]]: List of edges that go into this connectable shape.
 */
package protocol ElkConnectableShape: ElkShape {
    
    /// List of edges that leave this connectable shape.
    /// Adding or removing an edge to/from this list automatically updates its list of sources.
    var outgoingEdges: [ElkEdge] { get set }
    
    /// List of edges that go into this connectable shape.
    /// Adding or removing an edge to/from this list automatically updates its list of targets.
    var incomingEdges: [ElkEdge] { get set }
}
