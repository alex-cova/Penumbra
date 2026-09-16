import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_LabelDummyInserter {
    package init() {}

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("Label dummy insertions", 1)

        var newDummyNodes = [LNode]()

        let edgeLabelSpacing = layeredGraph.getProperty(LayeredOptions.SPACING_EDGE_LABEL) as? Double ?? 0.0
        let labelLabelSpacing = layeredGraph.getProperty(LayeredOptions.SPACING_LABEL_LABEL) as? Double ?? 0.0
        let layoutDirection = layeredGraph.getProperty(LayeredOptions.DIRECTION) as? Direction ?? .UNDEFINED

        for node in layeredGraph.layerlessNodes {
            for edge in node.getOutgoingEdges() {
                if edgeNeedsToBeProcessed(edge) {
                    let thickness = retrieveThickness(edge)

                    var representedLabels = [LLabel]()
                    let dummyNode = createLabelDummy(layeredGraph, edge, thickness, &representedLabels)
                    newDummyNodes.append(dummyNode)

                    let dummySize = dummyNode.size

                    var i = 0
                    while i < edge.labels.count {
                        let label = edge.labels[i]

                        if (label.getProperty(LayeredOptions.EDGE_LABELS_PLACEMENT) as? EdgeLabelPlacement) == .center {
                            if layoutDirection.isVertical() {
                                dummySize.x += label.size.x + labelLabelSpacing
                                dummySize.y = max(dummySize.y, label.size.y)
                            } else {
                                dummySize.x = max(dummySize.x, label.size.x)
                                dummySize.y += label.size.y + labelLabelSpacing
                            }

                            representedLabels.append(label)
                            edge.labels.remove(at: i)
                        } else {
                            i += 1
                        }
                    }

                    // Update the property with the filled list
                    dummyNode.setProperty(InternalProperties.REPRESENTED_LABELS, value: representedLabels)

                    if layoutDirection.isVertical() {
                        dummySize.x -= labelLabelSpacing
                        dummySize.y += edgeLabelSpacing + thickness
                    } else {
                        dummySize.y += edgeLabelSpacing - labelLabelSpacing + thickness
                    }
                }
            }
        }

        layeredGraph.layerlessNodes.append(contentsOf: newDummyNodes)

        monitor.done()
    }

    private func edgeNeedsToBeProcessed(_ edge: LEdge) -> Bool {
        guard edge.source?.node !== edge.target?.node else { return false }
        return edge.labels.contains { label in
            (label.getProperty(LayeredOptions.EDGE_LABELS_PLACEMENT) as? EdgeLabelPlacement) == .center
        }
    }

    private func retrieveThickness(_ edge: LEdge) -> Double {
        var thickness = edge.getProperty(LayeredOptions.EDGE_THICKNESS) as? Double ?? 0.0
        if thickness < 0 {
            thickness = 0
            edge.setProperty(LayeredOptions.EDGE_THICKNESS, value: thickness)
        }
        return thickness
    }

    private func createLabelDummy(_ layeredGraph: LGraph, _ edge: LEdge, _ thickness: Double,
                                    _ representedLabels: inout [LLabel]) -> LNode {
        let dummyNode = LNode(layeredGraph)
        dummyNode.type = .label
        dummyNode.setProperty(InternalProperties.ORIGIN, value: edge)
        dummyNode.setProperty(InternalProperties.REPRESENTED_LABELS, value: representedLabels)
        dummyNode.setProperty(LayeredOptions.PORT_CONSTRAINTS, value: PortConstraints.FIXED_POS)
        guard let src = edge.source, let tgt = edge.target else { return dummyNode }
        dummyNode.setProperty(InternalProperties.LONG_EDGE_SOURCE, value: src)
        dummyNode.setProperty(InternalProperties.LONG_EDGE_TARGET, value: tgt)

        LongEdgeSplitter.splitEdge(edge, dummyNode)

        let portPos = floor(thickness / 2)
        for dummyPort in dummyNode.ports {
            dummyPort.position.y = portPos
        }

        return dummyNode
    }
}
