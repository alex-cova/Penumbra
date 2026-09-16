// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/FixedAlignment.java
import Foundation

/// Layout option for the choice of candidates in the Brandes and Koepf node placement.
package enum org_eclipse_elk_alg_layered_options_FixedAlignment: String {
    /// Chooses the smallest layout from the four possible candidates.
    case NONE

    /// Chooses the left-up candidate from the four possible candidates.
    case LEFTUP

    /// Chooses the right-up candidate from the four possible candidates.
    case RIGHTUP

    /// Chooses the left-down candidate from the four possible candidates.
    case LEFTDOWN

    /// Chooses the right-down candidate from the four possible candidates.
    case RIGHTDOWN

    /// Creates a balanced layout from the four possible candidates.
    case BALANCED
}
