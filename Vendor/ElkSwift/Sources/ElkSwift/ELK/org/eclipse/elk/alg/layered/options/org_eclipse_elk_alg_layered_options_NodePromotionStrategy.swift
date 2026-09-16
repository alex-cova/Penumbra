// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/NodePromotionStrategy.java

import Foundation

/// Definitions of strategies for the node promotion heuristic.
package enum org_eclipse_elk_alg_layered_options_NodePromotionStrategy {
    /// Node promotion is not applied to the graph.
    case NONE

    /// Promotion strategy proposed by Nikolov et al. to keep layering width at worst
    /// as wide as the layering of the used layering algorithm.
    case NIKOLOV

    /// Nikolov strategy transferred to approximated pixel sizes of original and dummy nodes.
    case NIKOLOV_PIXEL

    /// Run node promotion without boundaries first; if maximal width is exceeded,
    /// dismiss and rerun with Nikolov strategy.
    case NIKOLOV_IMPROVED

    /// Like `NIKOLOV_IMPROVED`, but with approximated sizes of original and dummy nodes.
    case NIKOLOV_IMPROVED_PIXEL

    /// Stop when no promotions are left or when a configured percentage of dummy nodes
    /// has been reduced.
    case DUMMYNODE_PERCENTAGE

    /// Stop when no promotions are left or when a configured number of promotions
    /// (derived from node count percentage) was executed.
    case NODECOUNT_PERCENTAGE

    /// Run until there are no more promotions left to make.
    case NO_BOUNDARY

    /// Promote to conform to model order where applicable, left-to-right.
    case MODEL_ORDER_LEFT_TO_RIGHT

    /// Promote to conform to model order where applicable, right-to-left.
    case MODEL_ORDER_RIGHT_TO_LEFT
}
