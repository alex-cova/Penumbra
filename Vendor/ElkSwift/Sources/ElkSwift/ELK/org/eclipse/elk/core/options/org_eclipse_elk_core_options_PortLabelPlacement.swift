import Foundation

/**
 * Options for controlling how port labels are placed by layout algorithms. The corresponding layout
 * option will usually accept an `OptionSet` over this enumeration, theoretically allowing
 * arbitrary and even contradictory subsets of options to be set. Note that you are restricted to
 * the following combinations if you want your choice to make sense:
 * - Exactly one of the `.inside` and `.outside` options (if neither is set,
 *   label positions are not computed but left untouched).
 * - At most one of the `.alwaysSameSide`, `.alwaysOtherSameSide`, and `.spaceEfficient` options.
 *
 * Additionally `.nextToPortIfPossible` can be used to indicate that, if possible,
 * a label should be placed center-aligned with the corresponding port.
 *
 * <p><b>This enumeration is not set directly on `CoreOptions.portLabelsPlacement`; instead,
 * an `OptionSet` over this enumeration is used there.</b></p>
 *
 * <p><i>Note:</i> Layout algorithms may only support a subset of these options.</p>
 */
package struct PortLabelPlacement: OptionSet, Hashable {
    package let rawValue: Int
    
    package init(rawValue: Int) {
        self.rawValue = rawValue
    }
    
    /** Port labels are placed outside of the node. */
    package static let outside = PortLabelPlacement(rawValue: 1 << 0)
    
    /** Port labels are placed inside of the node. */
    package static let inside = PortLabelPlacement(rawValue: 1 << 1)
    
    /**
     * Not in all cases port labels are placed *next to* the port (that is, center-aligned). This option can be set
     * to direct the layout algorithm to place the label next to the port if no edge would cross the label.
     *
     * Cases in which this behavior is not the default:
     * - Outside labels of both hierarchical and non-hierarchical nodes,
     * - Inside labels of hierarchical nodes.
     *
     * Cases in which the behavior is the default anyway:
     * - Inside labels of non-hierarchical nodes.
     */
    package static let nextToPortIfPossible = PortLabelPlacement(rawValue: 1 << 2)
    
    /**
     * The port labels shall always be placed on the same side relative to their corresponding port. For
     * `PortSide.west` and `PortSide.east` this is *below* the port and for `PortSide.north` and
     * `PortSide.south` it is *right* of the port.
     *
     * <p>
     * Note: the option does not apply to inside port labels (unless a hierarchical edge connects).
     */
    package static let alwaysSameSide = PortLabelPlacement(rawValue: 1 << 3)
    
    /**
     * The port labels shall always be placed on the same side relative to their corresponding port. For
     * `PortSide.west` and `PortSide.east` this is *above* the port and for `PortSide.north` and
     * `PortSide.south` it is *left* of the port.
     *
     * <p>
     * Note: the option does not apply to inside port labels (unless a hierarchical edge connects).
     */
    package static let alwaysOtherSameSide = PortLabelPlacement(rawValue: 1 << 4)
    
    /**
     * Unless there are exactly two ports at a given port side, outside port labels are usually all placed to the same
     * side of their port. For example, if there are three northern ports, all of their labels will be placed to the
     * right of their ports. If this option is active, the leftmost label will be placed to the left of its port while
     * the others stay on the right side (and similar for the other port sides). This allows the node to be smaller
     * because the node size doesn't have to accommodate as many port labels, but it breaks symmetry.
     *
     * <p>
     * Note: the option does not apply to inside port labels (unless a hierarchical edge connects).
     */
    package static let spaceEfficient = PortLabelPlacement(rawValue: 1 << 5)
    
    /**
     * @return a set of `PortLabelPlacement` values indicating fixed port label positions.
     */
    package static var fixed: PortLabelPlacement {
        return []
    }
    
    /**
     * @return a set of `PortLabelPlacement` values indicating default inside port label positions.
     */
    package static var insideSet: PortLabelPlacement {
        return .inside
    }

    /**
     * @return a set of `PortLabelPlacement` values indicating default outside port label positions.
     */
    package static var outsideSet: PortLabelPlacement {
        return .outside
    }
    
    /**
     * @return whether the passed placement represents a fixed port label placement, i.e. whether neither
     *         `.inside` nor `.outside` are included.
     */
    package static func isFixed(_ placement: PortLabelPlacement) -> Bool {
        return !placement.contains(.inside) && !placement.contains(.outside)
    }
    
    /**
     * @return whether the passed `placement` is considered valid as described in the struct's documentation.
     */
    package static func isValid(_ placement: PortLabelPlacement) -> Bool {
        // Cannot have both inside and outside
        if placement.contains(.inside) && placement.contains(.outside) {
            return false
        }

        // At most one of alwaysSameSide, alwaysOtherSameSide, spaceEfficient
        let posCount = (placement.contains(.alwaysSameSide) ? 1 : 0)
            + (placement.contains(.alwaysOtherSameSide) ? 1 : 0)
            + (placement.contains(.spaceEfficient) ? 1 : 0)
        if posCount > 1 {
            return false
        }

        return true
    }
}
