/**
 * Copyright (c) 2016 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 */


/**
 * A representation of the model object '<em><b>Elk Bend Point</b></em>'.
 *
 * A bend point of an `ElkEdgeSection`. The coordinates of a bend point are always relative to the origin of the containing node of the edge the bend point belongs to.
 *
 * The following features are supported:
 * - `x`: The bend point's x coordinate, relative to the origin of the edge's containing node.
 * - `y`: The bend point's y coordinate, relative to the origin of the edge's containing node.
 */
package protocol ElkBendPoint: EObject {
    /// Returns the x coordinate of the bend point.
    var x: Double { get set }
    
    /// Returns the y coordinate of the bend point.
    var y: Double { get set }
    
    /// Sets the bend point's x and y coordinates simultaneously.
    func set(x: Double, y: Double)
}
