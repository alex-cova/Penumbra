import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_PortListSorter {
    package typealias Comparator = (LPort, LPort) -> Int

    package static let CMP_PORT_SIDE: Comparator = { p1, p2 in
        p1.side.ordinal - p2.side.ordinal
    }

    package static let CMP_PORT_DEGREE_EAST_WEST: Comparator = { p1, p2 in
        let ordinalDifference = p1.side.ordinal - p2.side.ordinal
        if ordinalDifference != 0 {
            return 0
        }

        switch p1.side {
        case .EAST:
            return realDegree(p2, { $0.outgoingEdges }) - realDegree(p1, { $0.outgoingEdges })
        case .WEST:
            return realDegree(p1, { $0.incomingEdges }) - realDegree(p2, { $0.incomingEdges })
        default:
            return 0
        }
    }

    package static let CMP_FIXED_ORDER_AND_FIXED_POS: Comparator = { p1, p2 in
        let portConstraints = p1.node?.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .UNDEFINED

        let ordinalDifference = p1.side.ordinal - p2.side.ordinal
        if ordinalDifference != 0 || !portConstraints.isOrderFixed() {
            return 0
        }

        if portConstraints == .FIXED_ORDER {
            let index1 = p1.getProperty(LayeredOptions.PORT_INDEX) as? Int
            let index2 = p2.getProperty(LayeredOptions.PORT_INDEX) as? Int
            if let i1 = index1, let i2 = index2 {
                let indexDifference = i1 - i2
                if indexDifference != 0 {
                    return indexDifference
                }
            }
        }

        switch p1.side {
        case .NORTH:
            return compareDouble(p1.position.x, p2.position.x)
        case .EAST:
            return compareDouble(p1.position.y, p2.position.y)
        case .SOUTH:
            return compareDouble(p2.position.x, p1.position.x)
        case .WEST:
            return compareDouble(p2.position.y, p1.position.y)
        default:
            return 0
        }
    }

    package static let CMP_COMBINED: Comparator = { p1, p2 in
        let sideCompare = CMP_PORT_SIDE(p1, p2)
        if sideCompare != 0 {
            return sideCompare
        }
        return CMP_FIXED_ORDER_AND_FIXED_POS(p1, p2)
    }

    package init() {}

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("Port order processing", 1)

        let pss = layeredGraph.getProperty(LayeredOptions.PORT_SORTING_STRATEGY) as? PortSortingStrategy

        for layer in layeredGraph.layers {
            for node in layer.nodes {
                let portConstraints = node.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .UNDEFINED

                if portConstraints.isOrderFixed() {
                    node.ports.sort { a, b in
                        org_eclipse_elk_alg_layered_intermediate_PortListSorter.CMP_COMBINED(a, b) < 0
                    }
                } else if portConstraints.isSideFixed() {
                    node.ports.sort { a, b in
                        org_eclipse_elk_alg_layered_intermediate_PortListSorter.CMP_PORT_SIDE(a, b) < 0
                    }

                    reverseWestAndSouthSide(&node.ports)

                    if pss == .PORT_DEGREE {
                        node.ports.sort { a, b in
                            org_eclipse_elk_alg_layered_intermediate_PortListSorter.CMP_PORT_DEGREE_EAST_WEST(a, b) < 0
                        }
                    }
                }
                node.cachePortSides()
            }
        }

        monitor.done()
    }

    private func reverseWestAndSouthSide(_ ports: inout [LPort]) {
        if ports.count <= 1 {
            return
        }

        let southIndices = findPortSideRange(ports, .SOUTH)
        reverseRange(&ports, southIndices.0, southIndices.1)

        let westIndices = findPortSideRange(ports, .WEST)
        reverseRange(&ports, westIndices.0, westIndices.1)
    }

    private func findPortSideRange(_ ports: [LPort], _ side: PortSide) -> (Int, Int) {
        if ports.isEmpty {
            return (0, 0)
        }

        var currentSide = ports[0].side
        var lowIdx = 0
        let lb = side.ordinal
        let hb = side.ordinal + 1

        while lowIdx < ports.count - 1 && currentSide.ordinal < lb {
            lowIdx += 1
            currentSide = ports[lowIdx].side
        }
        var highIdx = lowIdx
        while highIdx < ports.count - 1 && currentSide.ordinal < hb {
            highIdx += 1
            currentSide = ports[highIdx].side
        }

        return (lowIdx, highIdx)
    }

    private func reverseRange(_ ports: inout [LPort], _ lowIdx: Int, _ highIdx: Int) {
        if highIdx <= lowIdx + 2 {
            return
        }
        let n = (highIdx - lowIdx) / 2

        for i in 0..<n {
            let tmp = ports[lowIdx + i]
            ports[lowIdx + i] = ports[highIdx - i - 1]
            ports[highIdx - i - 1] = tmp
        }
    }

    private static func realDegree(_ p: LPort, _ edgesFun: (LPort) -> [LEdge]) -> Int {
        var count = 0
        for e in edgesFun(p) {
            if !(e.getProperty(InternalProperties.REVERSED) as? Bool ?? false) {
                count += 1
            }
        }
        return count
    }

    package static func compareDouble(_ lhs: Double, _ rhs: Double) -> Int {
        if lhs < rhs { return -1 }
        if lhs > rhs { return 1 }
        return 0
    }
}
