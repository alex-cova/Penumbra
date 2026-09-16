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
 * A shape is a graph element whose placement and extend can be described by x and y coordinates as well as a width and a height. The coordinates of a shape describe the position of its top left corner, relative to the origin of its parent element. The width and height of a shape describe the extend of its rectangular bounding box.
 */
package protocol ElkShape: ElkGraphElement {
    
    /// Height of the shape's rectangular bounding box.
    var height: Double { get set }
    
    /// Width of the shape's rectangular bounding box.
    var width: Double { get set }
    
    /// X coordinate of the shape's top left corner, relative to the origin of its parent object.
    var x: Double { get set }
    
    /// Y coordinate of the shape's top left corner, relative to the origin of its parent object.
    var y: Double { get set }
    
    /// Convenience method to set the shape's width and height simultaneously by calling their respective set methods.
    func setDimensions(width: Double, height: Double)
    
    /// Convenience method to set the shape's x and y coordinates simultaneously by calling their respective set methods.
    func setLocation(x: Double, y: Double)
}
