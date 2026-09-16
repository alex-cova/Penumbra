

/**
 Enumeration for the definition of a side of the edge to place the (edge) label to.
 */
package enum LabelSide {
    /** The label's placement side hasn't been decided yet. */
    case UNKNOWN
    /** The label is placed above the edge. */
    case ABOVE
    /** The label is placed below the edge. */
    case BELOW
    /** The label is placed directly on top of the edge. */
    case INLINE

    /**
     Property set on edge and port labels by layout algorithms depending on which side they decide is
     appropriate for any given label.
     */
    package static let LABEL_SIDE: Property<LabelSide> = Property<LabelSide>(
        "org.eclipse.elk.labelSide", LabelSide.UNKNOWN
    )

    /**
     Returns the side opposite to the one this method is called on. UNKNOWN is mapped to itself.
     */
    package func opposite() -> LabelSide {
        switch self {
        case .ABOVE:
            return .BELOW
        case .BELOW:
            return .ABOVE
        case .INLINE:
            return .INLINE
        case .UNKNOWN:
            return .UNKNOWN
        }
    }
}
