// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/WrappingStrategy.java

import Foundation

package enum org_eclipse_elk_alg_layered_options_WrappingStrategy {
    /// Off.
    case OFF
    /// At each cut point, only a single edge may wrap backwards. Consequently it is only
    /// possible to cut between pairs of layers that are connected (and spanned) by a single edge.
    case SINGLE_EDGE
    /// It is allowed that multiple edges wrap backwards at a cut point. An additional objective
    /// is thus to keep the number of edges wrapping backwards small.
    case MULTI_EDGE
}
