// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/LayerConstraint.java

import Foundation

/// Enumeration of layer constraint types.
package enum org_eclipse_elk_alg_layered_options_LayerConstraint {
    /// No constraint on the layering.
    case NONE

    /// Put into the first layer.
    case FIRST

    /// Put into a separate first layer; used internally.
    case FIRST_SEPARATE

    /// Put into the last layer.
    case LAST

    /// Put into a separate last layer; used internally.
    case LAST_SEPARATE
}
