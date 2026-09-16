// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/EdgeConstraint.java
import Foundation

/// Enumeration of edge constraints.
/// Edge constraints can be set on ports to constrain the type of edges incident to that port.
package enum org_eclipse_elk_alg_layered_options_EdgeConstraint {
    /// No constraint on incident edges.
    case NONE

    /// Node may have only incoming edges.
    case INCOMING_ONLY

    /// Node may have only outgoing edges.
    case OUTGOING_ONLY
}
