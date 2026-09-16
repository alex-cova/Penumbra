import Foundation

package class org_eclipse_elk_alg_layered_intermediate_HierarchicalNodeResizingProcessor {
    package init() {}

    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {
        _ = progressMonitor.begin("Resize child graph to fit parent.", 1)

        // Move all layer nodes to layerless
        for layer in graph.layers {
            graph.layerlessNodes.append(contentsOf: layer.nodes)
            layer.nodes.removeAll()
        }
        for node in graph.layerlessNodes {
            node.setLayer(nil)
        }
        graph.layers.removeAll()

        resizeGraph(graph)

        if isNested(graph), let parentNode = graph.getParentNode() {
            graphLayoutToNode(parentNode, graph)
        }

        progressMonitor.done()
    }

    private func graphLayoutToNode(_ node: LNode, _ lgraph: LGraph) {
        // Check if child and parent graphs have different transposition behavior.
        // DOWN/UP directions transpose x↔y in GraphTransformer; RIGHT/LEFT do not.
        // When they differ, sizes and port positions from the child graph must be
        // transposed to match the parent graph's internal coordinate system.
        let childDir = lgraph.getProperty(LayeredOptions.DIRECTION) as? Direction ?? .UNDEFINED
        let parentDir = node.getGraph()?.getProperty(LayeredOptions.DIRECTION) as? Direction ?? .UNDEFINED
        let needsTranspose = directionTransposes(childDir) != directionTransposes(parentDir)

        // Process external ports
        for childNode in lgraph.layerlessNodes {
            if let port = childNode.getProperty(InternalProperties.ORIGIN) as? LPort {
                let portPosition = LGraphUtil.getExternalPortPosition(
                    lgraph, childNode, port.getSize().x, port.getSize().y)
                if needsTranspose {
                    port.getPosition().x = portPosition.y
                    port.getPosition().y = portPosition.x
                } else {
                    port.getPosition().x = portPosition.x
                    port.getPosition().y = portPosition.y
                }
                // Keep the port side from the child graph's direction — an LR subgraph
                // should have entry on WEST (left) and exit on EAST (right), not transposed
                // to NORTH/SOUTH which would force top/bottom entry.
                if let side = childNode.getProperty(InternalProperties.EXT_PORT_SIDE) as? PortSide {
                    port.setSide(side)
                }
            }
        }

        // Setup the parent node
        let actualGraphSize = lgraph.getActualSize()
        if needsTranspose {
            let temp = actualGraphSize.x
            actualGraphSize.x = actualGraphSize.y
            actualGraphSize.y = temp
        }
        let graphProperties = lgraph.getProperty(InternalProperties.GRAPH_PROPERTIES) as? Set<GraphProperties> ?? []

        if graphProperties.contains(.EXTERNAL_PORTS) {
            node.setProperty(LayeredOptions.PORT_CONSTRAINTS, value: PortConstraints.FIXED_POS)
            if var parentGraphProps = node.getGraph()?.getProperty(InternalProperties.GRAPH_PROPERTIES) as? Set<GraphProperties> {
                parentGraphProps.insert(.NON_FREE_PORTS)
                node.getGraph()?.setProperty(InternalProperties.GRAPH_PROPERTIES, value: parentGraphProps)
            }
            LGraphUtil.resizeNode(node, newSize: actualGraphSize, movePorts: false, moveLabels: true)
        } else {
            LGraphUtil.resizeNode(node, newSize: actualGraphSize, movePorts: true, moveLabels: true)
        }
    }

    /// Whether the given direction uses coordinate transposition in GraphTransformer.
    /// DOWN and UP transpose x↔y; RIGHT and LEFT do not.
    private func directionTransposes(_ dir: Direction) -> Bool {
        dir == .DOWN || dir == .UP
    }

    /// Transpose a port side (same as GraphTransformer's transposedPortSide).
    private func transposedPortSide(_ side: PortSide) -> PortSide {
        switch side {
        case .NORTH: return .WEST
        case .WEST: return .NORTH
        case .SOUTH: return .EAST
        case .EAST: return .SOUTH
        default: return .UNDEFINED
        }
    }

    private func isNested(_ graph: LGraph) -> Bool {
        return graph.getParentNode() != nil
    }

    private func resizeGraph(_ lgraph: LGraph) {
        let sizeConstraint = lgraph.getProperty(LayeredOptions.NODE_SIZE_CONSTRAINTS) as? SizeConstraint ?? []
        let sizeOptions = lgraph.getProperty(LayeredOptions.NODE_SIZE_OPTIONS) as? SizeOptions ?? []

        let calculatedSize = lgraph.getActualSize()
        let adjustedSize = KVector(calculatedSize)

        if sizeConstraint.contains(.minimumSize) {
            let minSize = lgraph.getProperty(LayeredOptions.NODE_SIZE_MINIMUM) as? KVector ?? KVector()

            if sizeOptions.contains(.defaultMinimumSize) {
                if minSize.x <= 0 {
                    minSize.x = ElkUtil.DEFAULT_MIN_WIDTH
                }
                if minSize.y <= 0 {
                    minSize.y = ElkUtil.DEFAULT_MIN_HEIGHT
                }
            }

            adjustedSize.x = max(calculatedSize.x, minSize.x)
            adjustedSize.y = max(calculatedSize.y, minSize.y)
        }

        resizeGraphNoReallyIMeanIt(lgraph, calculatedSize, adjustedSize)
    }

    private func resizeGraphNoReallyIMeanIt(_ lgraph: LGraph, _ oldSize: KVector, _ newSize: KVector) {
        let contentAlignment = lgraph.getProperty(LayeredOptions.CONTENT_ALIGNMENT) as? ContentAlignment ?? []

        // horizontal alignment
        if newSize.x > oldSize.x {
            if contentAlignment.contains(.hCenter) {
                lgraph.getOffset().x += (newSize.x - oldSize.x) / 2.0
            } else if contentAlignment.contains(.hRight) {
                lgraph.getOffset().x += newSize.x - oldSize.x
            }
        }

        // vertical alignment
        if newSize.y > oldSize.y {
            if contentAlignment.contains(.vCenter) {
                lgraph.getOffset().y += (newSize.y - oldSize.y) / 2.0
            } else if contentAlignment.contains(.vBottom) {
                lgraph.getOffset().y += newSize.y - oldSize.y
            }
        }

        // correct the position of eastern and southern hierarchical ports
        let graphProperties = lgraph.getProperty(InternalProperties.GRAPH_PROPERTIES) as? Set<GraphProperties> ?? []
        if graphProperties.contains(.EXTERNAL_PORTS)
            && (newSize.x > oldSize.x || newSize.y > oldSize.y) {

            for node in lgraph.layerlessNodes {
                if node.type == .externalPort {
                    let extPortSide = node.getProperty(InternalProperties.EXT_PORT_SIDE) as? PortSide
                    if extPortSide == .EAST {
                        node.getPosition().x += newSize.x - oldSize.x
                    } else if extPortSide == .SOUTH {
                        node.getPosition().y += newSize.y - oldSize.y
                    }
                }
            }
        }

        // Actually apply the new size
        let padding = lgraph.getPadding()
        lgraph.getSize().x = newSize.x - padding.left - padding.right
        lgraph.getSize().y = newSize.y - padding.top - padding.bottom
    }
}
