// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/ConstraintCalculationStrategy.java
import Foundation

/// Which strategy should be used by the OneDimensionalCompactor to calculate the constraint graph.
package enum org_eclipse_elk_alg_layered_options_ConstraintCalculationStrategy {
    /// Determine constraints by a pair-wise comparison of all elements.
    case QUADRATIC

    /// Use a scanline technique.
    case SCANLINE
}
