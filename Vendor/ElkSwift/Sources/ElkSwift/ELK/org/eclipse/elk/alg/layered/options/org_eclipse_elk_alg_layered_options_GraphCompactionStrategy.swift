// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/GraphCompactionStrategy.java
import Foundation

/// Definition of strategies for horizontal compaction.
package enum org_eclipse_elk_alg_layered_options_GraphCompactionStrategy {
    /// Does not apply compaction.
    case NONE

    /// Compacts to the left.
    case LEFT

    /// Compacts to the right.
    case RIGHT

    /// Compacts left, locks CNodes that are not constrained, then compacts right.
    case LEFT_RIGHT_CONSTRAINT_LOCKING

    /// Compacts left, locks CNodes based on their CompactionLock, then compacts right.
    /// Yields better results for average edge length because CNodes are locked in the
    /// direction of fewer connections.
    case LEFT_RIGHT_CONNECTION_LOCKING

    /// Compacts as much as possible, but minimizes edge length instead of width.
    case EDGE_LENGTH
}
