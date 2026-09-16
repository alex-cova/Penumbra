// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/counting/HyperedgeCrossingsCounter.java
import Foundation

package class org_eclipse_elk_alg_layered_p3order_counting_HyperedgeCrossingsCounter {
    package let inLayerEdgeCount: [Int]
    package let hasNorthSouthPorts: [Bool]
    package var portPos: [Int]

    package init(
        _ inLayerEdgeCount: [Int],
        _ hasNorthSouthPorts: [Bool],
        _ portPos: [Int]
    ) {
        self.inLayerEdgeCount = inLayerEdgeCount
        self.hasNorthSouthPorts = hasNorthSouthPorts
        self.portPos = portPos
    }

    // MARK: - Inner types

    private final class Hyperedge: Comparable {
        var edges: [org_eclipse_elk_alg_layered_graph_LEdge] = []
        var ports: [org_eclipse_elk_alg_layered_graph_LPort] = []
        var upperLeft: Int = 0
        var lowerLeft: Int = 0
        var upperRight: Int = 0
        var lowerRight: Int = 0

        static func < (lhs: Hyperedge, rhs: Hyperedge) -> Bool {
            if lhs.upperLeft != rhs.upperLeft { return lhs.upperLeft < rhs.upperLeft }
            if lhs.upperRight != rhs.upperRight { return lhs.upperRight < rhs.upperRight }
            return ObjectIdentifier(lhs).hashValue < ObjectIdentifier(rhs).hashValue
        }

        static func == (lhs: Hyperedge, rhs: Hyperedge) -> Bool {
            lhs === rhs
        }
    }

    private enum CornerType {
        case UPPER
        case LOWER
    }

    private struct HyperedgeCorner {
        let hyperedge: Hyperedge
        let position: Int
        let oppositePosition: Int
        let type: CornerType
    }

    // MARK: - Count crossings

    package func countCrossings(
        _ leftLayer: [org_eclipse_elk_alg_layered_graph_LNode],
        _ rightLayer: [org_eclipse_elk_alg_layered_graph_LNode]
    ) -> Int {
        guard !leftLayer.isEmpty, !rightLayer.isEmpty else { return 0 }

        // Assign index values to the ports of the left layer
        var sourceCount = 0
        for node in leftLayer {
            // Assign index values in the order north - east - south - west
            for port in node.getPorts() {
                var portEdges = 0
                for edge in port.getOutgoingEdges() {
                    if node.getLayer() !== edge.getTarget()?.getNode()?.getLayer() {
                        portEdges += 1
                    }
                }
                if portEdges > 0 {
                    let pid = port.id
                    if pid >= 0, pid < portPos.count {
                        portPos[pid] = sourceCount
                    }
                    sourceCount += 1
                }
            }
        }

        // Assign index values to the ports of the right layer
        var targetCount = 0
        for node in rightLayer {
            // Determine how many input ports there are on the north side
            var northInputPorts = 0
            for port in node.getPorts() {
                if port.getSide() == .NORTH {
                    for edge in port.getIncomingEdges() {
                        if node.getLayer() !== edge.getSource()?.getNode()?.getLayer() {
                            northInputPorts += 1
                            break
                        }
                    }
                } else {
                    break
                }
            }
            // Assign index values in the order north - west - south - east
            var otherInputPorts = 0
            for port in node.getPorts().reversed() {
                var portEdges = 0
                for edge in port.getIncomingEdges() {
                    if node.getLayer() !== edge.getSource()?.getNode()?.getLayer() {
                        portEdges += 1
                    }
                }
                if portEdges > 0 {
                    let pid = port.id
                    if port.getSide() == .NORTH {
                        if pid >= 0, pid < portPos.count {
                            portPos[pid] = targetCount
                        }
                        targetCount += 1
                    } else {
                        if pid >= 0, pid < portPos.count {
                            portPos[pid] = targetCount + northInputPorts + otherInputPorts
                        }
                        otherInputPorts += 1
                    }
                }
            }
            targetCount += otherInputPorts
        }

        // Gather hyperedges
        var port2HyperedgeMap: [ObjectIdentifier: Hyperedge] = [:]
        var hyperedgeSet: [Hyperedge] = [] // maintains insertion order like LinkedHashSet

        for node in leftLayer {
            for sourcePort in node.getPorts() {
                for edge in sourcePort.getOutgoingEdges() {
                    guard let targetPort = edge.getTarget() else { continue }
                    guard node.getLayer() !== targetPort.getNode()?.getLayer() else { continue }

                    let sourceKey = ObjectIdentifier(sourcePort)
                    let targetKey = ObjectIdentifier(targetPort)
                    let sourceHE = port2HyperedgeMap[sourceKey]
                    let targetHE = port2HyperedgeMap[targetKey]

                    if sourceHE == nil && targetHE == nil {
                        let he = Hyperedge()
                        hyperedgeSet.append(he)
                        he.edges.append(edge)
                        he.ports.append(sourcePort)
                        port2HyperedgeMap[sourceKey] = he
                        he.ports.append(targetPort)
                        port2HyperedgeMap[targetKey] = he
                    } else if sourceHE == nil, let targetHE {
                        targetHE.edges.append(edge)
                        targetHE.ports.append(sourcePort)
                        port2HyperedgeMap[sourceKey] = targetHE
                    } else if targetHE == nil, let sourceHE {
                        sourceHE.edges.append(edge)
                        sourceHE.ports.append(targetPort)
                        port2HyperedgeMap[targetKey] = sourceHE
                    } else if let sourceHE, let targetHE, sourceHE === targetHE {
                        sourceHE.edges.append(edge)
                    } else if let sourceHE, let targetHE {
                        sourceHE.edges.append(edge)
                        for p in targetHE.ports {
                            port2HyperedgeMap[ObjectIdentifier(p)] = sourceHE
                        }
                        sourceHE.edges.append(contentsOf: targetHE.edges)
                        sourceHE.ports.append(contentsOf: targetHE.ports)
                        hyperedgeSet.removeAll { $0 === targetHE }
                    }
                }
            }
        }

        // Determine top and bottom positions for each hyperedge
        let leftLayerRef = leftLayer[0].getLayer()
        let rightLayerRef = rightLayer[0].getLayer()
        for he in hyperedgeSet {
            he.upperLeft = sourceCount
            he.upperRight = targetCount
            for port in he.ports {
                let pid = port.id
                guard pid >= 0, pid < portPos.count else { continue }
                let pos = portPos[pid]
                if port.getNode()?.getLayer() === leftLayerRef {
                    if pos < he.upperLeft { he.upperLeft = pos }
                    if pos > he.lowerLeft { he.lowerLeft = pos }
                } else if port.getNode()?.getLayer() === rightLayerRef {
                    if pos < he.upperRight { he.upperRight = pos }
                    if pos > he.lowerRight { he.lowerRight = pos }
                }
            }
        }

        // Determine the sequence of edge target positions sorted by source and target index
        let hyperedges = hyperedgeSet.sorted()
        var southSequence = [Int](repeating: 0, count: hyperedges.count)
        var compressDeltas = [Int](repeating: 0, count: targetCount + 1)
        for i in 0..<hyperedges.count {
            southSequence[i] = hyperedges[i].upperRight
            if southSequence[i] >= 0, southSequence[i] < compressDeltas.count {
                compressDeltas[southSequence[i]] = 1
            }
        }
        var delta = 0
        for i in 0..<compressDeltas.count {
            if compressDeltas[i] == 1 {
                compressDeltas[i] = delta
            } else {
                delta -= 1
            }
        }
        var q = 0
        for i in 0..<southSequence.count {
            let idx = southSequence[i]
            if idx >= 0, idx < compressDeltas.count {
                southSequence[i] += compressDeltas[idx]
            }
            q = max(q, southSequence[i] + 1)
        }

        // Build the accumulator tree
        var firstIndex = 1
        while firstIndex < q { firstIndex *= 2 }
        let treeSize = 2 * firstIndex - 1
        firstIndex -= 1
        var tree = [Int](repeating: 0, count: treeSize)

        // Count the straight-line crossings of the topmost edges
        var crossings = 0
        for k in 0..<southSequence.count {
            var index = southSequence[k] + firstIndex
            guard index >= 0, index < tree.count else { continue }
            tree[index] += 1
            while index > 0 {
                if index % 2 > 0 {
                    crossings += tree[index + 1]
                }
                index = (index - 1) / 2
                tree[index] += 1
            }
        }

        // Create corners for the left side
        var leftCorners: [HyperedgeCorner] = []
        leftCorners.reserveCapacity(hyperedges.count * 2)
        for he in hyperedges {
            leftCorners.append(HyperedgeCorner(hyperedge: he, position: he.upperLeft,
                                                oppositePosition: he.lowerLeft, type: .UPPER))
            leftCorners.append(HyperedgeCorner(hyperedge: he, position: he.lowerLeft,
                                                oppositePosition: he.upperLeft, type: .LOWER))
        }
        leftCorners.sort(by: compareCorners)

        // Count crossings caused by overlapping hyperedge areas on the left side
        var openHyperedges = 0
        for corner in leftCorners {
            switch corner.type {
            case .UPPER:
                openHyperedges += 1
            case .LOWER:
                openHyperedges -= 1
                crossings += openHyperedges
            }
        }

        // Create corners for the right side
        var rightCorners: [HyperedgeCorner] = []
        rightCorners.reserveCapacity(hyperedges.count * 2)
        for he in hyperedges {
            rightCorners.append(HyperedgeCorner(hyperedge: he, position: he.upperRight,
                                                 oppositePosition: he.lowerRight, type: .UPPER))
            rightCorners.append(HyperedgeCorner(hyperedge: he, position: he.lowerRight,
                                                 oppositePosition: he.upperRight, type: .LOWER))
        }
        rightCorners.sort(by: compareCorners)

        // Count crossings caused by overlapping hyperedge areas on the right side
        openHyperedges = 0
        for corner in rightCorners {
            switch corner.type {
            case .UPPER:
                openHyperedges += 1
            case .LOWER:
                openHyperedges -= 1
                crossings += openHyperedges
            }
        }

        return crossings
    }

    private func compareCorners(_ a: HyperedgeCorner, _ b: HyperedgeCorner) -> Bool {
        if a.position != b.position { return a.position < b.position }
        if a.oppositePosition != b.oppositePosition { return a.oppositePosition < b.oppositePosition }
        if a.hyperedge !== b.hyperedge {
            return ObjectIdentifier(a.hyperedge).hashValue < ObjectIdentifier(b.hyperedge).hashValue
        }
        if a.type == .UPPER && b.type == .LOWER { return true }
        if a.type == .LOWER && b.type == .UPPER { return false }
        return false
    }
}
