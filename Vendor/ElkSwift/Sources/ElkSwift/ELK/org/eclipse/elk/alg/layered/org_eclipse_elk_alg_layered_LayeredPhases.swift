import Foundation

/**
 * All phases the layered approach is divided into.
 */
package enum LayeredPhases: Int, CaseIterable {

    /** Elimination of cycles through edge reversal. */
    case p1CycleBreaking

    /** Division of nodes into distinct layers. */
    case p2Layering

    /** Computation of an order of nodes in each layer, usually to reduce crossings. */
    case p3NodeOrdering

    /** Assignment of y coordinates. */
    case p4NodePlacement

    /** Edge routing and assignment of x coordinates. */
    case p5EdgeRouting

    // Java-style static constants for compatibility with transpiled code
    package static let P1_CYCLE_BREAKING: LayeredPhases = .p1CycleBreaking
    package static let P2_LAYERING: LayeredPhases = .p2Layering
    package static let P3_NODE_ORDERING: LayeredPhases = .p3NodeOrdering
    package static let P4_NODE_PLACEMENT: LayeredPhases = .p4NodePlacement
    package static let P5_EDGE_ROUTING: LayeredPhases = .p5EdgeRouting

}
