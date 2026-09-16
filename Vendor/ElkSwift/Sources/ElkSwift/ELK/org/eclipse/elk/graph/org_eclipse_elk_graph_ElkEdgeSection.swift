// Copyright (c) 2016 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

import Foundation

/**
 * A representation of the model object 'Elk Edge Section'.
 *
 * An edge section defines the routing of an edge, or a part of that routing. If the edge is a regular edge (as opposed to a hyperedge), it will have a single edge section that connects to the edge's source element and target element. The section will then completely define the edge's start point, its end point, and all of its bend points. This is a special case of the more general case described below.
 *
 * If the section's parent edge is a hyperedge, defining the routing will be more complicated. There will be enough edge sections to connect all of the edge's souce and target elements. The sections will effectively define a routing graph: all sections in the graph will connect to other sections and/or sources and targets of the edge, each effectively defining a part of the complex route the edge will take. We call an edge section that connects to at least one ElkConnectableShape an outer section. Edge sections that connect only to other edge sections are referred to as inner sections.
 *
 * Conceptually, the routing graph would be undirected. The way references work in EMF, however, forces us to distinguish between a section's incoming and outgoing sections. This is not much of a problem, however: each routing graph can be made acyclic.
 *
 * All coordinates that define a section's route are relative to the origin of its edge's containing node.
 *
 * Note that edge sections are property holders to allow algorithms to pass more detailed information about an edge section back to the client.
 */
package protocol ElkEdgeSection: EMapPropertyHolder {
    
    // MARK: - Attributes
    
    /// X coordinate of the section's start point, relative to the origin of the edge's containing node.
    var startX: Double { get set }
    
    /// Y coordinate of the section's start point, relative to the origin of the edge's containing node.
    var startY: Double { get set }
    
    /// X coordinate of the section's end point, relative to the origin of the edge's containing node.
    var endX: Double { get set }
    
    /// Y coordinate of the section's end point, relative to the origin of the edge's containing node.
    var endY: Double { get set }
    
    /// The section's list of bend points. May well be empty if the section represents a straight line.
    var bendPoints: [ElkBendPoint] { get set }
    
    /// The edge this section belongs to.
    ///
    /// Setting the parent edge automatically updates its list of edge sections.
    var parent: ElkEdge? { get set }
    
    /// The shape this section ends at, if any. If there is one, this section is an outer section.
    var outgoingShape: ElkConnectableShape? { get set }
    
    /// The shape this section starts at, if any. If there is one, this section is an outer section.
    var incomingShape: ElkConnectableShape? { get set }
    
    /// List of outgoing sections this section is connected to. Must not be empty if this section is an inner section (not connected to a shape).
    ///
    /// Adding or removing a section to/from this list automatically updates its list of incoming sections.
    var outgoingSections: [ElkEdgeSection] { get set }
    
    /// List of incoming sections this section is connected to. Must not be empty if this section is an inner section (not connected to a shape).
    ///
    /// Adding or removing a section to/from this list automatically updates its list of outgoing sections.
    var incomingSections: [ElkEdgeSection] { get set }
    
    /// Identifier for the edge section.
    var identifier: String? { get set }
    
    // MARK: - Methods
    
    /// Sets the x and y coordinates of the section's start point simultaneously.
    func setStartLocation(x: Double, y: Double)
    
    /// Sets the x and y coordinates of the section's end point simultaneously.
    func setEndLocation(x: Double, y: Double)
}
