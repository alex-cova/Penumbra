// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p5edges/orthogonal/HyperEdgeSegment.java

import Foundation

// typealias HyperEdgeSegment is defined in TypeAliases.swift

package class org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment: Comparable, Hashable {

    // MARK: - Properties

    /// routing strategy which will ultimately decide how edges will be routed.
    package let routingStrategy: org_eclipse_elk_alg_layered_p5edges_orthogonal_direction_BaseRoutingDirectionStrategy

    /// ports represented by this hypernode.
    package var ports: [org_eclipse_elk_alg_layered_graph_LPort] = []

    /// mark value used for cycle breaking (to be accessed directly).
    package var mark: Int = 0

    /// the routing slot determines the horizontal distance to the preceding layer.
    package var routingSlot: Int = 0

    /// start position of this edge segment (in horizontal layouts, this is the topmost y coordinate).
    package var startPosition: Double = .nan
    /// end position of this edge segment (in horizontal layouts, this is the bottommost y coordinate).
    package var endPosition: Double = .nan

    /// sorted list of coordinates where incoming connections enter this segment.
    package var incomingConnectionCoordinates: [Double] = []
    /// sorted list of coordinates where outgoing connections leave this segment.
    package var outgoingConnectionCoordinates: [Double] = []

    /// list of outgoing dependencies to other edge segments.
    package var outgoingSegmentDeps: [org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency] = []
    /// combined weight of all outgoing dependencies.
    package var outDepWeight: Int = 0
    /// combined weight of critical outgoing dependencies.
    package var criticalOutDepWeight: Int = 0
    /// list of incoming dependencies from other edge segments.
    package var incomingSegmentDeps: [org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency] = []
    /// combined weight of all incoming dependencies.
    package var inDepWeight: Int = 0
    /// combined weight of critical incoming dependencies.
    package var criticalInDepWeight: Int = 0

    /// if this segment is the result of a split segment, this is the other segment; otherwise it is nil.
    package var splitPartner: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment?
    /// the segment that caused this segment to be split, if any (only set on one of the split partners).
    package var splitBy: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment?

    // MARK: - Initialization

    package init(_ routingStrategy: org_eclipse_elk_alg_layered_p5edges_orthogonal_direction_BaseRoutingDirectionStrategy) {
        self.routingStrategy = routingStrategy
    }

    /// Only used internally - should not be called externally.
    package init() {
        self.routingStrategy = org_eclipse_elk_alg_layered_p5edges_orthogonal_direction_BaseRoutingDirectionStrategy()
    }

    /// Adds the positions of the given port and all connected ports.
    package func addPortPositions(
        _ port: org_eclipse_elk_alg_layered_graph_LPort,
        _ hyperEdgeSegmentMap: inout [ObjectIdentifier: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment]
    ) {
        hyperEdgeSegmentMap[ObjectIdentifier(port)] = self
        ports.append(port)
        let portPos = routingStrategy.getPortPositionOnHyperNode(port)

        // add the new port position to the respective list
        if port.getSide() == routingStrategy.getSourcePortSide() {
            Self.insertSorted(&incomingConnectionCoordinates, portPos)
        } else {
            Self.insertSorted(&outgoingConnectionCoordinates, portPos)
        }

        // update start and end coordinates
        recomputeExtent()

        // add connected ports
        for otherPort in port.getConnectedPorts() {
            if hyperEdgeSegmentMap[ObjectIdentifier(otherPort)] == nil {
                addPortPositions(otherPort, &hyperEdgeSegmentMap)
            }
        }
    }

    package static func insertSorted(_ list: inout [Double], _ value: Double) {
        var insertIndex = list.count
        for i in 0..<list.count {
            let next = Float(list[i])
            if next == Float(value) {
                // an exactly equal value is already present in the list
                return
            } else if Double(next) > value {
                insertIndex = i
                break
            }
        }
        list.insert(value, at: insertIndex)
    }

    // MARK: - Getters and Setters

    /// Returns the ports incident to this segment.
    package func getPorts() -> [org_eclipse_elk_alg_layered_graph_LPort] {
        return ports
    }

    /// Returns this segment's routing slot.
    package func getRoutingSlot() -> Int {
        return routingSlot
    }

    /// Sets this segment's routing slot.
    package func setRoutingSlot(_ slot: Int) {
        self.routingSlot = slot
    }

    /// Returns the coordinate where this segment begins.
    package func getStartCoordinate() -> Double {
        return startPosition
    }

    /// Returns the coordinate where this segment ends.
    package func getEndCoordinate() -> Double {
        return endPosition
    }

    /// Returns the (sorted) list of coordinates where incoming connections enter this segment.
    package func getIncomingConnectionCoordinates() -> [Double] {
        return incomingConnectionCoordinates
    }

    /// Sets the incoming connection coordinates (used internally by split operations).
    package func setIncomingConnectionCoordinates(_ coords: [Double]) {
        incomingConnectionCoordinates = coords
    }

    /// Returns the (sorted) list of coordinates where outgoing connections leave this segment.
    package func getOutgoingConnectionCoordinates() -> [Double] {
        return outgoingConnectionCoordinates
    }

    /// Sets the outgoing connection coordinates (used internally by split operations).
    package func setOutgoingConnectionCoordinates(_ coords: [Double]) {
        outgoingConnectionCoordinates = coords
    }

    /// Return the outgoing dependencies to other hyper edge segments.
    package func getOutgoingSegmentDependencies() -> [org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency] {
        return outgoingSegmentDeps
    }

    package func appendOutgoingSegmentDependency(_ dep: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency) {
        outgoingSegmentDeps.append(dep)
    }

    package func removeOutgoingSegmentDependency(_ dep: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency) {
        outgoingSegmentDeps.removeAll(where: { $0 === dep })
    }

    /// Returns the combined weight of all outgoing dependencies.
    package func getOutWeight() -> Int {
        return outDepWeight
    }

    /// Sets the combined weight of all outgoing dependencies.
    package func setOutWeight(_ outWeight: Int) {
        self.outDepWeight = outWeight
    }

    /// Returns the combined weight of critical outgoing dependencies.
    package func getCriticalOutWeight() -> Int {
        return criticalOutDepWeight
    }

    /// Sets the combined weight of critical outgoing dependencies.
    package func setCriticalOutWeight(_ outWeight: Int) {
        self.criticalOutDepWeight = outWeight
    }

    /// Return the incoming dependencies from other hyper edge segments.
    package func getIncomingSegmentDependencies() -> [org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency] {
        return incomingSegmentDeps
    }

    package func appendIncomingSegmentDependency(_ dep: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency) {
        incomingSegmentDeps.append(dep)
    }

    package func removeIncomingSegmentDependency(_ dep: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegmentDependency) {
        incomingSegmentDeps.removeAll(where: { $0 === dep })
    }

    /// Returns the weight of incoming dependencies.
    package func getInWeight() -> Int {
        return inDepWeight
    }

    /// Sets the weight of incoming dependencies.
    package func setInWeight(_ inWeight: Int) {
        self.inDepWeight = inWeight
    }

    /// Returns the combined weight of critical incoming dependencies.
    package func getCriticalInWeight() -> Int {
        return criticalInDepWeight
    }

    /// Sets the combined weight of critical incoming dependencies.
    package func setCriticalInWeight(_ inWeight: Int) {
        self.criticalInDepWeight = inWeight
    }

    /// Returns the split partner.
    package func getSplitPartner() -> org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment? {
        return splitPartner
    }

    /// Sets the split partner.
    package func setSplitPartner(_ splitPartner: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment?) {
        self.splitPartner = splitPartner
    }

    /// Returns the segment that caused this one to be split, if any.
    package func getSplitBy() -> org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment? {
        return splitBy
    }

    /// Sets the segment that caused this one to be split, if any.
    package func setSplitBy(_ splitBy: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment?) {
        self.splitBy = splitBy
    }

    // MARK: - Utilities

    /// Returns the length of this segment (end - start).
    package func getLength() -> Double {
        return getEndCoordinate() - getStartCoordinate()
    }

    /// Checks whether this segment connects two or more ports.
    package func representsHyperedge() -> Bool {
        return getIncomingConnectionCoordinates().count + getOutgoingConnectionCoordinates().count > 2
    }

    /// Checks whether this segment was introduced while splitting another segment.
    package func isDummy() -> Bool {
        return splitPartner != nil && splitBy == nil
    }

    /// Recomputes the start and end coordinate based on incoming and outgoing connection coordinates.
    package func recomputeExtent() {
        startPosition = .nan
        endPosition = .nan

        recomputeExtentFromPositions(incomingConnectionCoordinates)
        recomputeExtentFromPositions(outgoingConnectionCoordinates)
    }

    package func recomputeExtentFromPositions(_ positions: [Double]) {
        // this code assumes that the positions are sorted ascendingly
        guard let first = positions.first, let last = positions.last else { return }
        // set new start position
        if startPosition.isNaN {
            startPosition = first
        } else {
            startPosition = min(startPosition, first)
        }

        // set new end position
        if endPosition.isNaN {
            endPosition = last
        } else {
            endPosition = max(endPosition, last)
        }
    }

    // MARK: - Splitting

    /// Simulates what would happen during a split.
    package func simulateSplit() -> (org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment, org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment) {
        let newSplit = org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment(routingStrategy)
        let newSplitPartner = org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment(routingStrategy)

        newSplit.incomingConnectionCoordinates.append(contentsOf: incomingConnectionCoordinates)
        newSplit.splitBy = splitBy
        newSplit.splitPartner = newSplitPartner
        newSplit.recomputeExtent()

        newSplitPartner.outgoingConnectionCoordinates.append(contentsOf: outgoingConnectionCoordinates)
        newSplitPartner.splitPartner = newSplit
        newSplitPartner.recomputeExtent()

        return (newSplit, newSplitPartner)
    }

    /// Splits this segment into two and returns the new segment.
    package func splitAt(_ splitPosition: Double) -> org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment {
        let partner = org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment(routingStrategy)
        splitPartner = partner
        partner.setSplitPartner(self)

        // Move all target positions over to the new segment
        partner.outgoingConnectionCoordinates.append(contentsOf: outgoingConnectionCoordinates)
        self.outgoingConnectionCoordinates.removeAll()

        // Link the two
        self.outgoingConnectionCoordinates.append(splitPosition)
        partner.incomingConnectionCoordinates.append(splitPosition)

        // Recompute their outer coordinates
        self.recomputeExtent()
        partner.recomputeExtent()

        // Clear dependencies so they can be regenerated later
        while !incomingSegmentDeps.isEmpty {
            incomingSegmentDeps[0].remove()
        }

        while !outgoingSegmentDeps.isEmpty {
            outgoingSegmentDeps[0].remove()
        }

        return partner
    }

    // MARK: - Comparable and Hashable

    package static func < (lhs: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment,
                          rhs: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment) -> Bool {
        return lhs.mark < rhs.mark
    }

    package static func == (lhs: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment,
                           rhs: org_eclipse_elk_alg_layered_p5edges_orthogonal_HyperEdgeSegment) -> Bool {
        return lhs.mark == rhs.mark
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(mark)
    }
}
