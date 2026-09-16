// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p5edges/orthogonal/HyperEdgeSegmentDependency.java

import Foundation

package final class org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency: CustomStringConvertible {
    package enum DependencyType: String {
        case REGULAR
        case CRITICAL
    }

    package static let CRITICAL_DEPENDENCY_WEIGHT = 1

    package let type: DependencyType
    package var source: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment?
    package var target: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment?
    package let weight: Int

    private init(
        _ type: DependencyType,
        _ source: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment,
        _ target: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment,
        _ weight: Int
    ) {
        self.type = type
        self.weight = weight
        setSource(source)
        setTarget(target)
    }

    @discardableResult
    package static func createAndAddRegular(
        _ source: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment,
        _ target: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment,
        _ weight: Int
    ) -> org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency {
        org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency(.REGULAR, source, target, weight)
    }

    @discardableResult
    package static func createAndAddCritical(
        _ source: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment,
        _ target: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment
    ) -> org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency {
        org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency(
            .CRITICAL,
            source,
            target,
            CRITICAL_DEPENDENCY_WEIGHT
        )
    }

    package func remove() {
        setSource(nil)
        setTarget(nil)
    }

    package func reverse() {
        let oldSource = source
        let oldTarget = target
        setSource(oldTarget)
        setTarget(oldSource)
    }

    package func getType() -> DependencyType {
        type
    }

    package func getSource() -> org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment? {
        source
    }

    package func setSource(_ newSource: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment?) {
        if let source {
            source.removeOutgoingSegmentDependency(self)
        }

        source = newSource

        if let source {
            source.appendOutgoingSegmentDependency(self)
        }
    }

    package func getTarget() -> org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment? {
        target
    }

    package func setTarget(_ newTarget: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment?) {
        if let target {
            target.removeIncomingSegmentDependency(self)
        }

        target = newTarget

        if let target {
            target.appendIncomingSegmentDependency(self)
        }
    }

    package func getWeight() -> Int {
        weight
    }

    package func toString() -> String {
        "\(String(describing: source))->\(String(describing: target)) (\(type.rawValue))"
    }

    package var description: String {
        toString()
    }
}
