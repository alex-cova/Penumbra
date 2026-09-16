// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/LayerUnzippingStrategy.java

import Foundation

/// Strategies for unzipping layers by splitting nodes into multiple layers.
package enum org_eclipse_elk_alg_layered_options_LayerUnzippingStrategy {
    /// Disable layer unzipping.
    case NONE

    /// Split all layers with more than two nodes into several layers in an alternating pattern.
    case ALTERNATING
}
