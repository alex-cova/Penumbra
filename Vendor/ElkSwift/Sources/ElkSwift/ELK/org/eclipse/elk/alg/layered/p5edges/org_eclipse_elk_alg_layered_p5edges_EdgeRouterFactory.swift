// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p5edges/EdgeRouterFactory.java

import Foundation

package enum org_eclipse_elk_alg_layered_p5edges_EdgeRouterFactory: org_eclipse_elk_core_alg_ILayoutPhaseFactory {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph

    case POLYLINE
    case ORTHOGONAL
    case SPLINES

    package func create() -> any org_eclipse_elk_core_alg_ILayoutPhase {
        switch self {
        case .POLYLINE:
            return org_eclipse_elk_alg_layered_p5edges_PolylineEdgeRouter()
        case .ORTHOGONAL:
            return org_eclipse_elk_alg_layered_p5edges_OrthogonalEdgeRouter()
        case .SPLINES:
            assertionFailure("Spline routing is not supported")
            return org_eclipse_elk_alg_layered_p5edges_OrthogonalEdgeRouter()
        }
    }

    package static func factoryFor(_ edgeRouting: EdgeRouting) -> org_eclipse_elk_alg_layered_p5edges_EdgeRouterFactory {
        switch edgeRouting {
        case .POLYLINE:
            return .POLYLINE
        case .ORTHOGONAL:
            return .ORTHOGONAL
        case .SPLINES:
            return .SPLINES
        default:
            return .ORTHOGONAL
        }
    }
}

extension org_eclipse_elk_alg_layered_p5edges_PolylineEdgeRouter: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_p5edges_OrthogonalEdgeRouter: org_eclipse_elk_core_alg_ILayoutPhase {
    package typealias P = LayeredPhases
    package typealias PhaseGraph = LGraph
    package typealias G = LGraph
}
// REMOVED: SplineEdgeRouter extension (splines dead code)
