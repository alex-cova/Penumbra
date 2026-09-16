// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p5edges/orthogonal/direction/BaseRoutingDirectionStrategy.java

import Foundation

package class org_eclipse_elk_alg_layered_p5edges_orthogonal_direction_BaseRoutingDirectionStrategy {

    package static let JUNCTION_POINTS_KEY: any IProperty = Property<org_eclipse_elk_core_math_KVectorChain>("org.eclipse.elk.junctionPoints")

    /// set of already created junction points, to avoid multiple points at the same position.
    package var createdJunctionPoints: Set<org_eclipse_elk_core_math_KVector> = []

    package init() {}

    // MARK: - Factory

    /// Returns an implementation suitable for the given routing direction.
    package static func forRoutingDirection(
        _ direction: org_eclipse_elk_alg_layered_p5edges_orthogonal_direction_RoutingDirection
    ) -> org_eclipse_elk_alg_layered_p5edges_orthogonal_direction_BaseRoutingDirectionStrategy {
        switch direction {
        case .WEST_TO_EAST:
            return org_eclipse_elk_alg_layered_p5edges_orthogonal_direction_WestToEastRoutingStrategy()
        case .NORTH_TO_SOUTH:
            return org_eclipse_elk_alg_layered_p5edges_orthogonal_direction_NorthToSouthRoutingStrategy()
        case .SOUTH_TO_NORTH:
            return org_eclipse_elk_alg_layered_p5edges_orthogonal_direction_SouthToNorthRoutingStrategy()
        }
    }

    // MARK: - Junction Points

    /// Add a junction point to the given edge if necessary.
    package func addJunctionPointIfNecessary(
        _ edge: org_eclipse_elk_alg_layered_graph_LEdge,
        _ segment: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment,
        _ pos: org_eclipse_elk_core_math_KVector,
        _ vertical: Bool
    ) {
        let p = vertical ? pos.y : pos.x

        // If we already have this junction point, don't bother
        if createdJunctionPoints.contains(pos) {
            return
        }

        // Whether the point lies somewhere inside the edge segment (without boundaries)
        let pointInsideEdgeSegment = p > segment.getStartCoordinate() && p < segment.getEndCoordinate()

        // Check if the point lies somewhere at the segment's boundary
        var pointAtSegmentBoundary = false
        let inCoords = segment.getIncomingConnectionCoordinates()
        let outCoords = segment.getOutgoingConnectionCoordinates()
        if let inFirst = inCoords.first, let outFirst = outCoords.first,
           let inLast = inCoords.last, let outLast = outCoords.last {

            // Is the bend point at the start and joins another edge at the same position?
            pointAtSegmentBoundary = pointAtSegmentBoundary
                || (abs(p - inFirst)
                    < org_eclipse_elk_alg_layered_p5edges_orthogonal_OrthogonalRoutingGenerator.TOLERANCE
                    && abs(p - outFirst)
                        < org_eclipse_elk_alg_layered_p5edges_orthogonal_OrthogonalRoutingGenerator.TOLERANCE)

            // Is the bend point at the end and joins another edge at the same position?
            pointAtSegmentBoundary = pointAtSegmentBoundary
                || (abs(p - inLast)
                    < org_eclipse_elk_alg_layered_p5edges_orthogonal_OrthogonalRoutingGenerator.TOLERANCE
                    && abs(p - outLast)
                        < org_eclipse_elk_alg_layered_p5edges_orthogonal_OrthogonalRoutingGenerator.TOLERANCE)
        }

        if pointInsideEdgeSegment || pointAtSegmentBoundary {
            // create a new junction point for the edge at the bend point's position
            var junctionPoints: org_eclipse_elk_core_math_KVectorChain
            if let existing: org_eclipse_elk_core_math_KVectorChain = edge.getProperty(org_eclipse_elk_alg_layered_p5edges_orthogonal_direction_BaseRoutingDirectionStrategy.JUNCTION_POINTS_KEY) {
                junctionPoints = existing
            } else {
                junctionPoints = org_eclipse_elk_core_math_KVectorChain()
                edge.setProperty(org_eclipse_elk_alg_layered_p5edges_orthogonal_direction_BaseRoutingDirectionStrategy.JUNCTION_POINTS_KEY, junctionPoints)
            }

            let jpoint = org_eclipse_elk_core_math_KVector(pos)
            junctionPoints.add(jpoint)
            createdJunctionPoints.insert(jpoint)
        }
    }

    /// Removes all junction points created so far.
    package func clearCreatedJunctionPoints() {
        createdJunctionPoints.removeAll()
    }

    /// Returns the set of junction points created so far.
    package func getCreatedJunctionPoints() -> Set<org_eclipse_elk_core_math_KVector> {
        return createdJunctionPoints
    }

    // MARK: - Abstract methods (to be overridden by subclasses)

    /// Returns the port's position on a hyper edge axis.
    package func getPortPositionOnHyperNode(_ port: org_eclipse_elk_alg_layered_graph_LPort) -> Double {
        assertionFailure("Subclass must override getPortPositionOnHyperNode")
        return 0
    }

    /// Returns the side of ports that should be considered on a source layer.
    package func getSourcePortSide() -> org_eclipse_elk_core_options_PortSide {
        assertionFailure("Subclass must override getSourcePortSide")
        return .UNDEFINED
    }

    /// Returns the side of ports that should be considered on a target layer.
    package func getTargetPortSide() -> org_eclipse_elk_core_options_PortSide {
        assertionFailure("Subclass must override getTargetPortSide")
        return .UNDEFINED
    }

    /// Calculates and assigns bend points for edges incident to the ports belonging to the given hyper edge.
    package func calculateBendPoints(
        _ hyperNode: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment,
        _ startPos: Double,
        _ edgeSpacing: Double
    ) {
        assertionFailure("Subclass must override calculateBendPoints")
    }
}
