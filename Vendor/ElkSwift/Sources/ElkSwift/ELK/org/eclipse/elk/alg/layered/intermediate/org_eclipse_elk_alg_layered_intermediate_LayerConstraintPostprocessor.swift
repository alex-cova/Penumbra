import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_LayerConstraintPostprocessor {
    package init() {}

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("Layer constraint postprocessing", 1)

        let layers = layeredGraph.layers

        if !layers.isEmpty {
            let firstLayer = layers[0]
            let lastLayer = layers[layers.count - 1]

            let firstLabelLayer = Layer(layeredGraph)
            let lastLabelLayer = Layer(layeredGraph)

            moveFirstAndLastNodes(layeredGraph, firstLayer, lastLayer, firstLabelLayer, lastLabelLayer)

            if !firstLabelLayer.nodes.isEmpty {
                layeredGraph.layers.insert(firstLabelLayer, at: 0)
            }

            if !lastLabelLayer.nodes.isEmpty {
                layeredGraph.layers.append(lastLabelLayer)
            }
        }

        if layeredGraph.hasProperty(InternalProperties.HIDDEN_NODES) {
            let firstSeparateLayer = Layer(layeredGraph)
            let lastSeparateLayer = Layer(layeredGraph)

            restoreHiddenNodes(layeredGraph, firstSeparateLayer, lastSeparateLayer)

            if !firstSeparateLayer.nodes.isEmpty {
                layeredGraph.layers.insert(firstSeparateLayer, at: 0)
            }

            if !lastSeparateLayer.nodes.isEmpty {
                layeredGraph.layers.append(lastSeparateLayer)
            }
        }

        monitor.done()
    }

    private func moveFirstAndLastNodes(_ layeredGraph: LGraph, _ firstLayer: Layer, _ lastLayer: Layer,
                                         _ firstLabelLayer: Layer, _ lastLabelLayer: Layer) {
        for layer in layeredGraph.layers {
            let nodes = LGraphUtil.toNodeArray(layer.nodes)

            for node in nodes {
                let constraint = node.getProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT) as? LayerConstraint ?? .NONE

                switch constraint {
                case .FIRST:
                    throwUpUnlessNoIncomingEdges(node)
                    node.setLayer(firstLayer)
                    moveLabelsToLabelLayer(node, true, firstLabelLayer)
                case .LAST:
                    throwUpUnlessNoOutgoingEdges(node)
                    node.setLayer(lastLayer)
                    moveLabelsToLabelLayer(node, false, lastLabelLayer)
                default:
                    break
                }
            }
        }

        // Remove empty layers
        layeredGraph.layers.removeAll { $0.nodes.isEmpty }
    }

    private func moveLabelsToLabelLayer(_ node: LNode, _ incoming: Bool, _ labelLayer: Layer) {
        let edges = incoming ? node.getIncomingEdges() : node.getOutgoingEdges()
        for edge in edges {
            guard let possibleLabelDummy = incoming ? edge.source?.node : edge.target?.node else { continue }
            if possibleLabelDummy.type == .label {
                possibleLabelDummy.setLayer(labelLayer)
            }
        }
    }

    private func restoreHiddenNodes(_ layeredGraph: LGraph, _ firstSeparateLayer: Layer, _ lastSeparateLayer: Layer) {
        guard let hiddenNodes = layeredGraph.getProperty(InternalProperties.HIDDEN_NODES) as? [LNode] else { return }

        for hiddenNode in hiddenNodes {
            let constraint = hiddenNode.getProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT) as? LayerConstraint ?? .NONE

            switch constraint {
            case .FIRST_SEPARATE:
                hiddenNode.setLayer(firstSeparateLayer)
            case .LAST_SEPARATE:
                hiddenNode.setLayer(lastSeparateLayer)
            default:
                break
            }

            for hiddenEdge in hiddenNode.getConnectedEdges() {
                if hiddenEdge.source != nil && hiddenEdge.target != nil {
                    continue
                }

                let isOutgoing = hiddenEdge.target == nil

                let originalOppositePort = hiddenEdge.getProperty(InternalProperties.ORIGINAL_OPPOSITE_PORT) as? LPort
                if isOutgoing {
                    hiddenEdge.setTarget(originalOppositePort)
                } else {
                    hiddenEdge.setSource(originalOppositePort)
                }
            }
        }
    }

    private func throwUpUnlessNoIncomingEdges(_ node: LNode) {
        for incoming in node.getIncomingEdges() {
            if incoming.source?.node?.type != .label {
                return
            }
        }
    }

    private func throwUpUnlessNoOutgoingEdges(_ node: LNode) {
        for outgoing in node.getOutgoingEdges() {
            if outgoing.target?.node?.type != .label {
                return
            }
        }
    }
}
