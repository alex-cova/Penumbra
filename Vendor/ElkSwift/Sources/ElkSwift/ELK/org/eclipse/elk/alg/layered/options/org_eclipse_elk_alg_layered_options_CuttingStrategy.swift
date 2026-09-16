// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/CuttingStrategy.java
import Foundation

/// Specifies the strategy employed to calculate cut indexes during graph wrapping.
package enum org_eclipse_elk_alg_layered_options_CuttingStrategy {
    /// Aspect ratio-driven cut calculation heuristic.
    case ARD

    /// Max scale-driven cut calculation heuristic.
    case MSD

    /// Cuts are manually specified by a user via LayeredOptions.WRAPPING_CUTTING_CUTS.
    case MANUAL
}
