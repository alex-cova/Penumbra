// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/SelfLoopPlacementStrategy.java

import Foundation

package enum org_eclipse_elk_alg_layered_options_SelfLoopPlacementStrategy {
    /// Distributes the loops equally around the node.
    case EQUALLY_DISTRIBUTED
    /// Stacks all loops to the north side of the node.
    case NORTH_STACKED
    /// Loops are placed sequentially (next to each other) to the north side of the node.
    case NORTH_SEQUENCE
}
