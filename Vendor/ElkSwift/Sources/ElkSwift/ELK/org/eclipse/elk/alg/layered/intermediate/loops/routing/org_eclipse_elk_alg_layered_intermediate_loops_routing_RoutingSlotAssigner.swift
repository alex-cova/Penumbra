import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_loops_routing_RoutingSlotAssigner {

    private var hyperEdgeSegments: [HyperEdgeSegment] = []
    private var slLoopToSegmentMap: [ObjectIdentifier: HyperEdgeSegment] = [:]
    private var slLoopActivityOverPorts: [ObjectIdentifier: [Bool]] = [:]

    package init() {}

    package func assignRoutingSlots(_ slHolder: SelfLoopHolder) {
        let labelCrossingMatrix = computeLabelCrossingMatrix(slHolder)
        createCrossingGraph(slHolder, labelCrossingMatrix)

        // Swift version takes 1 parameter (no random)
        OrthogonalRoutingGenerator.breakNonCriticalCycles(hyperEdgeSegments)

        doAssignRoutingSlots(slHolder, labelCrossingMatrix)

        hyperEdgeSegments = []
        slLoopToSegmentMap = [:]
        slLoopActivityOverPorts = [:]
    }

    // MARK: - Label Crossing Matrix

    private func computeLabelCrossingMatrix(_ slHolder: SelfLoopHolder) -> [[Bool]] {
        var labelID = 0
        for slLoop in slHolder.getSLHyperLoops() {
            if let slLabels = slLoop.getSLLabels() {
                slLabels.id = labelID
                labelID += 1
            }
        }

        var crossingMatrix = [[Bool]](repeating: [Bool](repeating: false, count: labelID), count: labelID)

        let slLoops = slHolder.getSLHyperLoops()
        for sl1Idx in 0..<slLoops.count {
            let slLoop1 = slLoops[sl1Idx]
            guard let slLabels1 = slLoop1.getSLLabels() else { continue }

            for sl2Idx in (sl1Idx + 1)..<slLoops.count {
                let slLoop2 = slLoops[sl2Idx]
                guard let slLabels2 = slLoop2.getSLLabels() else { continue }

                let overlap = labelsOverlap(slLoop1, slLoop2)
                crossingMatrix[slLabels1.id][slLabels2.id] = overlap
                crossingMatrix[slLabels2.id][slLabels1.id] = overlap
            }
        }

        return crossingMatrix
    }

    private func labelsOverlap(_ slLoop1: SelfHyperLoop, _ slLoop2: SelfHyperLoop) -> Bool {
        guard let slLabels1 = slLoop1.getSLLabels(), let slLabels2 = slLoop2.getSLLabels() else { return false }

        if slLabels1.getSide() != slLabels2.getSide()
            || slLabels1.getSide() == .EAST || slLabels1.getSide() == .WEST {
            return false
        }

        let start1 = slLabels1.getPosition().x
        let end1 = start1 + slLabels1.getSize().x
        let start2 = slLabels2.getPosition().x
        let end2 = start2 + slLabels2.getSize().x

        return start1 <= end2 && end1 >= start2
    }

    // MARK: - Crossing Graph

    private func createCrossingGraph(_ slHolder: SelfLoopHolder, _ labelCrossingMatrix: [[Bool]]) {
        let slLoops = slHolder.getSLHyperLoops()

        hyperEdgeSegments = []
        slLoopToSegmentMap = [:]

        for slLoop in slLoops {
            let segment = HyperEdgeSegment()
            hyperEdgeSegments.append(segment)
            slLoopToSegmentMap[ObjectIdentifier(slLoop)] = segment
        }

        slLoopActivityOverPorts = [:]
        computeLoopActivity(slHolder)

        for firstIdx in 0..<(slLoops.count - 1) {
            let slLoop1 = slLoops[firstIdx]
            for secondIdx in (firstIdx + 1)..<slLoops.count {
                createDependencies(slLoop1, slLoops[secondIdx], labelCrossingMatrix)
            }
        }
    }

    private func computeLoopActivity(_ slHolder: SelfLoopHolder) {
        let slLoops = slHolder.getSLHyperLoops()
        let lPorts = slHolder.getLNode().getPorts()

        for slLoop in slLoops {
            var loopActivity = [Bool](repeating: false, count: lPorts.count)

            guard let leftmost = slLoop.getLeftmostPort(), let rightmost = slLoop.getRightmostPort() else { continue }
            var lPortIdx = leftmost.getLPort().id - 1
            let lPortTargetIdx = rightmost.getLPort().id

            while lPortIdx != lPortTargetIdx {
                lPortIdx = (lPortIdx + 1) % lPorts.count
                loopActivity[lPortIdx] = true
            }

            slLoopActivityOverPorts[ObjectIdentifier(slLoop)] = loopActivity
        }
    }

    private func createDependencies(_ slLoop1: SelfHyperLoop, _ slLoop2: SelfHyperLoop,
                                     _ labelCrossingMatrix: [[Bool]]) {
        let firstAboveSecondCrossings = countCrossings(slLoop1, slLoop2)
        let secondAboveFirstCrossings = countCrossings(slLoop2, slLoop1)

        guard let segment1 = slLoopToSegmentMap[ObjectIdentifier(slLoop1)],
              let segment2 = slLoopToSegmentMap[ObjectIdentifier(slLoop2)] else { return }

        if firstAboveSecondCrossings < secondAboveFirstCrossings {
            _ = HyperEdgeSegmentDependency.createAndAddRegular(
                segment1, segment2, secondAboveFirstCrossings - firstAboveSecondCrossings)
        } else if secondAboveFirstCrossings < firstAboveSecondCrossings {
            _ = HyperEdgeSegmentDependency.createAndAddRegular(
                segment2, segment1, firstAboveSecondCrossings - secondAboveFirstCrossings)
        } else if firstAboveSecondCrossings != 0
                    || labelsOverlapMatrix(slLoop1, slLoop2, labelCrossingMatrix) {
            _ = HyperEdgeSegmentDependency.createAndAddRegular(segment1, segment2, 0)
            _ = HyperEdgeSegmentDependency.createAndAddRegular(segment2, segment1, 0)
        }
    }

    private func countCrossings(_ slUpperLoop: SelfHyperLoop, _ slLowerLoop: SelfHyperLoop) -> Int {
        guard let lowerLoopActivity = slLoopActivityOverPorts[ObjectIdentifier(slLowerLoop)] else { return 0 }
        var crossings = 0

        for slPort in slUpperLoop.getSLPorts() {
            if lowerLoopActivity[slPort.getLPort().id] {
                crossings += 1
            }
        }

        return crossings
    }

    private func labelsOverlapMatrix(_ slLoop1: SelfHyperLoop, _ slLoop2: SelfHyperLoop,
                                      _ labelCrossingMatrix: [[Bool]]) -> Bool {
        guard let l1 = slLoop1.getSLLabels(), let l2 = slLoop2.getSLLabels() else { return false }
        return labelCrossingMatrix[l1.id][l2.id]
    }

    // MARK: - Slot Assignment

    private func doAssignRoutingSlots(_ slHolder: SelfLoopHolder, _ labelCrossingMatrix: [[Bool]]) {
        assignRawRoutingSlotsToSegments()
        assignRawRoutingSlotsToLoops(slHolder)
        shiftTowardsNode(slHolder, labelCrossingMatrix)
    }

    private func assignRawRoutingSlotsToSegments() {
        var sinks = ArrayDeque<HyperEdgeSegment>()

        for segment in hyperEdgeSegments {
            segment.setInWeight(segment.getIncomingSegmentDependencies().count)
            segment.setOutWeight(segment.getOutgoingSegmentDependencies().count)

            if segment.getOutWeight() == 0 {
                segment.setRoutingSlot(0)
                sinks.append(segment)
            }
        }

        while !sinks.isEmpty {
            let segment = sinks.removeFirst()
            let nextRoutingSlot = segment.getRoutingSlot() + 1

            for inDependency in segment.getIncomingSegmentDependencies() {
                guard let sourceSegment = inDependency.getSource() else { continue }
                sourceSegment.setRoutingSlot(max(sourceSegment.getRoutingSlot(), nextRoutingSlot))

                sourceSegment.setOutWeight(sourceSegment.getOutWeight() - 1)
                if sourceSegment.getOutWeight() == 0 {
                    sinks.append(sourceSegment)
                }
            }
        }
    }

    private func assignRawRoutingSlotsToLoops(_ slHolder: SelfLoopHolder) {
        for slLoop in slHolder.getSLHyperLoops() {
            guard let segment = slLoopToSegmentMap[ObjectIdentifier(slLoop)] else { continue }
            let slot = segment.getRoutingSlot()
            for portSide in slLoop.getOccupiedPortSides() {
                slLoop.setRoutingSlot(portSide, slot)
            }
        }
    }

    private func shiftTowardsNode(_ slHolder: SelfLoopHolder, _ labelCrossingMatrix: [[Bool]]) {
        var nextFreeRoutingSlotAtPort = [Int](repeating: 0, count: slHolder.getLNode().getPorts().count)

        shiftTowardsNodeOnSide(slHolder, .NORTH, &nextFreeRoutingSlotAtPort, labelCrossingMatrix)
        shiftTowardsNodeOnSide(slHolder, .EAST, &nextFreeRoutingSlotAtPort, labelCrossingMatrix)
        shiftTowardsNodeOnSide(slHolder, .SOUTH, &nextFreeRoutingSlotAtPort, labelCrossingMatrix)
        shiftTowardsNodeOnSide(slHolder, .WEST, &nextFreeRoutingSlotAtPort, labelCrossingMatrix)
    }

    private func shiftTowardsNodeOnSide(_ slHolder: SelfLoopHolder, _ side: PortSide,
                                          _ nextFreeRoutingSlotAtPort: inout [Int],
                                          _ labelCrossingMatrix: [[Bool]]) {
        let slLoops = slHolder.getSLHyperLoops()
            .filter { $0.getOccupiedPortSides().contains(side) }
            .sorted { $0.getRoutingSlot(side) < $1.getRoutingSlot(side) }

        var minLPortIndex = Int.max
        var maxLPortIndex = Int.min
        for lPort in slHolder.getLNode().getPorts() {
            if lPort.getSide() == side {
                minLPortIndex = min(minLPortIndex, lPort.id)
                maxLPortIndex = max(maxLPortIndex, lPort.id)
            }
        }

        if minLPortIndex == Int.max {
            for (i, loop) in slLoops.enumerated() {
                loop.setRoutingSlot(side, i)
            }
        } else {
            var slotAssignedToLabel = [Int](repeating: -1, count: labelCrossingMatrix.count)

            for slLoop in slLoops {
                guard let activeAtPort = slLoopActivityOverPorts[ObjectIdentifier(slLoop)] else { continue }
                var lowestAvailableSlot = 0

                for portIndex in minLPortIndex...maxLPortIndex {
                    if activeAtPort[portIndex] {
                        lowestAvailableSlot = max(lowestAvailableSlot, nextFreeRoutingSlotAtPort[portIndex])
                    }
                }

                if let ourLabels = slLoop.getSLLabels() {
                    let ourLabelIdx = ourLabels.id
                    var slotsWithLabelConflicts = Set<Int>()

                    for otherLabelIdx in 0..<labelCrossingMatrix.count {
                        if labelCrossingMatrix[ourLabelIdx][otherLabelIdx] {
                            slotsWithLabelConflicts.insert(slotAssignedToLabel[otherLabelIdx])
                        }
                    }

                    while slotsWithLabelConflicts.contains(lowestAvailableSlot) {
                        lowestAvailableSlot += 1
                    }
                }

                slLoop.setRoutingSlot(side, lowestAvailableSlot)
                for portIndex in minLPortIndex...maxLPortIndex {
                    if activeAtPort[portIndex] {
                        nextFreeRoutingSlotAtPort[portIndex] = lowestAvailableSlot + 1
                    }
                }

                if let endLabels = slLoop.getSLLabels() {
                    slotAssignedToLabel[endLabels.id] = lowestAvailableSlot
                }
            }
        }
    }
}
