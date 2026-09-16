import Foundation

/**
 * Things to take into account when determining the size of a node. Each case of this enumeration
 * corresponds to something a layout algorithm should pay attention to when calculating node sizes.
 * Usually, one will use a combination of these values in a `OptionSet` instance, with the
 * empty set meaning that node sizes are fixed. <b>This enumeration is not set directly on
 * `CoreOptions.SizeConstraint`; instead, an `OptionSet` over this enumeration is used
 * there.</b>
 *
 * <p><i>Note:</i> Layout algorithms may only support a subset of these options.</p>
 *
 * @see SizeOptions
 * @author msp
 * @author cds
 */
package struct SizeConstraint: OptionSet, Hashable {
    package let rawValue: Int
    
    package init(rawValue: Int) {
        self.rawValue = rawValue
    }
    
    /**
     * The number of ports and their position should be taken into account when determining the
     * size of nodes. The sum of port widths and heights and the minimum spacing between ports
     * is a lower bound for the node size.
     */
    package static let ports = SizeConstraint(rawValue: 1 << 0)
    
    /**
     * Ports labels are taken into account when determining the size of nodes. Depending on where
     * the labels are positioned the node will be made large enough to avoid overlaps and to try
     * to place labels in as unambiguous a way as possible. Setting this option doesn't make any
     * sense if the `.ports` option is not set as well.
     */
    package static let portLabels = SizeConstraint(rawValue: 1 << 1)
    
    /**
     * A node's labels are taken into account.
     */
    package static let nodeLabels = SizeConstraint(rawValue: 1 << 2)
    
    /**
     * If set, a node's size will be at least the minimum size set on it. If no minimum size is set,
     * the behavior depends on whether the `SizeOptions.defaultMinimumSize` constraint is
     * set as well.
     */
    package static let minimumSize = SizeConstraint(rawValue: 1 << 3)
    
    /**
     * Returns an empty option set, which corresponds to fixed size constraints.
     *
     * @return option set representing fixed size constraints.
     */
    package static var fixed: SizeConstraint { [] }
    
    /**
     * Returns a set containing the `.minimumSize` constraint.
     *
     * @return set with minimum size constraint.
     */
    package static var minimumSizeOnly: SizeConstraint { [.minimumSize] }

    /**
     * Returns a set containing the common combination of `.minimumSize` and `.ports`.
     *
     * @return set with minimum size constraint in combination with ports.
     */
    package static var minimumSizeWithPorts: SizeConstraint { [.ports, .minimumSize] }
    
    /**
     * Returns a set containing all options defined in this enumeration, effectively giving
     * the layout algorithm as much freedom as possible in determining the node size.
     *
     * @return set with all available options.
     */
    package static var free: SizeConstraint { [.ports, .portLabels, .nodeLabels, .minimumSize] }
}
