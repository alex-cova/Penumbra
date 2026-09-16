// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/SelfLoopDistributionStrategy.java

import Foundation

package enum org_eclipse_elk_alg_layered_options_SelfLoopDistributionStrategy {
    /// Distributes the loops equally around the node.
    case EQUALLY
    /// Puts all loops to the north side of the node.
    case NORTH
    /// Loops are distributed over the north and the south side of the node.
    case NORTH_SOUTH
}
