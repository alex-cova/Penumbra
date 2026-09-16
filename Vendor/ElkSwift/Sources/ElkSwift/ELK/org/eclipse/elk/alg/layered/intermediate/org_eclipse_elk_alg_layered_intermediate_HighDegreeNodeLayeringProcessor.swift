import Foundation

package class org_eclipse_elk_alg_layered_intermediate_HighDegreeNodeLayeringProcessor {

    private var degreeThreshold: Int = 0
    private var treeHeightThreshold: Int = 0

    package init() {}

    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {
        degreeThreshold = graph.getProperty(LayeredOptions.HIGH_DEGREE_NODES_THRESHOLD) as? Int ?? 16
        treeHeightThreshold = graph.getProperty(LayeredOptions.HIGH_DEGREE_NODES_TREE_HEIGHT) as? Int ?? 0
        if treeHeightThreshold == 0 {
            treeHeightThreshold = Int.max
        }

        // Iterate through all layers using index-based iteration since we insert layers
        var layerIndex = 0
        while layerIndex < graph.layers.count {
            let lay = graph.layers[layerIndex]

            // #1 find high degree nodes and their incoming/outgoing trees
            var highDegreeNodes = [(LNode, HighDegreeNodeInformation)]()
            var incMax = -1
            var outMax = -1
            for n in lay.nodes {
                if isHighDegreeNode(n) {
                    let hdni = calculateInformation(n)
                    incMax = max(incMax, hdni.incTreesMaxHeight)
                    outMax = max(outMax, hdni.outTreesMaxHeight)
                    highDegreeNodes.append((n, hdni))
                }
            }

            // #2 insert layers before the current layer and move the trees
            var preLayers = [Layer]()
            for _ in 0..<max(0, incMax) {
                let l = Layer(graph)
                graph.layers.insert(l, at: layerIndex)
                preLayers.insert(l, at: 0)
                layerIndex += 1 // current layer shifted right
            }
            for (_, hdni) in highDegreeNodes {
                guard let incRoots = hdni.incTreeRoots else { continue }
                for incRoot in incRoots {
                    moveTree(incRoot, edgesFun: incomingEdges, layers: preLayers)
                }
            }

            // #3 insert layers after the current layer and move the trees
            var afterLayers = [Layer]()
            for _ in 0..<max(0, outMax) {
                let l = Layer(graph)
                let insertIndex = layerIndex + 1 + afterLayers.count
                graph.layers.insert(l, at: insertIndex)
                afterLayers.append(l)
            }
            for (_, hdni) in highDegreeNodes {
                guard let outRoots = hdni.outTreeRoots else { continue }
                for outRoot in outRoots {
                    moveTree(outRoot, edgesFun: outgoingEdges, layers: afterLayers)
                }
            }

            layerIndex += 1 + afterLayers.count
        }

        // Remove empty layers
        graph.layers.removeAll { $0.nodes.isEmpty }
    }

    private func incomingEdges(_ node: LNode) -> [LEdge] {
        return node.getIncomingEdges()
    }

    private func outgoingEdges(_ node: LNode) -> [LEdge] {
        return node.getOutgoingEdges()
    }

    private func connectedEdges(_ node: LNode) -> [LEdge] {
        return node.getConnectedEdges()
    }

    private func isHighDegreeNode(_ node: LNode) -> Bool {
        return degree(node) >= degreeThreshold
    }

    private func calculateInformation(_ hdn: LNode) -> HighDegreeNodeInformation {
        let hdni = HighDegreeNodeInformation()

        // check for incoming trees
        for incEdge in hdn.getIncomingEdges() {
            if incEdge.isSelfLoop() { continue }

            guard let src = incEdge.source?.node else { continue }
            if hasSingleConnection(src, edgeSelector: outgoingEdges) {
                let treeHeight = isTreeRoot(src, ancestorEdges: outgoingEdges, descendantEdges: incomingEdges)
                if treeHeight == -1 { continue }

                hdni.incTreesMaxHeight = max(hdni.incTreesMaxHeight, treeHeight)
                if hdni.incTreeRoots == nil {
                    hdni.incTreeRoots = [LNode]()
                }
                hdni.incTreeRoots?.append(src)
            }
        }

        // outgoing trees
        for outEdge in hdn.getOutgoingEdges() {
            if outEdge.isSelfLoop() { continue }

            guard let tgt = outEdge.target?.node else { continue }
            if hasSingleConnection(tgt, edgeSelector: incomingEdges) {
                let treeHeight = isTreeRoot(tgt, ancestorEdges: incomingEdges, descendantEdges: outgoingEdges)
                if treeHeight == -1 { continue }

                hdni.outTreesMaxHeight = max(hdni.outTreesMaxHeight, treeHeight)
                if hdni.outTreeRoots == nil {
                    hdni.outTreeRoots = [LNode]()
                }
                hdni.outTreeRoots?.append(tgt)
            }
        }

        return hdni
    }

    private func moveTree(_ root: LNode, edgesFun: (LNode) -> [LEdge], layers: [Layer]) {
        guard !layers.isEmpty else { return }

        root.setLayer(layers[0])

        let subList = Array(layers.dropFirst())
        for e in edgesFun(root) {
            guard let otherNode = other(e, root) else { continue }
            moveTree(otherNode, edgesFun: edgesFun, layers: subList)
        }
    }

    private func degree(_ node: LNode) -> Int {
        return node.getConnectedEdges().count
    }

    private func hasSingleConnection(_ node: LNode, edgeSelector: (LNode) -> [LEdge]) -> Bool {
        var connection: LNode? = nil

        for e in edgeSelector(node) {
            guard let otherNode = other(e, node) else { continue }
            if connection == nil {
                connection = otherNode
            } else {
                if otherNode !== connection {
                    return false
                }
            }
        }

        return true
    }

    private func other(_ edge: LEdge, _ node: LNode) -> LNode? {
        if edge.source?.node === node {
            return edge.target?.node
        } else {
            return edge.source?.node
        }
    }

    private func isTreeRoot(_ root: LNode,
                             ancestorEdges: (LNode) -> [LEdge],
                             descendantEdges: (LNode) -> [LEdge]) -> Int {
        // exclude high degree nodes themselves
        if isHighDegreeNode(root) {
            return -1
        }

        // does the node have exactly one parent?
        if !hasSingleConnection(root, edgeSelector: ancestorEdges) {
            return -1
        }

        // is it a leaf?
        if descendantEdges(root).isEmpty {
            return 1
        }

        // recursively check subtrees
        var currentHeight = 0
        for e in descendantEdges(root) {
            guard let otherNode = other(e, root) else { return -1 }
            let height = isTreeRoot(otherNode, ancestorEdges: ancestorEdges, descendantEdges: descendantEdges)

            if height == -1 {
                return -1
            }

            currentHeight = max(currentHeight, height)

            if currentHeight > treeHeightThreshold - 1 {
                return -1
            }
        }

        return currentHeight + 1
    }

    private class HighDegreeNodeInformation {
        var incTreesMaxHeight: Int = -1
        var incTreeRoots: [LNode]?
        var outTreesMaxHeight: Int = -1
        var outTreeRoots: [LNode]?
    }
}
