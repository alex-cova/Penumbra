// Copyright (c) 2012, 2015 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

/// Options for controlling how node labels are placed by layout algorithms. The corresponding layout
/// option will usually accept a `OptionSet` over this enumeration, theoretically allowing
/// arbitrary and even contradictory subsets of options to be set. Note that you are restricted to
/// the following combinations if you want your choice to make sense:
/// - Exactly one of the `.inside` and `.outside` options.
/// - Exactly one of the `.hLeft`, `.hCenter`, and `.hRight` options.
/// - Exactly one of the `.vTop`, `.vCenter`, and `.vBottom` options.
///
/// **This enumeration is not set directly on `CoreOptions.nodeLabelPlacement`; instead,
/// an `OptionSet` over this enumeration is used there.**
///
/// *Note:* Layout algorithms may only support a subset of these options.
package struct NodeLabelPlacement: OptionSet, Hashable {
    package let rawValue: Int
    
    package init(rawValue: Int) {
        self.rawValue = rawValue
    }
    
    /// Horizontal left placement.
    package static let hLeft = NodeLabelPlacement(rawValue: 1 << 0)
    
    /// Horizontal center placement.
    package static let hCenter = NodeLabelPlacement(rawValue: 1 << 1)
    
    /// Horizontal right placement.
    package static let hRight = NodeLabelPlacement(rawValue: 1 << 2)
    
    /// Vertical top placement.
    package static let vTop = NodeLabelPlacement(rawValue: 1 << 3)
    
    /// Vertical center placement.
    package static let vCenter = NodeLabelPlacement(rawValue: 1 << 4)
    
    /// Vertical bottom placement.
    package static let vBottom = NodeLabelPlacement(rawValue: 1 << 5)
    
    /// Place node labels on the inside of the node. This should usually be combined with size
    /// constraints to ensure the node is big enough to accomodate its labels.
    package static let inside = NodeLabelPlacement(rawValue: 1 << 6)
    
    /// Place node labels on the outside of the node.
    package static let outside = NodeLabelPlacement(rawValue: 1 << 7)
    
    /// If set, the default behaviour is changed to give the horizontal placement priority over the
    /// vertical one.
    ///
    /// ### Inside Placement
    ///
    /// The default behaviour is for top / bottom labels to contribute to the top / bottom insets
    /// of a node, thus causing the node's children to be moved down / leave space to the node's bottom.
    ///
    /// If this option is set, the default behaviour is overridden and the horizontal placement options
    /// are evaluated first. This makes a left top label occupy space on the left side of the node, causing
    /// the node's children to be moved right instead of down.
    ///
    /// *Note:* Since this changes the placement of a node's children, this option is only
    /// interpreted if set on the node itself, not on the individual labels.
    ///
    /// ### Outside Placement
    ///
    /// The default behaviour is to first choose the northern or southern node side for placement of
    /// the label, according to the `.vTop` and `.vBottom` options. The horizontal placement
    /// is then constrained to the width of the node, thus resulting in labels that are placed above or
    /// below the node, but never to its left or right side.
    ///
    /// If this option is set, the default behaviour is overridden and the horizontal placement options
    /// are evaluated first, thus causing the eastern or western node side to be chosen for placement of
    /// the label. The vertical placement options are then constrained to the height of the node, thus
    /// resulting in labels that are placed to the left or right of the node.
    package static let hPriority = NodeLabelPlacement(rawValue: 1 << 8)
    
    /// Returns an empty option set over this enumeration, which prevents the layout algorithm from
    /// changing the label's coordinates.
    ///
    /// - Returns: option set over this enumeration representing fixed node label placement constraints.
    package static func fixed() -> NodeLabelPlacement {
        return []
    }
    
    /// Returns a node label placement to place the node label inside the node, left-aligned on top.
    ///
    /// - Returns: node label placement for inside top left placement.
    package static func insideTopLeft() -> NodeLabelPlacement {
        return [.inside, .vTop, .hLeft]
    }
    
    /// Returns a node label placement to place the node label inside the node, centered at its top.
    ///
    /// - Returns: node label placement for inside top center placement.
    package static func insideTopCenter() -> NodeLabelPlacement {
        return [.inside, .vTop, .hCenter]
    }
    
    /// Returns a node label placement to place the node label inside the node, right-aligned on top.
    ///
    /// - Returns: node label placement for inside top right placement.
    package static func insideTopRight() -> NodeLabelPlacement {
        return [.inside, .vTop, .hRight]
    }
    
    /// Returns a node label placement to place the node label centered inside the node.
    ///
    /// - Returns: node label placement for inside centered placement.
    package static func insideCenter() -> NodeLabelPlacement {
        return [.inside, .vCenter, .hCenter]
    }
    
    /// Returns a node label placement to place the node label inside the node, left-aligned on bottom.
    ///
    /// - Returns: node label placement for inside top bottom placement.
    package static func insideBottomLeft() -> NodeLabelPlacement {
        return [.inside, .vBottom, .hLeft]
    }
    
    /// Returns a node label placement to place the node label inside the node, centered at its bottom.
    ///
    /// - Returns: node label placement for inside bottom center placement.
    package static func insideBottomCenter() -> NodeLabelPlacement {
        return [.inside, .vBottom, .hCenter]
    }
    
    /// Returns a node label placement to place the node label inside the node, right-aligned on bottom.
    ///
    /// - Returns: node label placement for inside top right placement.
    package static func insideBottomRight() -> NodeLabelPlacement {
        return [.inside, .vBottom, .hRight]
    }
    
    /// Returns a node label placement to place the node label outside the node, left-aligned on top.
    ///
    /// - Returns: node label placement for outside top left placement.
    package static func outsideTopLeft() -> NodeLabelPlacement {
        return [.outside, .vTop, .hLeft]
    }
    
    /// Returns a node label placement to place the node label outside the node, centered on top.
    ///
    /// - Returns: node label placement for outside top center placement.
    package static func outsideTopCenter() -> NodeLabelPlacement {
        return [.outside, .vTop, .hCenter]
    }
    
    /// Returns a node label placement to place the node label outside the node, right-aligned on top.
    ///
    /// - Returns: node label placement for outside top left placement.
    package static func outsideTopRight() -> NodeLabelPlacement {
        return [.outside, .vTop, .hRight]
    }
    
    /// Returns a node label placement to place the node label outside the node, left-aligned on bottom.
    ///
    /// - Returns: node label placement for outside top left placement.
    package static func outsideBottomLeft() -> NodeLabelPlacement {
        return [.outside, .vBottom, .hLeft]
    }
    
    /// Returns a node label placement to place the node label outside the node, centered below it.
    ///
    /// - Returns: node label placement for outside bottom center placement.
    package static func outsideBottomCenter() -> NodeLabelPlacement {
        return [.outside, .vBottom, .hCenter]
    }
    
    /// Returns a node label placement to place the node label outside the node, right-aligned on bottom.
    ///
    /// - Returns: node label placement for outside top left placement.
    package static func outsideBottomRight() -> NodeLabelPlacement {
        return [.outside, .vBottom, .hRight]
    }
    
    /// Returns whether the passed `placement` is considered valid as described in the struct's documentation.
    package static func isValid(_ placement: NodeLabelPlacement) -> Bool {
        // Cannot have both inside and outside
        if placement.contains(.inside) && placement.contains(.outside) {
            return false
        }

        // At most one horizontal alignment
        let hCount = (placement.contains(.hLeft) ? 1 : 0)
            + (placement.contains(.hCenter) ? 1 : 0)
            + (placement.contains(.hRight) ? 1 : 0)
        if hCount > 1 {
            return false
        }

        // At most one vertical alignment
        let vCount = (placement.contains(.vTop) ? 1 : 0)
            + (placement.contains(.vCenter) ? 1 : 0)
            + (placement.contains(.vBottom) ? 1 : 0)
        if vCount > 1 {
            return false
        }

        return true
    }
}
