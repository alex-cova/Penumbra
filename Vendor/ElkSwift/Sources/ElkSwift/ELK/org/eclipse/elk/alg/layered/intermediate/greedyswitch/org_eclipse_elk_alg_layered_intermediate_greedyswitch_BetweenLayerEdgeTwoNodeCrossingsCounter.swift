// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/greedyswitch/BetweenLayerEdgeTwoNodeCrossingsCounter.java
import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_greedyswitch_BetweenLayerEdgeTwoNodeCrossingsCounter {

    private var upperLowerCrossings: Int = 0
    private var lowerUpperCrossings: Int = 0
    private let currentNodeOrder: [[LNode]]
    private let freeLayerIndex: Int
    private var portPositions: [ObjectIdentifier: Int] = [:]
    private var easternAdjacencies: [ObjectIdentifier: AdjacencyList] = [:]
    private var westernAdjacencies: [ObjectIdentifier: AdjacencyList] = [:]

    package init(_ currentNodeOrder: [[LNode]], _ freeLayerIndex: Int) {
        self.currentNodeOrder = currentNodeOrder
        self.freeLayerIndex = freeLayerIndex
        setPortPositionsForNeighbouringLayers()
    }

    private func setPortPositionsForNeighbouringLayers() {
        if freeLayerIsNotFirstLayer() {
            setPortPositionsForLayer(freeLayerIndex - 1, .EAST)
        }
        if freeLayerIsNotLastLayer() {
            setPortPositionsForLayer(freeLayerIndex + 1, .WEST)
        }
    }

    private func freeLayerIsNotFirstLayer() -> Bool {
        freeLayerIndex > 0
    }

    private func freeLayerIsNotLastLayer() -> Bool {
        freeLayerIndex < currentNodeOrder.count - 1
    }

    private func setPortPositionsForLayer(_ layerIndex: Int, _ portSide: PortSide) {
        var portId = 0
        for node in currentNodeOrder[layerIndex] {
            let ports = CrossMinUtil.inNorthSouthEastWestOrder(node, portSide)
            for port in ports {
                portPositions[ObjectIdentifier(port)] = portId
                portId += 1
            }
        }
    }

    package func countEasternEdgeCrossings(_ upperNode: LNode, _ lowerNode: LNode) {
        resetCrossingCount()
        if upperNode === lowerNode { return }
        addEasternCrossings(upperNode, lowerNode)
    }

    package func countWesternEdgeCrossings(_ upperNode: LNode, _ lowerNode: LNode) {
        resetCrossingCount()
        if upperNode === lowerNode { return }
        addWesternCrossings(upperNode, lowerNode)
    }

    package func countBothSideCrossings(_ upperNode: LNode, _ lowerNode: LNode) {
        resetCrossingCount()
        if upperNode === lowerNode { return }
        addWesternCrossings(upperNode, lowerNode)
        addEasternCrossings(upperNode, lowerNode)
    }

    private func resetCrossingCount() {
        upperLowerCrossings = 0
        lowerUpperCrossings = 0
    }

    private func addEasternCrossings(_ upperNode: LNode, _ lowerNode: LNode) {
        let upperAdj = getAdjacencyFor(upperNode, .EAST, &easternAdjacencies)
        let lowerAdj = getAdjacencyFor(lowerNode, .EAST, &easternAdjacencies)
        if upperAdj.size() == 0 || lowerAdj.size() == 0 { return }
        countCrossingsByMergingAdjacencyLists(upperAdj, lowerAdj)
    }

    private func addWesternCrossings(_ upperNode: LNode, _ lowerNode: LNode) {
        let upperAdj = getAdjacencyFor(upperNode, .WEST, &westernAdjacencies)
        let lowerAdj = getAdjacencyFor(lowerNode, .WEST, &westernAdjacencies)
        if upperAdj.size() == 0 || lowerAdj.size() == 0 { return }
        countCrossingsByMergingAdjacencyLists(upperAdj, lowerAdj)
    }

    private func getAdjacencyFor(
        _ node: LNode,
        _ side: PortSide,
        _ adjacencies: inout [ObjectIdentifier: AdjacencyList]
    ) -> AdjacencyList {
        if adjacencies.isEmpty {
            for n in currentNodeOrder[freeLayerIndex] {
                adjacencies[ObjectIdentifier(n)] = AdjacencyList(n, side, portPositions)
            }
        }
        let aL = adjacencies[ObjectIdentifier(node)]!
        aL.reset()
        return aL
    }

    private func countCrossingsByMergingAdjacencyLists(_ upperAdj: AdjacencyList, _ lowerAdj: AdjacencyList) {
        while !upperAdj.isEmpty() && !lowerAdj.isEmpty() {
            if isBelow(upperAdj.first(), lowerAdj.first()) {
                upperLowerCrossings += upperAdj.size()
                lowerAdj.removeFirst()
            } else if isBelow(lowerAdj.first(), upperAdj.first()) {
                lowerUpperCrossings += lowerAdj.size()
                upperAdj.removeFirst()
            } else {
                upperLowerCrossings += upperAdj.countAdjacenciesBelowNodeOfFirstPort()
                lowerUpperCrossings += lowerAdj.countAdjacenciesBelowNodeOfFirstPort()
                upperAdj.removeFirst()
                lowerAdj.removeFirst()
            }
        }
    }

    private func isBelow(_ firstPort: Int, _ secondPort: Int) -> Bool {
        firstPort > secondPort
    }

    // MARK: - AdjacencyList

    private class AdjacencyList {
        private let node: LNode
        private var adjacencyList: [Adjacency] = []
        private let side: PortSide
        private var totalSize: Int = 0
        private var currentSize: Int = 0
        private var currentIndex: Int = 0
        private let portPositions: [ObjectIdentifier: Int]

        init(_ node: LNode, _ side: PortSide, _ portPositions: [ObjectIdentifier: Int]) {
            self.node = node
            self.side = side
            self.portPositions = portPositions
            getAdjacenciesSortedByPosition()
        }

        private func getAdjacenciesSortedByPosition() {
            iterateThroughEdgesCollectingAdjacencies()
            adjacencyList.sort()
        }

        private func iterateThroughEdgesCollectingAdjacencies() {
            let ports = CrossMinUtil.inNorthSouthEastWestOrder(node, side)
            for port in ports {
                let edges = getEdgesConnectedTo(port)
                for edge in edges {
                    if !edge.isSelfLoop() && isNotInLayer(edge) {
                        addAdjacencyOf(edge)
                        totalSize += 1
                        currentSize += 1
                    }
                }
            }
        }

        private func getEdgesConnectedTo(_ port: LPort) -> [LEdge] {
            side == .WEST ? port.getIncomingEdges() : port.getOutgoingEdges()
        }

        private func isNotInLayer(_ edge: LEdge) -> Bool {
            edge.getSource()?.getNode()?.getLayer() !== edge.getTarget()?.getNode()?.getLayer()
        }

        private func addAdjacencyOf(_ edge: LEdge) {
            guard let adjacentPort = adjacentPortOf(edge, side) else { return }
            let adjacentPortPosition = portPositions[ObjectIdentifier(adjacentPort)] ?? 0
            let lastIndex = adjacencyList.count - 1
            if !adjacencyList.isEmpty && adjacencyList[lastIndex].position == adjacentPortPosition {
                adjacencyList[lastIndex].cardinality += 1
                adjacencyList[lastIndex].currentCardinality += 1
            } else {
                adjacencyList.append(Adjacency(adjacentPortPosition))
            }
        }

        private func adjacentPortOf(_ edge: LEdge, _ s: PortSide) -> LPort? {
            s == .WEST ? edge.getSource() : edge.getTarget()
        }

        func reset() {
            currentIndex = 0
            currentSize = totalSize
            if !isEmpty() {
                currentAdjacency().reset()
            }
        }

        func countAdjacenciesBelowNodeOfFirstPort() -> Int {
            currentSize - currentAdjacency().currentCardinality
        }

        func removeFirst() {
            if isEmpty() { return }
            let currentEntry = currentAdjacency()
            if currentEntry.currentCardinality == 1 {
                incrementCurrentIndex()
            } else {
                currentEntry.currentCardinality -= 1
            }
            currentSize -= 1
        }

        private func incrementCurrentIndex() {
            currentIndex += 1
            if currentIndex < adjacencyList.count {
                currentAdjacency().reset()
            }
        }

        func isEmpty() -> Bool {
            currentSize == 0
        }

        func first() -> Int {
            currentAdjacency().position
        }

        func size() -> Int {
            currentSize
        }

        private func currentAdjacency() -> Adjacency {
            adjacencyList[currentIndex]
        }
    }

    // MARK: - Adjacency

    private class Adjacency: Comparable {
        let position: Int
        var cardinality: Int
        var currentCardinality: Int

        init(_ adjacentPortPosition: Int) {
            position = adjacentPortPosition
            cardinality = 1
            currentCardinality = 1
        }

        func reset() {
            currentCardinality = cardinality
        }

        static func < (lhs: Adjacency, rhs: Adjacency) -> Bool {
            lhs.position < rhs.position
        }

        static func == (lhs: Adjacency, rhs: Adjacency) -> Bool {
            lhs.position == rhs.position
        }
    }

    // MARK: - Getters

    package func getUpperLowerCrossings() -> Int {
        upperLowerCrossings
    }

    package func getLowerUpperCrossings() -> Int {
        lowerUpperCrossings
    }
}
