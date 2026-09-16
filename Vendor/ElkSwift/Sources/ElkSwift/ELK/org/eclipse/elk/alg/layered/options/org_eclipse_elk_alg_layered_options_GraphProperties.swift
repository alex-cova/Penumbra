// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/GraphProperties.java
import Foundation

/// An enumeration of properties a graph may have.
///
/// These can be used as part of an `EnumSet` to base decisions on graph properties.
package enum org_eclipse_elk_alg_layered_options_GraphProperties {
    /// The graph contains comment boxes.
    case COMMENTS

    /// The graph contains dummy nodes representing external ports.
    case EXTERNAL_PORTS

    /// The graph contains hyperedges.
    case HYPEREDGES

    /// The graph contains hypernodes (nodes that are marked as such).
    case HYPERNODES

    /// The graph contains ports that are not free for positioning.
    case NON_FREE_PORTS

    /// The graph contains ports on the northern or southern side.
    case NORTH_SOUTH_PORTS

    /// The graph contains self-loops.
    case SELF_LOOPS

    /// The graph contains node labels.
    case CENTER_LABELS

    /// The graph contains head or tail edge labels.
    case END_LABELS

    /// The graph's nodes are partitioned.
    case PARTITIONS
}
