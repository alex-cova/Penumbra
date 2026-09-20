// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/SweepCopy.java

import Foundation

package class org_eclipse_elk_alg_layered_p3order_SweepCopy {
    package static let PORT_CONSTRAINTS_KEY: any IProperty = Property<PortConstraints>("org.eclipse.elk.portConstraints")
    package static let INTERNAL_IN_LAYER_LAYOUT_UNIT_KEY = org_eclipse_elk_alg_layered_options_InternalProperties.IN_LAYER_LAYOUT_UNIT
    package static let INTERNAL_ORIGIN_KEY = org_eclipse_elk_alg_layered_options_InternalProperties.ORIGIN

    // Java: LNode[][]
    package let nodeOrder: [[org_eclipse_elk_alg_layered_graph_LNode]]?
    // Java: List<List<List<LPort>>>
    package let portOrders: [[[org_eclipse_elk_alg_layered_graph_LPort]]]

    package init(_ nodeOrderIn: [[org_eclipse_elk_alg_layered_graph_LNode]]?) {
        nodeOrder = Self.deepCopy(nodeOrderIn)
        var newPortOrders: [[[org_eclipse_elk_alg_layered_graph_LPort]]] = []
        if let nodeOrderIn {
            for (_, layerNodes) in nodeOrderIn.enumerated() {
                var layerPorts: [[org_eclipse_elk_alg_layered_graph_LPort]] = []
                for node in layerNodes {
                    let ports = node.getPorts()
                    layerPorts.append(ports)
                }
                newPortOrders.append(layerPorts)
            }
        }
        portOrders = newPortOrders
    }

    package init(_ sc: org_eclipse_elk_alg_layered_p3order_SweepCopy) {
        nodeOrder = Self.deepCopy(sc.nodeOrder)
        // Java copies only outer list here; Swift arrays remain CoW and keep shared element identity.
        portOrders = sc.portOrders
    }

    package static func deepCopy(
        _ currentBestNodeOrder: [[org_eclipse_elk_alg_layered_graph_LNode]]?
    ) -> [[org_eclipse_elk_alg_layered_graph_LNode]]? {
        guard let currentBestNodeOrder else {
            return nil
        }
        var result: [[org_eclipse_elk_alg_layered_graph_LNode]] = []
        result.reserveCapacity(currentBestNodeOrder.count)
        for layer in currentBestNodeOrder {
            result.append(layer)
        }
        return result
    }

    package func nodes() -> [[org_eclipse_elk_alg_layered_graph_LNode]]? {
        nodeOrder
    }

    package func transferNodeAndPortOrdersToGraph(
        _ lGraph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ setPortContstraints: Bool
    ) {
        guard let nodeOrder else {
            return
        }

        var updatePortOrder: [ObjectIdentifier: org_eclipse_elk_alg_layered_graph_LNode] = [:]
        let layers = lGraph.getLayers()
        let layerLimit = min(layers.count, nodeOrder.count)

        for i in 0..<layerLimit {
            let layer = layers[i]
            var graphLayerNodes = layer.getNodes()
            let orderedLayerNodes = nodeOrder[i]
            var northSouthPortDummies: [org_eclipse_elk_alg_layered_graph_LNode] = []

            let nodeLimit = min(graphLayerNodes.count, orderedLayerNodes.count)
            for j in 0..<nodeLimit {
                let node = orderedLayerNodes[j]
                node.id = j
                if node.getType() == .NORTH_SOUTH_PORT {
                    northSouthPortDummies.append(node)
                }

                graphLayerNodes[j] = node

                if i < portOrders.count, j < portOrders[i].count {
                    let savedPorts = portOrders[i][j]
                    applyPortOrder(savedPorts, to: node)
                }

                if setPortContstraints {
                    let existing = node.getProperty(Self.PORT_CONSTRAINTS_KEY)
                        as? org_eclipse_elk_core_options_PortConstraints
                    let constraints = existing ?? .UNDEFINED
                    if !constraints.isOrderFixed() {
                        node.setProperty(Self.PORT_CONSTRAINTS_KEY, org_eclipse_elk_core_options_PortConstraints.FIXED_ORDER)
                    }
                }
            }

            layer.setNodes(graphLayerNodes)

            for dummy in northSouthPortDummies {
                if let origin = assertCorrectPortSides(dummy) {
                    updatePortOrder[ObjectIdentifier(origin)] = origin
                    updatePortOrder[ObjectIdentifier(dummy)] = dummy
                }
            }
        }

        for node in updatePortOrder.values {
            let sorted = node.getPorts().enumerated().sorted { lhs, rhs in
                let cmp = org_eclipse_elk_alg_layered_intermediate_PortListSorter.CMP_COMBINED(
                    lhs.element,
                    rhs.element
                )
                if cmp != 0 {
                    return cmp < 0
                }
                // Keep Java's stable-sort behavior for equal comparator values.
                return lhs.offset < rhs.offset
            }.map(\.element)
            applyPortOrder(sorted, to: node)
            node.cachePortSides()
        }
    }

    package func assertCorrectPortSides(
        _ dummy: org_eclipse_elk_alg_layered_graph_LNode
    ) -> org_eclipse_elk_alg_layered_graph_LNode? {
        guard dummy.getType() == .NORTH_SOUTH_PORT else {
            return nil
        }

        guard let origin: org_eclipse_elk_alg_layered_graph_LNode = dummy.getProperty(Self.INTERNAL_IN_LAYER_LAYOUT_UNIT_KEY) else {
            return nil
        }

        let dummyPorts = dummy.getPorts()
        guard let dummyPort = dummyPorts.first else {
            return origin
        }

        let representedPort: org_eclipse_elk_alg_layered_graph_LPort? = dummyPort.getProperty(Self.INTERNAL_ORIGIN_KEY)
        guard let representedPort else {
            return origin
        }

        for port in origin.getPorts() where port === representedPort {
            if port.getSide() == .NORTH && dummy.id > origin.id {
                port.setSide(.SOUTH)
                if port.isExplicitlySuppliedPortAnchor() {
                    let portHeight = port.getSize().y
                    let anchorY = port.getAnchor().y
                    port.getAnchor().y = portHeight - anchorY
                }
            } else if port.getSide() == .SOUTH && origin.id > dummy.id {
                port.setSide(.NORTH)
                if port.isExplicitlySuppliedPortAnchor() {
                    let portHeight = port.getSize().y
                    let anchorY = port.getAnchor().y
                    port.getAnchor().y = -(portHeight - anchorY)
                }
            }
            break
        }

        return origin
    }

    package func applyPortOrder(
        _ orderedPorts: [org_eclipse_elk_alg_layered_graph_LPort],
        to node: org_eclipse_elk_alg_layered_graph_LNode
    ) {
        for port in node.getPorts() {
            port.setNode(nil)
        }
        for port in orderedPorts {
            port.setNode(node)
        }
    }
}
