// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/LayeringStrategy.java

import Foundation

package enum org_eclipse_elk_alg_layered_options_LayeringStrategy: org_eclipse_elk_core_alg_ILayoutPhaseFactory {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph

    /// All nodes will be layered with minimal edge length by using the network-simplex algorithm.
    case NETWORK_SIMPLEX

    /// All nodes will be layered according to the longest path to any sink.
    case LONGEST_PATH

    /// All nodes will be layered according to the longest path to any source.
    case LONGEST_PATH_SOURCE

    /// Restricts the number of original nodes in any layer.
    case COFFMAN_GRAHAM

    /// Layers according to relative node positions from input.
    case INTERACTIVE

    /// Similar to LONGEST_PATH, but tries to reduce max nodes per layer.
    case STRETCH_WIDTH

    /// MinWidth heuristic for minimum-width layering with dummy-node awareness.
    case MIN_WIDTH

    /// Breadth-first model-order-driven layering.
    case BF_MODEL_ORDER

    /// Depth-first model-order-driven layering.
    case DF_MODEL_ORDER

    package func create() -> any org_eclipse_elk_core_alg_ILayoutPhase {
        switch self {
        case .NETWORK_SIMPLEX:
            return org_eclipse_elk_alg_layered_p2layers_NetworkSimplexLayerer()
        case .LONGEST_PATH:
            return org_eclipse_elk_alg_layered_p2layers_LongestPathLayerer()
        case .COFFMAN_GRAHAM:
            return org_eclipse_elk_alg_layered_p2layers_CoffmanGrahamLayerer()
        case .INTERACTIVE:
            return org_eclipse_elk_alg_layered_p2layers_InteractiveLayerer()
        case .STRETCH_WIDTH:
            return org_eclipse_elk_alg_layered_p2layers_StretchWidthLayerer()
        case .MIN_WIDTH:
            return org_eclipse_elk_alg_layered_p2layers_MinWidthLayerer()
        case .LONGEST_PATH_SOURCE:
            return org_eclipse_elk_alg_layered_p2layers_LongestPathSourceLayerer()
        case .BF_MODEL_ORDER:
            return org_eclipse_elk_alg_layered_p2layers_BreadthFirstModelOrderLayerer()
        case .DF_MODEL_ORDER:
            return org_eclipse_elk_alg_layered_p2layers_DepthFirstModelOrderLayerer()
        }
    }
}

// Classes that already have process() and getLayoutProcessorConfiguration() defined
extension org_eclipse_elk_alg_layered_p2layers_LongestPathLayerer: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_p2layers_InteractiveLayerer: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_p2layers_LongestPathSourceLayerer: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_p2layers_BreadthFirstModelOrderLayerer: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}

extension org_eclipse_elk_alg_layered_p2layers_NetworkSimplexLayerer: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_p2layers_CoffmanGrahamLayerer: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {}
    package func getLayoutProcessorConfiguration(_ graph: LGraph) -> LayoutProcessorConfiguration<LayeredPhases, LGraph>? { nil }
}
extension org_eclipse_elk_alg_layered_p2layers_StretchWidthLayerer: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {}
    package func getLayoutProcessorConfiguration(_ graph: LGraph) -> LayoutProcessorConfiguration<LayeredPhases, LGraph>? { nil }
}
extension org_eclipse_elk_alg_layered_p2layers_MinWidthLayerer: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {}
    package func getLayoutProcessorConfiguration(_ graph: LGraph) -> LayoutProcessorConfiguration<LayeredPhases, LGraph>? { nil }
}
extension org_eclipse_elk_alg_layered_p2layers_DepthFirstModelOrderLayerer: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {}
    package func getLayoutProcessorConfiguration(_ graph: LGraph) -> LayoutProcessorConfiguration<LayeredPhases, LGraph>? { nil }
}
