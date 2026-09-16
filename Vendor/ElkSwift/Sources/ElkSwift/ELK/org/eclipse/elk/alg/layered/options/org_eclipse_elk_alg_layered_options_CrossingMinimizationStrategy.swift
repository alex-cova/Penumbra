// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/CrossingMinimizationStrategy.java

import Foundation

package enum org_eclipse_elk_alg_layered_options_CrossingMinimizationStrategy: org_eclipse_elk_core_alg_ILayoutPhaseFactory {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph

    case LAYER_SWEEP
    case MEDIAN_LAYER_SWEEP
    case INTERACTIVE
    case NONE

    package func create() -> any org_eclipse_elk_core_alg_ILayoutPhase {
        switch self {
        case .LAYER_SWEEP:
            return org_eclipse_elk_alg_layered_p3order_LayerSweepCrossingMinimizer(.BARYCENTER)
        case .MEDIAN_LAYER_SWEEP:
            return org_eclipse_elk_alg_layered_p3order_LayerSweepCrossingMinimizer(.MEDIAN)
        case .INTERACTIVE:
            return org_eclipse_elk_alg_layered_p3order_InteractiveCrossingMinimizer()
        case .NONE:
            return org_eclipse_elk_alg_layered_p3order_NoCrossingMinimizer()
        }
    }
}

extension org_eclipse_elk_alg_layered_p3order_LayerSweepCrossingMinimizer: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_p3order_InteractiveCrossingMinimizer: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_p3order_NoCrossingMinimizer: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
