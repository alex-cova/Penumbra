/*******************************************************************************
 * Copyright (c) 2009, 2015 Kiel University and others.
 * 
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 ******************************************************************************/

/**
 * Definition of port constraints. To be accessed using `CoreOptions.portConstraints`.
 */
package enum PortConstraints {
    /// Undefined constraints.
    case undefined
    /// All ports are free.
    case free
    /// The side is fixed for each port.
    case fixedSide
    /// The side is fixed for each port, and the order of ports is fixed for each side.
    case fixedOrder
    /// The side is fixed for each port, the order or ports is fixed for each side and
    /// the relative position of each port must be preserved. That means if the node is
    /// resized by factor x, the port's position must also be scaled by x.
    case fixedRatio
    /// The exact position is fixed for each port.
    case fixedPos
    
    /// Returns whether the position of the ports is fixed. Note that this is not true
    /// if port ratios are fixed.
    package func isPosFixed() -> Bool {
        return self == .fixedPos
    }

    /// Returns whether the ratio of port positions is fixed. Note that this is not true
    /// if the port positions are fixed.
    package func isRatioFixed() -> Bool {
        return self == .fixedRatio
    }

    /// Returns whether the order of ports is fixed.
    package func isOrderFixed() -> Bool {
        return self == .fixedOrder || self == .fixedRatio || self == .fixedPos
    }

    /// Returns whether the sides of ports are fixed.
    package func isSideFixed() -> Bool {
        return self != .free && self != .undefined
    }

    // MARK: - Uppercase Aliases (Java compatibility)
    package static let UNDEFINED = PortConstraints.undefined
    package static let FREE = PortConstraints.free
    package static let FIXED_SIDE = PortConstraints.fixedSide
    package static let FIXED_ORDER = PortConstraints.fixedOrder
    package static let FIXED_RATIO = PortConstraints.fixedRatio
    package static let FIXED_POS = PortConstraints.fixedPos
}
