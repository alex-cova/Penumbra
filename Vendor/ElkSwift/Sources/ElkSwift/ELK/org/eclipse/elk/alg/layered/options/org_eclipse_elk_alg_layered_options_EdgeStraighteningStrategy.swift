// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/EdgeStraighteningStrategy.java
import Foundation

/// Specifies how the compaction step of the BKNodePlacer should be executed.
package enum org_eclipse_elk_alg_layered_options_EdgeStraighteningStrategy {
    /// As specified in the original paper.
    case NONE

    /// An integrated method trying to increase the number of straight edges.
    case IMPROVE_STRAIGHTNESS
}
