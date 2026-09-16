// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/CenterEdgeLabelPlacementStrategy.java

import Foundation

package enum org_eclipse_elk_alg_layered_options_CenterEdgeLabelPlacementStrategy: CaseIterable, Hashable {
    case MEDIAN_LAYER
    case TAIL_LAYER
    case HEAD_LAYER
    case SPACE_EFFICIENT_LAYER
    case WIDEST_LAYER
    case CENTER_LAYER

    package func usesLabelSizeInformation() -> Bool {
        self == .WIDEST_LAYER
            || self == .CENTER_LAYER
            || self == .SPACE_EFFICIENT_LAYER
    }
}
