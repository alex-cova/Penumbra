import Foundation

package class org_eclipse_elk_alg_layered_intermediate_loops_routing_OrthogonalSelfLoopRouter: AbstractSelfLoopRouter {

    package enum EdgeRoutingDirection {
        case CLOCKWISE
        case COUNTER_CLOCKWISE
    }

    package override init() {
        super.init()
    }

    package override func routeSelfLoops(_ slHolder: SelfLoopHolder) {
        let lNode = slHolder.getLNode()
        let nodeSize = lNode.getSize()
        let nodeMargins = lNode.getMargin()

        let edgeEdgeDistance: Double = LGraphUtil.getIndividualOrInherited(lNode, property: LayeredOptions.SPACING_EDGE_EDGE)
        let edgeLabelDistance: Double = LGraphUtil.getIndividualOrInherited(lNode, property: LayeredOptions.SPACING_EDGE_LABEL)
        let nodeSLDistance: Double = LGraphUtil.getIndividualOrInherited(lNode, property: LayeredOptions.SPACING_NODE_SELF_LOOP)

        let newNodeMargins = LMargin()
        newNodeMargins.set(nodeMargins)

        let routingSlotPositions = computeRoutingSlotPositions(slHolder, edgeEdgeDistance, edgeLabelDistance, nodeSLDistance)

        for slLoop in slHolder.getSLHyperLoops() {
            for slEdge in slLoop.getSLEdges() {
                let lEdge = slEdge.getLEdge()
                let routingDirection = computeEdgeRoutingDirection(slEdge)

                var bendPoints = computeOrthogonalBendPoints(slEdge, routingDirection, routingSlotPositions)
                bendPoints = modifyBendPoints(slEdge, routingDirection, bendPoints)

                lEdge.getBendPoints().clear()
                for bp in bendPoints {
                    lEdge.getBendPoints().add(bp)
                    updateNewNodeMargins(nodeSize, newNodeMargins, bp)
                }
            }

            if let slLabels = slLoop.getSLLabels() {
                placeLabels(slLoop, slLabels, routingSlotPositions, edgeLabelDistance)
                updateNewNodeMarginsForLabels(nodeSize, newNodeMargins, slLabels)
            }
        }

        nodeMargins.set(newNodeMargins)
    }

    private func computeEdgeRoutingDirection(_ slEdge: SelfLoopEdge) -> EdgeRoutingDirection {
        let sourceLPort = slEdge.getSLSource().getLPort()
        let sourcePortSide = sourceLPort.getSide()
        let targetLPort = slEdge.getSLTarget().getLPort()
        let targetPortSide = targetLPort.getSide()

        if sourcePortSide == targetPortSide {
            return sourceLPort.id < targetLPort.id ? .CLOCKWISE : .COUNTER_CLOCKWISE
        } else if sourcePortSide.right() == targetPortSide {
            return .CLOCKWISE
        } else if sourcePortSide.left() == targetPortSide {
            return .COUNTER_CLOCKWISE
        } else {
            guard let slLoop = slEdge.getSLHyperLoop() else { return .CLOCKWISE }
            if slLoop.getOccupiedPortSides().contains(sourcePortSide.right()) {
                return .CLOCKWISE
            } else {
                return .COUNTER_CLOCKWISE
            }
        }
    }

    private func placeLabels(_ slLoop: SelfHyperLoop, _ slLabels: SelfHyperLoopLabels,
                              _ routingSlotPositions: [[Double]], _ edgeLabelDistance: Double) {
        let labelSide = slLabels.getSide()
        var labelPosition = routingSlotPositions[labelSide.ordinal][slLoop.getRoutingSlot(labelSide)]
        var inline = false
        for label in slLabels.getLLabels() {
            if let isInline: Bool = label.getProperty(LayeredOptions.EDGE_LABELS_INLINE) as? Bool, isInline {
                inline = true
                break
            }
        }
        var effectiveEdgeLabelDistance = edgeLabelDistance
        if inline { effectiveEdgeLabelDistance = 0 }

        switch labelSide {
        case .NORTH:
            labelPosition -= effectiveEdgeLabelDistance + slLabels.getSize().y
            slLabels.getPosition().y = labelPosition
        case .SOUTH:
            labelPosition += effectiveEdgeLabelDistance
            slLabels.getPosition().y = labelPosition
        case .WEST:
            labelPosition -= effectiveEdgeLabelDistance + slLabels.getSize().x
            slLabels.getPosition().x = labelPosition
        case .EAST:
            labelPosition += effectiveEdgeLabelDistance
            slLabels.getPosition().x = labelPosition
        default:
            break
        }
    }

    private func updateNewNodeMargins(_ nodeSize: KVector, _ newNodeMargins: LMargin, _ bendPoint: KVector) {
        newNodeMargins.left = max(newNodeMargins.left, -bendPoint.x)
        newNodeMargins.right = max(newNodeMargins.right, bendPoint.x - nodeSize.x)
        newNodeMargins.top = max(newNodeMargins.top, -bendPoint.y)
        newNodeMargins.bottom = max(newNodeMargins.bottom, bendPoint.y - nodeSize.y)
    }

    private func updateNewNodeMarginsForLabels(_ nodeSize: KVector, _ newNodeMargins: LMargin,
                                                 _ slLabels: SelfHyperLoopLabels) {
        let pos = slLabels.getPosition().clone()
        updateNewNodeMargins(nodeSize, newNodeMargins, pos)
        _ = pos.add(slLabels.getSize())
        updateNewNodeMargins(nodeSize, newNodeMargins, pos)
    }

    // MARK: - Routing Slot Positions

    private func computeRoutingSlotPositions(_ slHolder: SelfLoopHolder, _ edgeEdgeDistance: Double,
                                              _ edgeLabelDistance: Double, _ nodeSLDistance: Double) -> [[Double]] {
        let sideCount = 5 // PortSide enum count
        var positions = [[Double]](repeating: [], count: sideCount)
        for side in [PortSide.UNDEFINED, .NORTH, .EAST, .SOUTH, .WEST] {
            let slotCount = slHolder.getRoutingSlotCount()[side.ordinal]
            positions[side.ordinal] = [Double](repeating: 0, count: slotCount)
        }

        initializeWithMaxLabelHeight(&positions, slHolder, .NORTH)
        initializeWithMaxLabelHeight(&positions, slHolder, .SOUTH)

        computePositions(&positions, slHolder, .NORTH, edgeEdgeDistance, edgeLabelDistance, nodeSLDistance)
        computePositions(&positions, slHolder, .EAST, edgeEdgeDistance, edgeLabelDistance, nodeSLDistance)
        computePositions(&positions, slHolder, .SOUTH, edgeEdgeDistance, edgeLabelDistance, nodeSLDistance)
        computePositions(&positions, slHolder, .WEST, edgeEdgeDistance, edgeLabelDistance, nodeSLDistance)

        return positions
    }

    private func initializeWithMaxLabelHeight(_ positions: inout [[Double]], _ slHolder: SelfLoopHolder,
                                                _ portSide: PortSide) {
        for slLoop in slHolder.getSLHyperLoops() {
            if let slLabels = slLoop.getSLLabels(), slLabels.getSide() == portSide {
                let routingSlot = slLoop.getRoutingSlot(portSide)
                if routingSlot < positions[portSide.ordinal].count {
                    positions[portSide.ordinal][routingSlot] = max(
                        positions[portSide.ordinal][routingSlot], slLabels.getSize().y)
                }
            }
        }
    }

    private func computePositions(_ positions: inout [[Double]], _ slHolder: SelfLoopHolder,
                                    _ portSide: PortSide, _ edgeEdgeDistance: Double,
                                    _ edgeLabelDistance: Double, _ nodeSelfLoopDistance: Double) {
        var currPos = computeBaselinePosition(slHolder, portSide, nodeSelfLoopDistance)
        let factor: Double = (portSide == .NORTH || portSide == .WEST) ? -1 : 1

        for slot in 0..<positions[portSide.ordinal].count {
            var largestLabelSize = positions[portSide.ordinal][slot]
            if largestLabelSize > 0 {
                largestLabelSize += edgeLabelDistance
            }
            positions[portSide.ordinal][slot] = currPos
            currPos += factor * (largestLabelSize + edgeEdgeDistance)
        }
    }

    private func computeBaselinePosition(_ slHolder: SelfLoopHolder, _ portSide: PortSide,
                                           _ nodeSelfLoopDistance: Double) -> Double {
        let lNode = slHolder.getLNode()
        let lMargins = lNode.getMargin()

        switch portSide {
        case .NORTH: return -lMargins.top - nodeSelfLoopDistance
        case .EAST:  return lNode.getSize().x + lMargins.right + nodeSelfLoopDistance
        case .SOUTH: return lNode.getSize().y + lMargins.bottom + nodeSelfLoopDistance
        case .WEST:  return -lMargins.left - nodeSelfLoopDistance
        default:     return -1
        }
    }

    // MARK: - Bend Point Computation

    func computeOrthogonalBendPoints(_ slEdge: SelfLoopEdge, _ routingDirection: EdgeRoutingDirection,
                                      _ routingSlotPositions: [[Double]]) -> KVectorChain {
        let bendPoints = KVectorChain()
        addOuterBendPoint(slEdge, slEdge.getSLSource(), routingSlotPositions, bendPoints)
        addCornerBendPoints(slEdge, routingDirection, routingSlotPositions, bendPoints)
        addOuterBendPoint(slEdge, slEdge.getSLTarget(), routingSlotPositions, bendPoints)
        return bendPoints
    }

    func modifyBendPoints(_ slEdge: SelfLoopEdge, _ routingDirection: EdgeRoutingDirection,
                           _ bendPoints: KVectorChain) -> KVectorChain {
        return bendPoints
    }

    private func addOuterBendPoint(_ slEdge: SelfLoopEdge, _ slPort: SelfLoopPort,
                                     _ routingSlotPositions: [[Double]], _ bendPoints: KVectorChain) {
        guard let slLoop = slEdge.getSLHyperLoop() else { return }
        let lPort = slPort.getLPort()
        let portSide = lPort.getSide()

        let result = getBaseVector(portSide, slLoop.getRoutingSlot(portSide), routingSlotPositions)

        let anchor = lPort.getPosition().clone().add(lPort.getAnchor())
        switch lPort.getSide() {
        case .NORTH, .SOUTH:
            result.x += anchor.x
        case .EAST, .WEST:
            result.y += anchor.y
        default:
            break
        }

        bendPoints.add(result)
    }

    private func addCornerBendPoints(_ slEdge: SelfLoopEdge, _ routingDirection: EdgeRoutingDirection,
                                       _ routingSlotPositions: [[Double]], _ bendPoints: KVectorChain) {
        let lSourcePort = slEdge.getSLSource().getLPort()
        let lTargetPort = slEdge.getSLTarget().getLPort()

        if lSourcePort.getSide() == lTargetPort.getSide() { return }

        guard let slLoop = slEdge.getSLHyperLoop() else { return }
        var labelSide: PortSide?
        var lSize: KVector?
        let inline = slEdge.isInline()
        if inline, let labels = slLoop.getSLLabels() {
            labelSide = slEdge.getLabelSide()
            lSize = labels.getSize()
        }

        var currPortSide = lSourcePort.getSide()

        while currPortSide != lTargetPort.getSide() {
            let nextPortSide = routingDirection == .CLOCKWISE
                ? currPortSide.right()
                : currPortSide.left()

            let currPortSideComponent = getBaseVector(
                currPortSide, slLoop.getRoutingSlot(currPortSide), routingSlotPositions)
            let nextPortSideComponent = getBaseVector(
                nextPortSide, slLoop.getRoutingSlot(nextPortSide), routingSlotPositions)

            if inline, let ls = labelSide, let sz = lSize {
                if currPortSide == ls {
                    adjustVectorForLabelSide(currPortSideComponent, ls, sz)
                } else if nextPortSide == ls {
                    adjustVectorForLabelSide(nextPortSideComponent, ls, sz)
                }
            }

            bendPoints.add(currPortSideComponent.add(nextPortSideComponent))
            currPortSide = nextPortSide
        }
    }

    private func getBaseVector(_ portSide: PortSide, _ routingSlot: Int,
                                 _ routingSlotPositions: [[Double]]) -> KVector {
        let position = routingSlotPositions[portSide.ordinal][routingSlot]

        switch portSide {
        case .NORTH, .SOUTH:
            return KVector(0, position)
        case .EAST, .WEST:
            return KVector(position, 0)
        default:
            return KVector()
        }
    }

    private func adjustVectorForLabelSide(_ portSideComponent: KVector, _ labelSide: PortSide, _ labelSize: KVector) {
        switch labelSide {
        case .NORTH:
            portSideComponent.y -= labelSize.y / 2
        case .SOUTH:
            portSideComponent.y += labelSize.y / 2
        case .WEST:
            portSideComponent.x -= labelSize.x / 2
        case .EAST:
            portSideComponent.x += labelSize.x / 2
        default:
            break
        }
    }
}
