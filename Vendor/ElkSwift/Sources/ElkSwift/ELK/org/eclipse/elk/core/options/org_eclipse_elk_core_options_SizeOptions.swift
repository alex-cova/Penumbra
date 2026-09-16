import Foundation

/**
 * Size constraint options that modify how size constraints of a node are applied. Interpreting a
 * size option set on a node only makes sense when its size constraint is taken into consideration
 * as well. <b>This enumeration is not set directly on CoreOptions.sizeOptions; instead,
 * an `OptionSet` over this enumeration is used there.</b>
 *
 * <p><i>Note:</i> Layout algorithms may only support a subset of these options.</p>
 *
 * @author cds
 */
package struct SizeOptions: OptionSet, Hashable {
    package let rawValue: Int
    
    package init(rawValue: Int) {
        self.rawValue = rawValue
    }
    
    /**
     * If no minimum size is set on an element, the minimum size options are assumed to be some
     * default value determined by the particular layout algorithm. This option only makes sense
     * if the `SizeConstraint.minimumSize` constraint is set.
     */
    package static let defaultMinimumSize = SizeOptions(rawValue: 1 << 0)
    
    /**
     * If this option is set and paddings are computed by the algorithm, the minimum size plus the
     * computed padding are a lower bound on the node size. If this option is not set, the minimum size
     * will be applied to the node's whole size regardless of any computed padding. Note that,
     * depending on the algorithm, this option may only apply to non-hierarchical nodes. This option
     * only makes sense if the `SizeConstraint.minimumSize` constraint is set.
     */
    package static let minimumSizeAccountsForPadding = SizeOptions(rawValue: 1 << 1)
    
    /**
     * With this option set, the padding of nodes will be computed and returned as part of the
     * algorithm's result. If port labels or node labels are placed, they may influence the size of
     * the padding. Note that, depending on the algorithm, this option may only apply to
     * non-hierarchical nodes. This option is independent of the size constraint set on a node.
     */
    package static let computePadding = SizeOptions(rawValue: 1 << 2)
    
    /**
     * If node labels influence the node size, but outside node labels are allowed to overhang, only inside node labels
     * actually influence node size.
     */
    package static let outsideNodeLabelsOverhang = SizeOptions(rawValue: 1 << 3)
    
    /**
     * By default, ports only use the space available to them, even if that means violating port spacing settings. If
     * this option is active, port spacings are adhered to, even if that means ports extend beyond node boundaries.
     */
    package static let portsOverhang = SizeOptions(rawValue: 1 << 4)
    
    /**
     * If port labels are taken into consideration, differently sized labels can result in a different amount of space
     * between different pairs of ports. This option causes all ports to be evenly spaced by enlarging the space
     * between every pair of ports to the largest amount of space between any pair of ports.
     */
    package static let uniformPortSpacing = SizeOptions(rawValue: 1 << 5)
    
    /**
     * @deprecated Use `PortLabelPlacement.spaceEfficient`.
     */
    @available(*, deprecated, message: "Use PortLabelPlacement.spaceEfficient")
    package static let spaceEfficientPortLabels = SizeOptions(rawValue: 1 << 6)
    
    /**
     * By default, inside node labels will be laid out in three rows of three cells, with no relation between the
     * width of cells in different rows. If this option is enabled, the cells will be treated as cells of a table,
     * with equal columns across all rows. This usually results in larger nodes.
     */
    package static let forceTabularNodeLabels = SizeOptions(rawValue: 1 << 7)
    
    /**
     * If this option is set, the node sizing and label placement code will not make an attempt to achieve a symmetrical
     * layout. With this option inactive, for example, the space reserved for left inside port labels will be the same
     * as for right inside port labels, which would not be the case otherwise. Deactivating this option will also ensure
     * that center node labels will actually be placed in the center.
     */
    package static let asymmetrical = SizeOptions(rawValue: 1 << 8)
    
    /**
     * Returns the enumeration value related to the given ordinal.
     *
     * @param i ordinal value
     * @return the related enumeration value
     */
    package static func value(ofOrdinal i: Int) -> SizeOptions {
        let allOptions: [SizeOptions] = [
            .defaultMinimumSize,
            .minimumSizeAccountsForPadding,
            .computePadding,
            .outsideNodeLabelsOverhang,
            .portsOverhang,
            .uniformPortSpacing,
            .spaceEfficientPortLabels,
            .forceTabularNodeLabels,
            .asymmetrical
        ]
        return allOptions[i]
    }
}
