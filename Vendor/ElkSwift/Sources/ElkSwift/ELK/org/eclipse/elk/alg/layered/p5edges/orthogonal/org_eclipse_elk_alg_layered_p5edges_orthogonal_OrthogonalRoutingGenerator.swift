// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p5edges/orthogonal/OrthogonalRoutingGenerator.java

import Foundation

package final class org_eclipse_elk_alg_layered_p5edges_orthogonal_OrthogonalRoutingGenerator {

    // MARK: - Constants

    /// differences below this tolerance value are treated as zero.
    package static let TOLERANCE: Double = 1e-3

    /// a special return value used by the conflict counting method.
    package static let CRITICAL_CONFLICTS_DETECTED: Int = -1

    /// factor for edge spacing used to determine the conflictThreshold (determined experimentally).
    package static let CONFLICT_THRESHOLD_FACTOR: Double = 0.5
    /// factor to compute criticalConflictThreshold (determined experimentally).
    package static let CRITICAL_CONFLICT_THRESHOLD_FACTOR: Double = 0.2

    /// weight penalty for (non-critical) conflicts.
    package static let CONFLICT_PENALTY: Int = 1
    /// weight penalty for crossings.
    package static let CROSSING_PENALTY: Int = 16

    /// we'll be using this thing to split hyper edge segments, if necessary.
    package var segmentSplitter: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentSplitter?

    /// routing direction strategy.
    package let routingStrategy: org_eclipse_elk_alg_layered_p5edges_orthogonal_direction_BaseRoutingDirectionStrategy
    /// spacing between edges.
    package let edgeSpacing: Double

    /// Threshold at which horizontal line segments are considered to be too close to one another.
    package let conflictThreshold: Double
    /// Threshold at which horizontal line segments are considered to overlap.
    package var criticalConflictThreshold: Double = 0

    /// prefix of debug output files.
    package let debugPrefix: String?

    // MARK: - Initialization

    package init() {
        self.routingStrategy = org_eclipse_elk_alg_layered_p5edges_orthogonal_direction_BaseRoutingDirectionStrategy()
        self.edgeSpacing = 0
        self.conflictThreshold = 0
        self.debugPrefix = nil
    }

    package init(
        _ direction: org_eclipse_elk_alg_layered_p5edges_orthogonal_direction_RoutingDirection,
        _ edgeSpacing: Double,
        _ debugPrefix: String?
    ) {
        self.routingStrategy = org_eclipse_elk_alg_layered_p5edges_orthogonal_direction_BaseRoutingDirectionStrategy.forRoutingDirection(direction)
        self.edgeSpacing = edgeSpacing
        self.conflictThreshold = Self.CONFLICT_THRESHOLD_FACTOR * edgeSpacing
        self.debugPrefix = debugPrefix
    }

    // MARK: - Route Edges

    /// Routes edges between two layers.
    /// Returns the number of routing slots used.
    package func routeEdges(
        _ monitor: IElkProgressMonitor,
        _ layeredGraph: LGraph,
        _ sourceLayerNodes: [LNode]?,
        _ sourceLayerIndex: Int,
        _ targetLayerNodes: [LNode]?,
        _ startPos: Double
    ) -> Int {
        // Keep track of our hyperedge segments, and which ports they were created for
        var portToEdgeSegmentMap = [ObjectIdentifier: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment]()
        var edgeSegments = [org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment]()

        // create hyperedge segments for eastern output ports of the left layer and for western output ports of
        // the right layer
        createHyperEdgeSegments(
            sourceLayerNodes, routingStrategy.getSourcePortSide(), &edgeSegments, &portToEdgeSegmentMap)
        createHyperEdgeSegments(
            targetLayerNodes, routingStrategy.getTargetPortSide(), &edgeSegments, &portToEdgeSegmentMap)

        // Our critical conflict threshold is a fraction of the minimum distance between two horizontal hyperedge
        // segments
        criticalConflictThreshold = Self.CRITICAL_CONFLICT_THRESHOLD_FACTOR * minimumHorizontalSegmentDistance(edgeSegments)

        // create dependencies for the hyperedge segment ordering graph and note how many critical dependencies have
        // been created
        var criticalDependencyCount = 0
        for firstIdx in 0..<max(0, edgeSegments.count - 1) {
            let firstSegment = edgeSegments[firstIdx]
            for secondIdx in (firstIdx + 1)..<edgeSegments.count {
                criticalDependencyCount += createDependencyIfNecessary(firstSegment, edgeSegments[secondIdx])
            }
        }

        // if there are at least two critical dependencies, there may be critical cycles that need to be broken
        if criticalDependencyCount >= 2 {
            breakCriticalCycles(&edgeSegments)
        }

        // break non-critical cycles
        Self.breakNonCriticalCycles(edgeSegments)

        // assign ranks to the edge segments
        Self.topologicalNumbering(edgeSegments)

        // set bend points with appropriate coordinates
        var rankCount = -1
        for node in edgeSegments {
            // edges that are just straight lines don't take up a slot and don't need bend points
            if abs(node.getStartCoordinate() - node.getEndCoordinate()) < Self.TOLERANCE {
                continue
            }

            rankCount = max(rankCount, node.getRoutingSlot())

            routingStrategy.calculateBendPoints(node, startPos, edgeSpacing)
        }

        // release the created resources
        routingStrategy.clearCreatedJunctionPoints()
        return rankCount + 1
    }

    // MARK: - Hyper Edge Segment Creation

    /// Creates hyperedge segments for the given layer.
    private func createHyperEdgeSegments(
        _ nodes: [LNode]?,
        _ portSide: org_eclipse_elk_core_options_PortSide,
        _ hyperEdges: inout [org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment],
        _ portToHyperEdgeSegmentMap: inout [ObjectIdentifier: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment]
    ) {
        guard let nodes = nodes else { return }

        for node in nodes {
            for port in node.getPorts(.OUTPUT, portSide) {
                let hyperEdge = portToHyperEdgeSegmentMap[ObjectIdentifier(port)]
                if hyperEdge == nil {
                    let newHyperEdge = org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment(routingStrategy)
                    hyperEdges.append(newHyperEdge)
                    newHyperEdge.addPortPositions(port, &portToHyperEdgeSegmentMap)
                }
            }
        }
    }

    // MARK: - Minimum Distance

    /// Computes and returns the minimum distance between any two adjacent source connections and any two adjacent target
    /// connections.
    private func minimumHorizontalSegmentDistance(
        _ edgeSegments: [org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment]
    ) -> Double {
        var allIncoming = [Double]()
        var allOutgoing = [Double]()

        for segment in edgeSegments {
            allIncoming.append(contentsOf: segment.getIncomingConnectionCoordinates())
            allOutgoing.append(contentsOf: segment.getOutgoingConnectionCoordinates())
        }

        let minIncomingDistance = Self.minimumDifference(allIncoming)
        let minOutgoingDistance = Self.minimumDifference(allOutgoing)

        return min(minIncomingDistance, minOutgoingDistance)
    }

    /// Returns the smallest difference between any two numbers in the given list.
    /// If there are less than two distinct numbers, returns Double.greatestFiniteMagnitude.
    private static func minimumDifference(_ numbers: [Double]) -> Double {
        let sorted = Array(Set(numbers)).sorted()

        var minDifference = Double.greatestFiniteMagnitude

        if sorted.count >= 2 {
            for i in 1..<sorted.count {
                let diff = sorted[i] - sorted[i - 1]
                minDifference = min(minDifference, diff)
            }
        }

        return minDifference
    }

    // MARK: - Dependency Creation

    /// Create dependencies between the two given hyperedge segments, if one is needed.
    @discardableResult
    package func createDependencyIfNecessary(
        _ he1: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment,
        _ he2: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment
    ) -> Int {
        // check if at least one of the two nodes is just a straight line; those don't
        // create dependencies since they don't take up a slot
        if abs(he1.getStartCoordinate() - he1.getEndCoordinate()) < Self.TOLERANCE
            || abs(he2.getStartCoordinate() - he2.getEndCoordinate()) < Self.TOLERANCE {
            return 0
        }

        // compare number of conflicts for both variants
        let conflicts1 = countConflicts(he1.getOutgoingConnectionCoordinates(), he2.getIncomingConnectionCoordinates())
        let conflicts2 = countConflicts(he2.getOutgoingConnectionCoordinates(), he1.getIncomingConnectionCoordinates())

        let criticalConflictsDetected =
            conflicts1 == Self.CRITICAL_CONFLICTS_DETECTED || conflicts2 == Self.CRITICAL_CONFLICTS_DETECTED
        var criticalDependencyCount = 0

        if criticalConflictsDetected {
            if conflicts1 == Self.CRITICAL_CONFLICTS_DETECTED {
                org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency.createAndAddCritical(he2, he1)
                criticalDependencyCount += 1
            }

            if conflicts2 == Self.CRITICAL_CONFLICTS_DETECTED {
                org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency.createAndAddCritical(he1, he2)
                criticalDependencyCount += 1
            }

        } else {
            var crossings1 = Self.countCrossings(
                he1.getOutgoingConnectionCoordinates(), he2.getStartCoordinate(), he2.getEndCoordinate())
            crossings1 += Self.countCrossings(
                he2.getIncomingConnectionCoordinates(), he1.getStartCoordinate(), he1.getEndCoordinate())
            var crossings2 = Self.countCrossings(
                he2.getOutgoingConnectionCoordinates(), he1.getStartCoordinate(), he1.getEndCoordinate())
            crossings2 += Self.countCrossings(
                he1.getIncomingConnectionCoordinates(), he2.getStartCoordinate(), he2.getEndCoordinate())

            let depValue1 = Self.CONFLICT_PENALTY * conflicts1 + Self.CROSSING_PENALTY * crossings1
            let depValue2 = Self.CONFLICT_PENALTY * conflicts2 + Self.CROSSING_PENALTY * crossings2

            if depValue1 < depValue2 {
                org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency.createAndAddRegular(he1, he2, depValue2 - depValue1)
            } else if depValue1 > depValue2 {
                org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency.createAndAddRegular(he2, he1, depValue1 - depValue2)
            } else if depValue1 > 0 && depValue2 > 0 {
                org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency.createAndAddRegular(he1, he2, 0)
                org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency.createAndAddRegular(he2, he1, 0)
            }
        }

        return criticalDependencyCount
    }

    /// Counts the number of conflicts for the given lists of positions.
    package func countConflicts(_ posis1: [Double], _ posis2: [Double]) -> Int {
        var conflicts = 0

        if !posis1.isEmpty && !posis2.isEmpty {
            var iter1Index = 0
            var iter2Index = 0
            var pos1 = posis1[iter1Index]
            var pos2 = posis2[iter2Index]
            var hasMore = true

            repeat {
                if pos1 > pos2 - criticalConflictThreshold && pos1 < pos2 + criticalConflictThreshold {
                    return -1
                } else if pos1 > pos2 - conflictThreshold && pos1 < pos2 + conflictThreshold {
                    conflicts += 1
                }

                if pos1 <= pos2 && iter1Index + 1 < posis1.count {
                    iter1Index += 1
                    pos1 = posis1[iter1Index]
                } else if pos2 <= pos1 && iter2Index + 1 < posis2.count {
                    iter2Index += 1
                    pos2 = posis2[iter2Index]
                } else {
                    hasMore = false
                }
            } while hasMore
        }

        return conflicts
    }

    /// Counts the number of crossings for a given list of positions.
    package static func countCrossings(_ posis: [Double], _ start: Double, _ end: Double) -> Int {
        var crossings = 0
        for pos in posis {
            if pos > end {
                break
            } else if pos >= start {
                crossings += 1
            }
        }
        return crossings
    }

    // MARK: - Cycle Breaking

    /// Finds and breaks critical cycles to avoid edge overlaps.
    private func breakCriticalCycles(
        _ edgeSegments: inout [org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment]
    ) {
        let cycleDependencies =
            org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeCycleDetector.detectCycles(edgeSegments, true)

        // Lazy initialisation
        if segmentSplitter == nil {
            segmentSplitter = org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentSplitter(self)
        }

        guard let splitter = segmentSplitter else { return }
        splitter.splitSegments(cycleDependencies, &edgeSegments, criticalConflictThreshold)
    }

    /// Finds and breaks non-critical cycles by removing and reversing non-critical dependencies.
    package static func breakNonCriticalCycles(
        _ edgeSegments: [org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment]
    ) {
        let cycleDependencies =
            org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeCycleDetector.detectCycles(edgeSegments, false)

        for cycleDependency in cycleDependencies {
            if cycleDependency.getWeight() == 0 {
                cycleDependency.remove()
            } else {
                cycleDependency.reverse()
            }
        }
    }

    // MARK: - Topological Ordering

    /// Perform a topological numbering of the given hyperedge segments.
    private static func topologicalNumbering(
        _ segments: [org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment]
    ) {
        var sources = ArrayDeque<org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment>()
        var rightwardTargets = ArrayDeque<org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment>()

        for node in segments {
            node.setInWeight(node.getIncomingSegmentDependencies().count)
            node.setOutWeight(node.getOutgoingSegmentDependencies().count)

            if node.getInWeight() == 0 {
                sources.append(node)
            }

            if node.getOutWeight() == 0 && node.getIncomingConnectionCoordinates().isEmpty {
                rightwardTargets.append(node)
            }
        }

        var maxRank = -1

        // assign ranks using topological numbering
        while !sources.isEmpty {
            let node = sources.removeFirst()
            for dep in node.getOutgoingSegmentDependencies() {
                guard let target = dep.getTarget() else { continue }
                target.setRoutingSlot(max(target.getRoutingSlot(), node.getRoutingSlot() + 1))
                maxRank = max(maxRank, target.getRoutingSlot())

                target.setInWeight(target.getInWeight() - 1)
                if target.getInWeight() == 0 {
                    sources.append(target)
                }
            }
        }

        // Move hyperedge segments with horizontal segments only pointing rightwards as far right as possible
        if maxRank > -1 {
            for node in rightwardTargets {
                node.setRoutingSlot(maxRank)
            }

            while !rightwardTargets.isEmpty {
                let node = rightwardTargets.removeFirst()

                for dep in node.getIncomingSegmentDependencies() {
                    guard let source = dep.getSource() else { continue }
                    if !source.getIncomingConnectionCoordinates().isEmpty {
                        continue
                    }

                    source.setRoutingSlot(min(source.getRoutingSlot(), node.getRoutingSlot() - 1))

                    source.setOutWeight(source.getOutWeight() - 1)
                    if source.getOutWeight() == 0 {
                        rightwardTargets.append(source)
                    }
                }
            }
        }
    }
}
