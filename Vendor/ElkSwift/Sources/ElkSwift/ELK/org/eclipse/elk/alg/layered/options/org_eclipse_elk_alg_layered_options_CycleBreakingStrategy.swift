// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/CycleBreakingStrategy.java

import Foundation

package enum org_eclipse_elk_alg_layered_options_CycleBreakingStrategy: org_eclipse_elk_core_alg_ILayoutPhaseFactory {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph

    case GREEDY
    case DEPTH_FIRST
    case INTERACTIVE
    case MODEL_ORDER
    case GREEDY_MODEL_ORDER
    case SCC_CONNECTIVITY
    case SCC_NODE_TYPE
    case DFS_NODE_ORDER
    case BFS_NODE_ORDER

    package func create() -> any org_eclipse_elk_core_alg_ILayoutPhase {
        switch self {
        case .GREEDY:
            return org_eclipse_elk_alg_layered_p1cycles_GreedyCycleBreaker()
        case .DEPTH_FIRST:
            return org_eclipse_elk_alg_layered_p1cycles_DepthFirstCycleBreaker()
        case .INTERACTIVE:
            return org_eclipse_elk_alg_layered_p1cycles_InteractiveCycleBreaker()
        case .MODEL_ORDER:
            return org_eclipse_elk_alg_layered_p1cycles_ModelOrderCycleBreaker()
        case .GREEDY_MODEL_ORDER:
            return org_eclipse_elk_alg_layered_p1cycles_GreedyModelOrderCycleBreaker()
        case .SCC_CONNECTIVITY:
            return org_eclipse_elk_alg_layered_p1cycles_SCConnectivity()
        case .SCC_NODE_TYPE:
            return org_eclipse_elk_alg_layered_p1cycles_SCCNodeTypeCycleBreaker()
        case .DFS_NODE_ORDER:
            return org_eclipse_elk_alg_layered_p1cycles_DFSNodeOrderCycleBreaker()
        case .BFS_NODE_ORDER:
            return org_eclipse_elk_alg_layered_p1cycles_BFSNodeOrderCycleBreaker()
        }
    }
}

extension org_eclipse_elk_alg_layered_p1cycles_GreedyCycleBreaker: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_p1cycles_DepthFirstCycleBreaker: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_p1cycles_InteractiveCycleBreaker: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_p1cycles_ModelOrderCycleBreaker: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
// GreedyModelOrderCycleBreaker inherits ILayoutPhase from GreedyCycleBreaker
extension org_eclipse_elk_alg_layered_p1cycles_SCCModelOrderCycleBreaker: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
// SCConnectivity and SCCNodeTypeCycleBreaker inherit ILayoutPhase from SCCModelOrderCycleBreaker
extension org_eclipse_elk_alg_layered_p1cycles_DFSNodeOrderCycleBreaker: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_p1cycles_BFSNodeOrderCycleBreaker: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
