// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/LayerSweepTypeDecider.java
import Foundation

package class org_eclipse_elk_alg_layered_p3order_LayerSweepTypeDecider:
    org_eclipse_elk_alg_layered_p3order_counting_IInitializable
{
    package enum _Keys {
        static let crossingMinimizationHierarchicalSweepiness =
            "org.eclipse.elk.layered.crossingMinimization.hierarchicalSweepiness"
        static let portConstraints = "org.eclipse.elk.portConstraints"
        static let portDummy = "portDummy"
        static let origin = "org.eclipse.elk.layered.origin"
    }

    package var nodeInfo: [[NodeInfo?]]
    package let graphData: org_eclipse_elk_alg_layered_p3order_GraphInfoHolder

    package init() {
        graphData = org_eclipse_elk_alg_layered_p3order_GraphInfoHolder(
            org_eclipse_elk_alg_layered_graph_LGraph(),
            .NONE,
            []
        )
        nodeInfo = []
    }

    package init(_ graphData: org_eclipse_elk_alg_layered_p3order_GraphInfoHolder) {
        self.graphData = graphData
        self.nodeInfo = Array(repeating: [], count: graphData.currentNodeOrder().count)
    }

    package func useBottomUp() -> Bool {
        // Java default is 0.1 (from Layered.melk), NOT 0
        let boundary = graphData.lGraph().getProperty(_Keys.crossingMinimizationHierarchicalSweepiness) as? Double ?? 0.1

        if bottomUpForced(boundary) || rootNode() || fixedPortOrder() || fewerThanTwoInOutEdges() {
            return true
        }

        if graphData.crossMinDeterministic() {
            return false
        }

        var pathsToRandom = 0
        var pathsToHierarchical = 0

        var nsPortDummies: [org_eclipse_elk_alg_layered_graph_LNode] = []

        for layer in graphData.currentNodeOrder() {
            for node in layer {
                if isNorthSouthDummy(node) {
                    nsPortDummies.append(node)
                    continue
                }

                let currentNode = nodeInfoFor(node)

                if isExternalPortDummy(node) {
                    currentNode.hierarchicalInfluence = 1
                    if isEasternDummy(node) {
                        pathsToHierarchical += currentNode.connectedEdges
                    }
                } else if hasNoWesternPorts(node) {
                    currentNode.randomInfluence = 1
                } else if hasNoEasternPorts(node) {
                    pathsToRandom += currentNode.connectedEdges
                }

                for edge in node.getOutgoingEdges() {
                    pathsToRandom += currentNode.randomInfluence
                    pathsToHierarchical += currentNode.hierarchicalInfluence
                    transferInfoToTarget(currentNode, edge)
                }

                let northSouthPorts = node.getPortSideView(.NORTH) + node.getPortSideView(.SOUTH)
                for port in northSouthPorts {
                    if let nsDummy = port.getProperty(_Keys.portDummy) as? org_eclipse_elk_alg_layered_graph_LNode {
                        pathsToRandom += currentNode.randomInfluence
                        pathsToHierarchical += currentNode.hierarchicalInfluence
                        transferInfoTo(currentNode, nsDummy)
                    }
                }
            }

            for node in nsPortDummies {
                let currentNode = nodeInfoFor(node)
                for edge in node.getOutgoingEdges() {
                    pathsToRandom += currentNode.randomInfluence
                    pathsToHierarchical += currentNode.hierarchicalInfluence
                    transferInfoToTarget(currentNode, edge)
                }
            }
            nsPortDummies.removeAll(keepingCapacity: true)
        }

        let allPaths = Double(pathsToRandom + pathsToHierarchical)
        let normalized = allPaths == 0 ? Double.infinity : Double(pathsToRandom - pathsToHierarchical) / allPaths
        return normalized >= boundary
    }

    package func fixedPortOrder() -> Bool {
        let constraints = graphData.parent().getProperty(_Keys.portConstraints) as? org_eclipse_elk_core_options_PortConstraints
            ?? .UNDEFINED
        return constraints.isOrderFixed()
    }

    package func transferInfoToTarget(
        _ currentNode: NodeInfo,
        _ edge: org_eclipse_elk_alg_layered_graph_LEdge
    ) {
        transferInfoTo(currentNode, targetNode(edge))
    }

    package func transferInfoTo(
        _ currentNode: NodeInfo,
        _ target: org_eclipse_elk_alg_layered_graph_LNode
    ) {
        let targetNodeInfo = nodeInfoFor(target)
        targetNodeInfo.transfer(currentNode)
        targetNodeInfo.connectedEdges += 1
    }

    package func fewerThanTwoInOutEdges() -> Bool {
        graphData.parent().getPortSideView(.EAST).count < 2
            && graphData.parent().getPortSideView(.WEST).count < 2
    }

    package func rootNode() -> Bool {
        !graphData.hasParent()
    }

    package func bottomUpForced(_ boundary: Double) -> Bool {
        boundary < -1
    }

    package func targetNode(_ edge: org_eclipse_elk_alg_layered_graph_LEdge) -> org_eclipse_elk_alg_layered_graph_LNode {
        edge.getTarget()?.getNode() ?? org_eclipse_elk_alg_layered_graph_LNode(org_eclipse_elk_alg_layered_graph_LGraph())
    }

    package func hasNoEasternPorts(_ node: org_eclipse_elk_alg_layered_graph_LNode) -> Bool {
        let eastPorts = node.getPortSideView(.EAST)
        return eastPorts.isEmpty || !eastPorts.contains(where: { !$0.getConnectedEdges().isEmpty })
    }

    package func hasNoWesternPorts(_ node: org_eclipse_elk_alg_layered_graph_LNode) -> Bool {
        let westPorts = node.getPortSideView(.WEST)
        return westPorts.isEmpty || !westPorts.contains(where: { !$0.getConnectedEdges().isEmpty })
    }

    package func isExternalPortDummy(_ node: org_eclipse_elk_alg_layered_graph_LNode) -> Bool {
        node.getType() == .EXTERNAL_PORT
    }

    package func isNorthSouthDummy(_ node: org_eclipse_elk_alg_layered_graph_LNode) -> Bool {
        node.getType() == .NORTH_SOUTH_PORT
    }

    package func isEasternDummy(_ node: org_eclipse_elk_alg_layered_graph_LNode) -> Bool {
        originPort(node)?.getSide() == .EAST
    }

    package func originPort(_ node: org_eclipse_elk_alg_layered_graph_LNode) -> org_eclipse_elk_alg_layered_graph_LPort? {
        node.getProperty(_Keys.origin) as? org_eclipse_elk_alg_layered_graph_LPort
    }

    package func nodeInfoFor(_ node: org_eclipse_elk_alg_layered_graph_LNode) -> NodeInfo {
        guard let layerIndex = node.getLayer()?.id,
              layerIndex >= 0,
              layerIndex < nodeInfo.count,
              node.id >= 0,
              node.id < nodeInfo[layerIndex].count
        else {
            return NodeInfo()
        }

        if nodeInfo[layerIndex][node.id] == nil {
            nodeInfo[layerIndex][node.id] = NodeInfo()
        }
        guard let info = nodeInfo[layerIndex][node.id] else { return NodeInfo() }
        return info
    }

    package func initAtLayerLevel(
        _ l: Int,
        _ nodeOrder: [[org_eclipse_elk_alg_layered_graph_LNode]]
    ) {
        guard l >= 0, l < nodeOrder.count else { return }
        if let first = nodeOrder[l].first,
           let layer = first.getLayer()
        {
            layer.id = l
        }
        nodeInfo[l] = Array(repeating: nil, count: nodeOrder[l].count)
    }

    package func initAtNodeLevel(
        _ l: Int,
        _ n: Int,
        _ nodeOrder: [[org_eclipse_elk_alg_layered_graph_LNode]]
    ) {
        guard l >= 0, l < nodeOrder.count, n >= 0, n < nodeOrder[l].count else { return }
        let node = nodeOrder[l][n]
        node.id = n
        nodeInfo[l][n] = NodeInfo()
    }

    package final class NodeInfo: CustomStringConvertible {
        package var connectedEdges = 0
        package var hierarchicalInfluence = 0
        package var randomInfluence = 0

        package init() {}

        package func transfer(_ nodeInfo: NodeInfo) {
            hierarchicalInfluence += nodeInfo.hierarchicalInfluence
            randomInfluence += nodeInfo.randomInfluence
            connectedEdges += nodeInfo.connectedEdges
        }

        package var description: String {
            "NodeInfo [connectedEdges=\(connectedEdges), hierarchicalInfluence=\(hierarchicalInfluence), randomInfluence=\(randomInfluence)]"
        }
    }
}
