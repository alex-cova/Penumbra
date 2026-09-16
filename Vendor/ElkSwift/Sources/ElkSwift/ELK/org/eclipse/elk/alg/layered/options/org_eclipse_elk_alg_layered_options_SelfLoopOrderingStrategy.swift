// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/SelfLoopOrderingStrategy.java

import Foundation

package enum org_eclipse_elk_alg_layered_options_SelfLoopOrderingStrategy {
    /// Self loops will be stacked or nested high.
    case STACKED
    /// Self loops will be stacked or nested high with the first self loop on top.
    case REVERSE_STACKED
    /// Self loops will be placed next to each other.
    case SEQUENCED
}
