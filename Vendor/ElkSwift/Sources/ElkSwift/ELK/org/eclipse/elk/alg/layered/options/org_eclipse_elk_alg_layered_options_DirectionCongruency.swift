// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/DirectionCongruency.java
import Foundation

/// Allows specifying how drawings of the same graph with different layout directions compare to each other.
package enum org_eclipse_elk_alg_layered_options_DirectionCongruency {
    /// The vertical reading direction of left-to-right or right-to-left corresponds to the
    /// horizontal reading direction of top-to-bottom or bottom-to-top.
    case READING_DIRECTION

    /// The four possible drawings are simply rotated versions of the left-to-right variant.
    case ROTATION
}
