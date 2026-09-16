// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/OrderingStrategy.java

import Foundation

/// Strategy to order nodes and ports before crossing minimization.
package enum org_eclipse_elk_alg_layered_options_OrderingStrategy: String {
    /// Nothing is ordered.
    case NONE

    /// Nodes and edges are ordered.
    case NODES_AND_EDGES

    /// Node ordering is used only as a secondary criterion. Edge order is preserved.
    case PREFER_EDGES

    /// Prefer node order.
    case PREFER_NODES
}
