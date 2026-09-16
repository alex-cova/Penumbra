// Copyright (c) 2009, 2020 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0


/**
 * Definition of placement positions for edge labels. To be accessed using `CoreOptions.edgeLabelPlacement`.
 */
package enum EdgeLabelPlacement {
    /// label is centered on the edge.
    case center
    /// label is at the head (target) of the edge.
    case head
    /// label is at the tail (source) of the edge.
    case tail
    
    /**
     * Checks whether this edge label placement is one of the two end label placements.
     *
     * - Returns: `true` iff this is `.head` or `.tail`.
     */
    package func isEndLabelPlacement() -> Bool {
        return self == .head || self == .tail
    }

    // MARK: - Uppercase Aliases (Java compatibility)
    package static let CENTER = EdgeLabelPlacement.center
    package static let HEAD = EdgeLabelPlacement.head
    package static let TAIL = EdgeLabelPlacement.tail
}
