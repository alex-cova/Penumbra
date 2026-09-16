// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/InteractiveCrossingMinimizer.java
import Foundation

package final class org_eclipse_elk_alg_layered_p3order_InteractiveCrossingMinimizer {
    package enum _Keys {
        static let graphProperties = org_eclipse_elk_alg_layered_options_InternalProperties.GRAPH_PROPERTIES
        static let inLayerSuccessorConstraints = org_eclipse_elk_alg_layered_options_InternalProperties.IN_LAYER_SUCCESSOR_CONSTRAINTS
        static let originalDummyNodePosition = org_eclipse_elk_alg_layered_options_InternalProperties.ORIGINAL_DUMMY_NODE_POSITION
        static let origin = org_eclipse_elk_alg_layered_options_InternalProperties.ORIGIN
        static let originalBendpoints = org_eclipse_elk_alg_layered_options_InternalProperties.ORIGINAL_BENDPOINTS
        static let reversed = "reversed"
        static let longEdgeSource = org_eclipse_elk_alg_layered_options_InternalProperties.LONG_EDGE_SOURCE
        static let longEdgeTarget = org_eclipse_elk_alg_layered_options_InternalProperties.LONG_EDGE_TARGET
    }

    package static let INTERMEDIATE_PROCESSING_CONFIGURATION: LayoutProcessorConfiguration<LayeredPhases, LGraph> = {
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(
                org_eclipse_elk_alg_layered_LayeredPhases.P3_NODE_ORDERING,
                org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy.LONG_EDGE_SPLITTER
            )
            .addBefore(
                org_eclipse_elk_alg_layered_LayeredPhases.P4_NODE_PLACEMENT,
                org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy.IN_LAYER_CONSTRAINT_PROCESSOR
            )
            .addAfter(
                org_eclipse_elk_alg_layered_LayeredPhases.P5_EDGE_ROUTING,
                org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy.LONG_EDGE_JOINER
            )
    }()

    package init() {}

    package func getLayoutProcessorConfiguration(
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph
    ) -> LayoutProcessorConfiguration<LayeredPhases, LGraph>? {
        let configuration = LayoutProcessorConfiguration<LayeredPhases, LGraph>.create(
            from: Self.INTERMEDIATE_PROCESSING_CONFIGURATION
        )
        let graphProperties = graph.getProperty(_Keys.graphProperties)
            as? Set<org_eclipse_elk_alg_layered_options_GraphProperties> ?? []
        if graphProperties.contains(.NON_FREE_PORTS) {
            configuration.addBefore(
                org_eclipse_elk_alg_layered_LayeredPhases.P3_NODE_ORDERING,
                org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy.PORT_LIST_SORTER
            )
        }
        return configuration
    }

    package func process(
        _ layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ monitor: any org_eclipse_elk_core_util_IElkProgressMonitor
    ) {
        monitor.begin("Interactive crossing minimization", 1)

        var layerIndex = 0
        for layer in layeredGraph.getLayers() {
            layer.id = layerIndex
            layerIndex += 1
        }

        let nodeOrder = layeredGraph.getLayers().map { $0.getNodes() }
        let portDistributor = org_eclipse_elk_alg_layered_p3order_NodeRelativePortDistributor(nodeOrder.count)

        var portCount = 0
        layerIndex = 0
        for layer in layeredGraph {
            var horizPos: Double = 0
            var nodeCount = 0
            for node in layer.getNodes() {
                if node.getPosition().x > 0 {
                    horizPos += node.getPosition().x + node.getSize().x / 2
                    nodeCount += 1
                }
                for port in node.getPorts() {
                    port.id = portCount
                    portCount += 1
                }
            }

            if nodeCount > 0 {
                horizPos /= Double(nodeCount)
            }

            let nodes = layer.getNodes()
            var positions: [ObjectIdentifier: Double] = [:]
            positions.reserveCapacity(nodes.count)

            for (index, node) in nodes.enumerated() {
                node.id = index
                let y = getPos(node, horizPos)
                positions[ObjectIdentifier(node)] = y

                if node.getType() == .LONG_EDGE {
                    node.setProperty(_Keys.originalDummyNodePosition, y)
                }
            }

            let sortedNodes = nodes.sorted { n1, n2 in
                let p1 = positions[ObjectIdentifier(n1)] ?? 0
                let p2 = positions[ObjectIdentifier(n2)] ?? 0
                let compare = p1 == p2 ? 0 : (p1 < p2 ? -1 : 1)

                if compare == 0 {
                    let node1Successors = n1.getProperty(_Keys.inLayerSuccessorConstraints)
                        as? [org_eclipse_elk_alg_layered_graph_LNode] ?? []
                    let node2Successors = n2.getProperty(_Keys.inLayerSuccessorConstraints)
                        as? [org_eclipse_elk_alg_layered_graph_LNode] ?? []

                    if node1Successors.contains(where: { $0 === n2 }) {
                        return true
                    }
                    if node2Successors.contains(where: { $0 === n1 }) {
                        return false
                    }
                }

                return p1 < p2
            }

            layer.setNodes(sortedNodes)
            _ = portDistributor.distributePortsWhileSweeping(nodeOrder, layerIndex, true)
            layerIndex += 1
        }

        monitor.done()
    }

    package func getPos(
        _ node: org_eclipse_elk_alg_layered_graph_LNode,
        _ horizPos: Double
    ) -> Double {
        switch node.getType() {
        case .LONG_EDGE:
            guard let edge = node.getProperty(_Keys.origin) as? org_eclipse_elk_alg_layered_graph_LEdge else {
                break
            }

            var bendpoints = edge.getProperty(_Keys.originalBendpoints) as? org_eclipse_elk_core_math_KVectorChain
                ?? org_eclipse_elk_core_math_KVectorChain()
            if edge.getProperty(_Keys.reversed) as? Bool ?? false {
                bendpoints = org_eclipse_elk_core_math_KVectorChain.reverse(bendpoints)
            }

            let source = node.getProperty(_Keys.longEdgeSource) as? org_eclipse_elk_alg_layered_graph_LPort
            if let source {
                let sourcePoint = source.getAbsoluteAnchor()
                if horizPos <= sourcePoint.x {
                    return sourcePoint.y
                }
                bendpoints.addFirst(sourcePoint)
            }

            let target = node.getProperty(_Keys.longEdgeTarget) as? org_eclipse_elk_alg_layered_graph_LPort
            if let target {
                let targetPoint = target.getAbsoluteAnchor()
                if targetPoint.x <= horizPos {
                    return targetPoint.y
                }
                bendpoints.addLast(targetPoint)
            }

            let points = bendpoints.toArray()
            if points.count >= 2 {
                var point1 = points[0]
                var point2 = points[1]
                var i = 1
                while point2.x < horizPos && i + 1 < points.count {
                    point1 = point2
                    i += 1
                    point2 = points[i]
                }

                if point2.x == point1.x {
                    return point1.y
                }
                return point1.y + (horizPos - point1.x) / (point2.x - point1.x) * (point2.y - point1.y)
            }

        case .NORTH_SOUTH_PORT:
            guard let firstPort = node.getPorts().first,
                  let originPort = firstPort.getProperty(_Keys.origin) as? org_eclipse_elk_alg_layered_graph_LPort,
                  let originNode = originPort.getNode()
            else {
                break
            }

            switch originPort.getSide() {
            case .NORTH:
                return originNode.getPosition().y
            case .SOUTH:
                return originNode.getPosition().y + originNode.getSize().y
            case .EAST, .WEST, .UNDEFINED:
                break
            }

        default:
            break
        }

        return node.getInteractiveReferencePoint().y
    }
}
