import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_LabelDummyRemover {
    package init() {}

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("Label dummy removal", 1)

        let edgeLabelSpacing = layeredGraph.getProperty(LayeredOptions.SPACING_EDGE_LABEL) as? Double ?? 0.0
        let labelLabelSpacing = layeredGraph.getProperty(LayeredOptions.SPACING_LABEL_LABEL) as? Double ?? 0.0
        let layoutDirection = layeredGraph.getProperty(LayeredOptions.DIRECTION) as? Direction ?? .UNDEFINED

        for layer in layeredGraph.layers {
            var i = 0
            while i < layer.nodes.count {
                let node = layer.nodes[i]

                if node.type == .label {
                    guard let originEdge = node.getProperty(InternalProperties.ORIGIN) as? LEdge else { i += 1; continue }
                    let thickness = originEdge.getProperty(LayeredOptions.EDGE_THICKNESS) as? Double ?? 0.0
                    let labelsBelowEdge = (node.getProperty(InternalProperties.LABEL_SIDE) as? LabelSide) == .BELOW

                    let currLabelPos = KVector(node.position)

                    if labelsBelowEdge {
                        currLabelPos.y += thickness + edgeLabelSpacing
                    }

                    let labelSpace = KVector(
                        node.size.x,
                        node.size.y + (node.isInlineEdgeLabel() ? 0 : -thickness - edgeLabelSpacing)
                    )

                    let representedLabels = node.getProperty(InternalProperties.REPRESENTED_LABELS) as? [LLabel] ?? []

                    if layoutDirection.isVertical() {
                        placeLabelsForVerticalLayout(
                            representedLabels, currLabelPos, labelLabelSpacing, labelSpace,
                            labelsBelowEdge, layoutDirection)
                    } else {
                        placeLabelsForHorizontalLayout(
                            representedLabels, currLabelPos, labelLabelSpacing, labelSpace)
                    }

                    originEdge.labels.append(contentsOf: representedLabels)

                    let edgeRouting = layeredGraph.getProperty(LayeredOptions.EDGE_ROUTING) as? EdgeRouting
                    LongEdgeJoiner.joinAt(node, edgeRouting == .POLYLINE)

                    layer.nodes.remove(at: i)
                } else {
                    i += 1
                }
            }
        }

        monitor.done()
    }

    private func placeLabelsForHorizontalLayout(_ labels: [LLabel], _ labelPos: KVector,
                                                  _ labelSpacing: Double, _ labelSpace: KVector) {
        for label in labels {
            label.position.x = labelPos.x + (labelSpace.x - label.size.x) / 2.0
            label.position.y = labelPos.y
            labelPos.y += label.size.y + labelSpacing
        }
    }

    private func placeLabelsForVerticalLayout(_ labels: [LLabel], _ labelPos: KVector,
                                                _ labelSpacing: Double, _ labelSpace: KVector,
                                                _ leftAligned: Bool, _ layoutDirection: Direction) {
        let inline = labels.allSatisfy { $0.getProperty(LayeredOptions.EDGE_LABELS_INLINE) as? Bool ?? false }

        var effectiveLabels = labels
        if layoutDirection == .UP {
            effectiveLabels = effectiveLabels.reversed()
        }

        for label in effectiveLabels {
            label.position.x = labelPos.x

            if inline {
                label.position.y = labelPos.y + (labelSpace.y - label.size.y) / 2
            } else if leftAligned {
                label.position.y = labelPos.y
            } else {
                label.position.y = labelPos.y + labelSpace.y - label.size.y
            }

            labelPos.x += label.size.x + labelSpacing
        }
    }
}
