import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_LayerConstraintPreprocessor {
    package init() {}

    private enum HiddenNodeConnections {
        case NONE
        case FIRST_SEPARATE
        case LAST_SEPARATE
        case BOTH

        func combine(_ layerConstraint: LayerConstraint) -> HiddenNodeConnections {
            switch self {
            case .NONE:
                return layerConstraint == .FIRST_SEPARATE ? .FIRST_SEPARATE : .LAST_SEPARATE
            case .FIRST_SEPARATE:
                return layerConstraint == .FIRST_SEPARATE ? .FIRST_SEPARATE : .BOTH
            case .LAST_SEPARATE:
                return layerConstraint == .FIRST_SEPARATE ? .BOTH : .LAST_SEPARATE
            case .BOTH:
                return .BOTH
            }
        }
    }

    private static let HIDDEN_NODE_CONNECTIONS = Property<Any>("separateLayerConnections")

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("Layer constraint preprocessing", 1)

        var hiddenNodes = [LNode]()

        var i = 0
        while i < layeredGraph.layerlessNodes.count {
            let lNode = layeredGraph.layerlessNodes[i]

            if isRelevantNode(lNode) {
                hide(lNode)
                hiddenNodes.append(lNode)
                layeredGraph.layerlessNodes.remove(at: i)
            } else {
                i += 1
            }
        }

        if !hiddenNodes.isEmpty {
            layeredGraph.setProperty(InternalProperties.HIDDEN_NODES, value: hiddenNodes)
        }

        monitor.done()
    }

    private func isRelevantNode(_ lNode: LNode) -> Bool {
        let constraint = lNode.getProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT) as? LayerConstraint ?? .NONE
        return constraint == .FIRST_SEPARATE || constraint == .LAST_SEPARATE
    }

    private func hide(_ lNode: LNode) {
        ensureNoInacceptableEdges(lNode)
        for lEdge in lNode.getConnectedEdges() {
            hideEdge(lNode, lEdge)
        }
    }

    private func hideEdge(_ lNode: LNode, _ lEdge: LEdge) {
        let isOutgoing = lEdge.source?.node === lNode
        guard let oppositePort = isOutgoing ? lEdge.target : lEdge.source else { return }

        if isOutgoing {
            lEdge.setTarget(nil)
        } else {
            lEdge.setSource(nil)
        }

        lEdge.setProperty(InternalProperties.ORIGINAL_OPPOSITE_PORT, value: oppositePort)

        if let oppositeNode = oppositePort.node {
            updateOppositeNodeLayerConstraints(lNode, oppositeNode)
        }
    }

    private func updateOppositeNodeLayerConstraints(_ hiddenNode: LNode, _ oppositeNode: LNode) {
        if oppositeNode.hasProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT) {
            return
        }

        let hiddenConstraint = hiddenNode.getProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT) as? LayerConstraint ?? .NONE
        let current = oppositeNode.getProperty(
            org_eclipse_elk_alg_layered_intermediate_LayerConstraintPreprocessor.HIDDEN_NODE_CONNECTIONS
        ) as? HiddenNodeConnections ?? .NONE
        let connections = current.combine(hiddenConstraint)
        oppositeNode.setProperty(
            org_eclipse_elk_alg_layered_intermediate_LayerConstraintPreprocessor.HIDDEN_NODE_CONNECTIONS,
            value: connections
        )

        if oppositeNode.getConnectedEdges().first != nil {
            return
        }

        switch connections {
        case .FIRST_SEPARATE:
            oppositeNode.setProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT, value: LayerConstraint.FIRST)
        case .LAST_SEPARATE:
            oppositeNode.setProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT, value: LayerConstraint.LAST)
        default:
            break
        }
    }

    private func ensureNoInacceptableEdges(_ lNode: LNode) {
        let layerConstraint = lNode.getProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT) as? LayerConstraint ?? .NONE

        if layerConstraint == .FIRST_SEPARATE {
            for inEdge in lNode.getIncomingEdges() {
                if !isAcceptableIncidentEdge(inEdge) {
                    // In Java this throws UnsupportedConfigurationException; we just print a warning
                    return
                }
            }
        } else if layerConstraint == .LAST_SEPARATE {
            for outEdge in lNode.getOutgoingEdges() {
                if !isAcceptableIncidentEdge(outEdge) {
                    return
                }
            }
        }
    }

    private func isAcceptableIncidentEdge(_ edge: LEdge) -> Bool {
        guard let sourceNode = edge.source?.node,
              let targetNode = edge.target?.node else {
            return false
        }
        return sourceNode.type == .externalPort && targetNode.type == .externalPort
    }
}
