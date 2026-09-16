import Foundation

package final class org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout {
    package var root: [org_eclipse_elk_alg_layered_graph_LNode?]
    package var blockSize: [Double]
    package var align: [org_eclipse_elk_alg_layered_graph_LNode?]
    package var innerShift: [Double]
    package var sink: [org_eclipse_elk_alg_layered_graph_LNode?]
    package var shift: [Double]
    package var y: [Double]
    package var vdir: VDirection
    package var hdir: HDirection
    package var su: [Bool]
    package var od: [Bool]

    package var layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph
    package var spacings: org_eclipse_elk_alg_layered_options_Spacings

    package init(
        _ layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ nodeCount: Int,
        _ vdir: VDirection,
        _ hdir: HDirection
    ) {
        self.layeredGraph = layeredGraph
        self.spacings =
            layeredGraph.getProperty(org_eclipse_elk_alg_layered_options_InternalProperties.SPACINGS)
            ?? org_eclipse_elk_alg_layered_options_Spacings()

        root = Array(repeating: nil, count: nodeCount)
        blockSize = Array(repeating: 0.0, count: nodeCount)
        align = Array(repeating: nil, count: nodeCount)
        innerShift = Array(repeating: 0.0, count: nodeCount)
        sink = Array(repeating: nil, count: nodeCount)
        shift = Array(repeating: 0.0, count: nodeCount)
        y = Array(repeating: 0.0, count: nodeCount)
        su = Array(repeating: false, count: nodeCount)
        od = Array(repeating: true, count: nodeCount)
        self.vdir = vdir
        self.hdir = hdir
    }

    package convenience init() {
        self.init(
            org_eclipse_elk_alg_layered_graph_LGraph(),
            0,
            .DOWN,
            .RIGHT
        )
    }

    package func cleanup() {
        root.removeAll(keepingCapacity: false)
        blockSize.removeAll(keepingCapacity: false)
        align.removeAll(keepingCapacity: false)
        innerShift.removeAll(keepingCapacity: false)
        sink.removeAll(keepingCapacity: false)
        shift.removeAll(keepingCapacity: false)
        y.removeAll(keepingCapacity: false)
        su.removeAll(keepingCapacity: false)
        od.removeAll(keepingCapacity: false)
    }

    package func layoutSize() -> Double {
        var minVal = Double.infinity
        var maxVal = -Double.infinity

        for layer in layeredGraph.getLayers() {
            for n in layer.getNodes() {
                let yMin = y[n.id]
                let rootId = root[n.id]?.id ?? n.id
                let yMax = yMin + blockSize[rootId]
                minVal = Swift.min(minVal, yMin)
                maxVal = Swift.max(maxVal, yMax)
            }
        }
        return maxVal - minVal
    }

    package func calculateDelta(
        _ src: org_eclipse_elk_alg_layered_graph_LPort,
        _ tgt: org_eclipse_elk_alg_layered_graph_LPort
    ) -> Double {
        guard let srcNode = src.getNode(), let tgtNode = tgt.getNode() else {
            return 0.0
        }

        let srcPos = y[srcNode.id]
            + innerShift[srcNode.id]
            + src.getPosition().y
            + src.getAnchor().y
        let tgtPos = y[tgtNode.id]
            + innerShift[tgtNode.id]
            + tgt.getPosition().y
            + tgt.getAnchor().y
        return tgtPos - srcPos
    }

    package func shiftBlock(_ rootNode: org_eclipse_elk_alg_layered_graph_LNode, _ delta: Double) {
        var current: org_eclipse_elk_alg_layered_graph_LNode? = rootNode
        repeat {
            guard let currentNode = current else { break }
            y[currentNode.id] += delta
            current = align[currentNode.id]
        } while current !== rootNode
    }

    package func checkSpaceAbove(
        _ blockRoot: org_eclipse_elk_alg_layered_graph_LNode,
        _ delta: Double,
        _ ni: org_eclipse_elk_alg_layered_p4nodes_bk_NeighborhoodInformation
    ) -> Double {
        var availableSpace = delta
        let rootNode = blockRoot
        var current: org_eclipse_elk_alg_layered_graph_LNode? = rootNode

        repeat {
            guard let c = current, let next = align[c.id] else { break }
            current = next
            let minYCurrent = getMinY(next)

            if let neighbor = getUpperNeighbor(next, ni) {
                let maxYNeighbor = getMaxY(neighbor)
                availableSpace = Swift.min(
                    availableSpace,
                    minYCurrent - (maxYNeighbor + spacings.getVerticalSpacing(next, neighbor))
                )
            }
        } while current !== rootNode

        return availableSpace
    }

    package func checkSpaceBelow(
        _ blockRoot: org_eclipse_elk_alg_layered_graph_LNode,
        _ delta: Double,
        _ ni: org_eclipse_elk_alg_layered_p4nodes_bk_NeighborhoodInformation
    ) -> Double {
        var availableSpace = delta
        let rootNode = blockRoot
        var current: org_eclipse_elk_alg_layered_graph_LNode? = rootNode

        repeat {
            guard let c = current, let next = align[c.id] else { break }
            current = next
            let maxYCurrent = getMaxY(next)

            if let neighbor = getLowerNeighbor(next, ni) {
                let minYNeighbor = getMinY(neighbor)
                availableSpace = Swift.min(
                    availableSpace,
                    minYNeighbor - (maxYCurrent + spacings.getVerticalSpacing(next, neighbor))
                )
            }
        } while current !== rootNode

        return availableSpace
    }

    package func getMinY(_ n: org_eclipse_elk_alg_layered_graph_LNode) -> Double {
        let rootNode = root[n.id] ?? n
        return y[rootNode.id]
            + innerShift[n.id]
            - n.getMargin().top
    }

    package func getMaxY(_ n: org_eclipse_elk_alg_layered_graph_LNode) -> Double {
        let rootNode = root[n.id] ?? n
        return y[rootNode.id]
            + innerShift[n.id]
            + n.getSize().y
            + n.getMargin().bottom
    }

    package func getLowerNeighbor(
        _ n: org_eclipse_elk_alg_layered_graph_LNode,
        _ ni: org_eclipse_elk_alg_layered_p4nodes_bk_NeighborhoodInformation
    ) -> org_eclipse_elk_alg_layered_graph_LNode? {
        guard let layer = n.getLayer() else { return nil }
        let layerPos = ni.nodeIndex[n.id]
        if layerPos < layer.getNodes().count - 1 {
            return layer.getNodes()[layerPos + 1]
        }
        return nil
    }

    package func getUpperNeighbor(
        _ n: org_eclipse_elk_alg_layered_graph_LNode,
        _ ni: org_eclipse_elk_alg_layered_p4nodes_bk_NeighborhoodInformation
    ) -> org_eclipse_elk_alg_layered_graph_LNode? {
        guard let layer = n.getLayer() else { return nil }
        let layerPos = ni.nodeIndex[n.id]
        if layerPos > 0 {
            return layer.getNodes()[layerPos - 1]
        }
        return nil
    }

    package func toString() -> String {
        var result = ""
        if hdir == .RIGHT {
            result += "RIGHT"
        } else {
            result += "LEFT"
        }
        if vdir == .DOWN {
            result += "DOWN"
        } else {
            result += "UP"
        }
        return result
    }

    package enum VDirection {
        case DOWN
        case UP
    }

    package enum HDirection {
        case RIGHT
        case LEFT
    }
}
