// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/greedyswitch/NorthSouthEdgeNeighbouringNodeCrossingsCounter.java
import Foundation

package class org_eclipse_elk_alg_layered_intermediate_greedyswitch_NorthSouthEdgeNeighbouringNodeCrossingsCounter {

    private var upperLowerCrossings: Int = 0
    private var lowerUpperCrossings: Int = 0
    private var portPositions: [ObjectIdentifier: Int] = [:]
    private let layer: [LNode]

    package init(_ nodes: [LNode]) {
        layer = nodes
        initializePortPositions()
    }

    private func initializePortPositions() {
        for node in layer {
            setPortIdsOn(node, .SOUTH)
            setPortIdsOn(node, .NORTH)
        }
    }

    private func setPortIdsOn(_ node: LNode, _ side: PortSide) {
        let ports = CrossMinUtil.inNorthSouthEastWestOrder(node, side)
        var portId = 0
        for port in ports {
            portPositions[ObjectIdentifier(port)] = portId
            portId += 1
        }
    }

    package func countCrossings(_ upperNode: LNode, _ lowerNode: LNode) {
        upperLowerCrossings = 0
        lowerUpperCrossings = 0

        processIfTwoNorthSouthNodes(upperNode, lowerNode)
        processIfNorthSouthLongEdgeDummyCrossing(upperNode, lowerNode)
        processIfNormalNodeWithNSPortsAndLongEdgeDummy(upperNode, lowerNode)
    }

    private func processIfTwoNorthSouthNodes(_ upperNode: LNode, _ lowerNode: LNode) {
        if isNorthSouth(upperNode) && isNorthSouth(lowerNode) && !haveDifferentOrigins(upperNode, lowerNode) {
            if isNorthOfNormalNode(upperNode) {
                countCrossingsOfTwoNorthSouthDummies(upperNode, lowerNode)
            } else {
                countCrossingsOfTwoNorthSouthDummies(lowerNode, upperNode)
            }
        }
    }

    private func countCrossingsOfTwoNorthSouthDummies(
        _ furtherFromNormalNode: LNode,
        _ closerToNormalNode: LNode
    ) {
        if originPortPositionOf(furtherFromNormalNode) > originPortPositionOf(closerToNormalNode) {
            let closerEastPorts = closerToNormalNode.getPortSideView(.EAST)
            upperLowerCrossings = closerEastPorts.isEmpty ? 0 : closerEastPorts[0].getDegree()
            let furtherWestPorts = furtherFromNormalNode.getPortSideView(.WEST)
            lowerUpperCrossings = furtherWestPorts.isEmpty ? 0 : furtherWestPorts[0].getDegree()
        } else {
            let closerWestPorts = closerToNormalNode.getPortSideView(.WEST)
            upperLowerCrossings = closerWestPorts.isEmpty ? 0 : closerWestPorts[0].getDegree()
            let furtherEastPorts = furtherFromNormalNode.getPortSideView(.EAST)
            lowerUpperCrossings = furtherEastPorts.isEmpty ? 0 : furtherEastPorts[0].getDegree()
        }
    }

    private func processIfNorthSouthLongEdgeDummyCrossing(_ upperNode: LNode, _ lowerNode: LNode) {
        if isNorthSouth(upperNode) && isLongEdgeDummy(lowerNode) {
            if isNorthOfNormalNode(upperNode) {
                upperLowerCrossings = 1
            } else {
                lowerUpperCrossings = 1
            }
        } else if isNorthSouth(lowerNode) && isLongEdgeDummy(upperNode) {
            if isNorthOfNormalNode(lowerNode) {
                lowerUpperCrossings = 1
            } else {
                upperLowerCrossings = 1
            }
        }
    }

    private func processIfNormalNodeWithNSPortsAndLongEdgeDummy(_ upperNode: LNode, _ lowerNode: LNode) {
        if isNormal(upperNode) && isLongEdgeDummy(lowerNode) {
            upperLowerCrossings = numberOfNorthSouthEdges(upperNode, .SOUTH)
            lowerUpperCrossings = numberOfNorthSouthEdges(upperNode, .NORTH)
        }
        if isNormal(lowerNode) && isLongEdgeDummy(upperNode) {
            upperLowerCrossings = numberOfNorthSouthEdges(lowerNode, .NORTH)
            lowerUpperCrossings = numberOfNorthSouthEdges(lowerNode, .SOUTH)
        }
    }

    private func numberOfNorthSouthEdges(_ node: LNode, _ side: PortSide) -> Int {
        var count = 0
        for port in node.getPortSideView(side) {
            if hasConnectedNorthSouthEdge(port) {
                count += 1
            }
        }
        return count
    }

    private func hasConnectedNorthSouthEdge(_ port: LPort) -> Bool {
        port.getProperty(InternalProperties.PORT_DUMMY) != nil
    }

    private func haveDifferentOrigins(_ upperNode: LNode, _ lowerNode: LNode) -> Bool {
        originOf(upperNode) !== originOf(lowerNode)
    }

    private func originPortPositionOf(_ node: LNode) -> Int {
        let origin = originPortOf(node)
        return portPositions[ObjectIdentifier(origin)] ?? 0
    }

    private func originPortOf(_ node: LNode) -> LPort {
        let port = node.getPorts()[0]
        guard let origin = port.getProperty(InternalProperties.ORIGIN) as? LPort else { return port }
        return origin
    }

    private func isNorthOfNormalNode(_ node: LNode) -> Bool {
        originPortOf(node).getSide() == .NORTH
    }

    private func originOf(_ node: LNode) -> LNode? {
        node.getProperty(InternalProperties.ORIGIN) as? LNode
    }

    private func isLongEdgeDummy(_ node: LNode) -> Bool {
        node.getType() == .LONG_EDGE
    }

    private func isNorthSouth(_ node: LNode) -> Bool {
        node.getType() == .NORTH_SOUTH_PORT
    }

    private func isNormal(_ node: LNode) -> Bool {
        node.getType() == .NORMAL
    }

    package func getUpperLowerCrossings() -> Int {
        upperLowerCrossings
    }

    package func getLowerUpperCrossings() -> Int {
        lowerUpperCrossings
    }
}
