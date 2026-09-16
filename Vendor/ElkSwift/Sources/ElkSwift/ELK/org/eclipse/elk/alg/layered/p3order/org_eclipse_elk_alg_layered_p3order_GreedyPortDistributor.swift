// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/GreedyPortDistributor.java
import Foundation

package class org_eclipse_elk_alg_layered_p3order_GreedyPortDistributor:
    org_eclipse_elk_alg_layered_p3order_ISweepPortDistributor,
    org_eclipse_elk_alg_layered_p3order_counting_IInitializable
{
    package var crossingsCounter = org_eclipse_elk_alg_layered_p3order_counting_CrossingsCounter()
    package var nPorts = 0
    package var portPos: [Int] = []
    package var hierarchicalCrossingsCounter: org_eclipse_elk_alg_layered_intermediate_greedyswitch_BetweenLayerEdgeTwoNodeCrossingsCounter?

    package init() {}

    package func distributePortsWhileSweeping(
        _ nodeOrder: [[org_eclipse_elk_alg_layered_graph_LNode]],
        _ currentIndex: Int,
        _ isForwardSweep: Bool
    ) -> Bool {
        initialize(nodeOrder, currentIndex, isForwardSweep)
        return distributePortsInLayer(nodeOrder, currentIndex, isForwardSweep)
    }

    package func distributePortsInLayer(
        _ nodeOrder: [[org_eclipse_elk_alg_layered_graph_LNode]],
        _ currentIndex: Int,
        _ isForwardSweep: Bool
    ) -> Bool {
        guard currentIndex >= 0, currentIndex < nodeOrder.count else {
            return false
        }

        let side: org_eclipse_elk_core_options_PortSide = isForwardSweep ? .WEST : .EAST
        var improved = false

        for node in nodeOrder[currentIndex] {
            let pc = portConstraints(of: node)
            let sidePorts = node.getPortSideView(side)
            if sidePorts.count > 1 {
                let label = node.getLabels().first?.getText() ?? "node\(node.id)"
            }
            if pc.isOrderFixed() {
                if sidePorts.count > 1 {
                    let label = node.getLabels().first?.getText() ?? "node\(node.id)"
                }
                continue
            }

            let nestedGraph = node.getNestedGraph()
            let useHierarchicalCrossCounter = !node.getPortSideView(side).isEmpty && nestedGraph != nil

            if useHierarchicalCrossCounter, let nestedGraph {
                let innerGraph = nestedGraph.toNodeArray()
                let relevantLayer = isForwardSweep ? 0 : max(0, innerGraph.count - 1)
                hierarchicalCrossingsCounter =
                    org_eclipse_elk_alg_layered_intermediate_greedyswitch_BetweenLayerEdgeTwoNodeCrossingsCounter(
                        innerGraph,
                        relevantLayer
                    )
            }

            improved = distributePortsOnNode(node, side, useHierarchicalCrossCounter) || improved
        }

        return improved
    }

    package func distributePortsOnNode(
        _ node: org_eclipse_elk_alg_layered_graph_LNode,
        _ side: org_eclipse_elk_core_options_PortSide,
        _ useHierarchicalCrosscounter: Bool
    ) -> Bool {
        // In Java, getPortSideView returns a live subList view — mutations propagate
        // back to the node's port list. In Swift, we get a value copy, so we must
        // write the reordered ports back after the greedy swap loop.
        var ports = node.getPortSideView(side)
        let reversed = (side == .SOUTH || side == .WEST)
        if reversed {
            ports.reverse()
        }

        var improved = false
        var continueSwitching: Bool

        repeat {
            continueSwitching = false
            if ports.count > 1 {
                var i = 0
                while i < ports.count - 1 {
                    let upperPort = ports[i]
                    let lowerPort = ports[i + 1]

                    if switchingDecreasesCrossings(upperPort, lowerPort, node, useHierarchicalCrosscounter) {
                        improved = true
                        switchPorts(&ports, node, i, i + 1)
                        continueSwitching = true
                    }

                    i += 1
                }
            }
        } while continueSwitching

        // Write back: propagate reordered ports to the node's actual port list.
        if improved {
            if reversed {
                ports.reverse()
            }
            node.setPortSideView(side, ports)
        }

        return improved
    }

    package func initForLayers(
        _ leftLayer: [org_eclipse_elk_alg_layered_graph_LNode],
        _ rightLayer: [org_eclipse_elk_alg_layered_graph_LNode]
    ) {
        crossingsCounter.initForCountingBetween(leftLayer, rightLayer)
    }

    package func switchingDecreasesCrossings(
        _ upperPort: org_eclipse_elk_alg_layered_graph_LPort,
        _ lowerPort: org_eclipse_elk_alg_layered_graph_LPort,
        _ node: org_eclipse_elk_alg_layered_graph_LNode,
        _ useHierarchicalCrosscounter: Bool
    ) -> Bool {
        _ = node
        let originalAndSwitched = crossingsCounter.countCrossingsBetweenPortsInBothOrders(upperPort, lowerPort)
        var upperLowerCrossings = originalAndSwitched.getFirst() ?? 0
        var lowerUpperCrossings = originalAndSwitched.getSecond() ?? 0

        if useHierarchicalCrosscounter {
            let upperNode = upperPort.getProperty(portDummyKey()) as? org_eclipse_elk_alg_layered_graph_LNode
            let lowerNode = lowerPort.getProperty(portDummyKey()) as? org_eclipse_elk_alg_layered_graph_LNode

            if let upperNode, let lowerNode, let hierarchicalCrossingsCounter {
                hierarchicalCrossingsCounter.countBothSideCrossings(upperNode, lowerNode)
                upperLowerCrossings += hierarchicalCrossingsCounter.getUpperLowerCrossings()
                lowerUpperCrossings += hierarchicalCrossingsCounter.getLowerUpperCrossings()
            }
        }

        return upperLowerCrossings > lowerUpperCrossings
    }

    package func switchPorts(
        _ ports: inout [org_eclipse_elk_alg_layered_graph_LPort],
        _ node: org_eclipse_elk_alg_layered_graph_LNode,
        _ topPort: Int,
        _ bottomPort: Int
    ) {
        _ = node

        guard topPort >= 0, bottomPort >= 0, topPort < ports.count, bottomPort < ports.count else {
            return
        }

        crossingsCounter.switchPorts(ports[topPort], ports[bottomPort])
        let lower = ports[bottomPort]
        ports[bottomPort] = ports[topPort]
        ports[topPort] = lower
    }

    package func initialize(
        _ nodeOrder: [[org_eclipse_elk_alg_layered_graph_LNode]],
        _ currentIndex: Int,
        _ isForwardSweep: Bool
    ) {
        if isForwardSweep, currentIndex > 0 {
            initForLayers(nodeOrder[currentIndex - 1], nodeOrder[currentIndex])
        } else if !isForwardSweep, currentIndex < nodeOrder.count - 1 {
            initForLayers(nodeOrder[currentIndex], nodeOrder[currentIndex + 1])
        } else if currentIndex >= 0, currentIndex < nodeOrder.count {
            crossingsCounter.initPortPositionsForInLayerCrossings(
                nodeOrder[currentIndex],
                isForwardSweep ? .WEST : .EAST
            )
        }
    }

    package func initAtNodeLevel(
        _ l: Int,
        _ n: Int,
        _ nodeOrder: [[org_eclipse_elk_alg_layered_graph_LNode]]
    ) {
        guard l >= 0, l < nodeOrder.count, n >= 0, n < nodeOrder[l].count else {
            return
        }

        let node = nodeOrder[l][n]
        nPorts += node.getPorts().count
    }

    package func initAfterTraversal() {
        portPos = Array(repeating: 0, count: nPorts)
        crossingsCounter = org_eclipse_elk_alg_layered_p3order_counting_CrossingsCounter(portPos)
    }

    package func portConstraints(of node: org_eclipse_elk_alg_layered_graph_LNode) -> org_eclipse_elk_core_options_PortConstraints {
        let value = node.getProperty(portConstraintsKey()) as? org_eclipse_elk_core_options_PortConstraints
        return value ?? .UNDEFINED
    }

    package func portConstraintsKey() -> String {
        "org.eclipse.elk.portConstraints"
    }

    package func portDummyKey() -> String {
        "portDummy"
    }
}

