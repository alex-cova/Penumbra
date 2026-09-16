// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/GreedySwitchType.java

import Foundation

/// Sets the variant of the greedy switch heuristic.
package enum org_eclipse_elk_alg_layered_options_GreedySwitchType {
    /// Only consider crossings to one side of the free layer.
    /// Calculate crossing matrix on demand.
    case ONE_SIDED

    /// Consider crossings to both sides of the free layer.
    /// Calculate crossing matrix on demand.
    case TWO_SIDED

    /// Do not use greedy switch.
    case OFF
}
