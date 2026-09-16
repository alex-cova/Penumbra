// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/NodePlacementStrategy.java

import Foundation

package enum org_eclipse_elk_alg_layered_options_NodePlacementStrategy: org_eclipse_elk_core_alg_ILayoutPhaseFactory {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph

    case SIMPLE
    case INTERACTIVE
    case LINEAR_SEGMENTS
    case BRANDES_KOEPF
    case NETWORK_SIMPLEX

    package func create() -> any org_eclipse_elk_core_alg_ILayoutPhase {
        switch self {
        case .SIMPLE:
            return org_eclipse_elk_alg_layered_p4nodes_SimpleNodePlacer()
        case .INTERACTIVE:
            return org_eclipse_elk_alg_layered_p4nodes_InteractiveNodePlacer()
        case .LINEAR_SEGMENTS:
            return org_eclipse_elk_alg_layered_p4nodes_LinearSegmentsNodePlacer()
        case .BRANDES_KOEPF:
            return org_eclipse_elk_alg_layered_p4nodes_bk_BKNodePlacer()
        case .NETWORK_SIMPLEX:
            return org_eclipse_elk_alg_layered_p4nodes_NetworkSimplexPlacer()
        }
    }
}

extension org_eclipse_elk_alg_layered_p4nodes_SimpleNodePlacer: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_p4nodes_InteractiveNodePlacer: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_p4nodes_LinearSegmentsNodePlacer: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_p4nodes_bk_BKNodePlacer: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_p4nodes_NetworkSimplexPlacer: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
