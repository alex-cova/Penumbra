// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/PortSortingStrategy.java

import Foundation

package enum org_eclipse_elk_alg_layered_options_PortSortingStrategy {
    /// Distributes the ports to their respective sides but preserves the input order
    /// among the ports of a common side.
    case INPUT_ORDER

    /// Using `INPUT_ORDER` as basis, additionally sort the ports on the WEST and EAST
    /// side according to the individual port's out-degree and in-degree, respectively
    /// (that is, the degree in the original input graph).
    case PORT_DEGREE
}
