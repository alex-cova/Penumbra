// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/InLayerConstraint.java

import Foundation

/// Enumeration of in-layer constraint types.
package enum org_eclipse_elk_alg_layered_options_InLayerConstraint {
    /// No constraint on in-layer placement.
    case NONE

    /// Float node to the top of the layer, along with other nodes with this constraint.
    case TOP

    /// Float node to the bottom of the layer, along with other nodes with this constraint.
    case BOTTOM
}
