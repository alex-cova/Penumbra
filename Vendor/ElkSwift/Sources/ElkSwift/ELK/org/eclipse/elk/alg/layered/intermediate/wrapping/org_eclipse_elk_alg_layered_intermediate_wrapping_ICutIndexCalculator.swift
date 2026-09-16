// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/wrapping/ICutIndexCalculator.java
import Foundation

package protocol org_eclipse_elk_alg_layered_intermediate_wrapping_ICutIndexCalculator {
    func getCutIndexes(
        _ graph: LGraph,
        _ gs: org_eclipse_elk_alg_layered_intermediate_wrapping_GraphStats
    ) -> [Int]

    func guaranteeValid() -> Bool
}

/// Simple ICutIndexCalculator that reads manually specified cut indexes from
/// the WRAPPING_CUTTING_CUTS layout option.
package class org_eclipse_elk_alg_layered_intermediate_wrapping_ICutIndexCalculator_ManualCutIndexCalculator:
    org_eclipse_elk_alg_layered_intermediate_wrapping_ICutIndexCalculator
{
    // Mirrors LayeredOptions.WRAPPING_CUTTING_CUTS.
    package static let WRAPPING_CUTTING_CUTS_KEY = "org.eclipse.elk.layered.wrapping.cutting.cuts"

    package init() {}

    package func getCutIndexes(
        _ graph: LGraph,
        _ gs: org_eclipse_elk_alg_layered_intermediate_wrapping_GraphStats
    ) -> [Int] {
        graph.getProperty(Self.WRAPPING_CUTTING_CUTS_KEY) as? [Int] ?? []
    }

    package func guaranteeValid() -> Bool {
        false
    }
}
