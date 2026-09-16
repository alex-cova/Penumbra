import Foundation

/// Calculates node sizes, places ports, and places node and port labels.
package final class org_eclipse_elk_alg_layered_intermediate_LabelAndNodeSizeProcessor {
    package init() {}

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        monitor.begin("Node and Port Label Placement and Node Sizing", 1)

        NodeDimensionCalculation.calculateLabelAndNodeSizes(LGraphAdapters.adapt(
            layeredGraph,
            transparentNorthSouthEdges: true,
            transparentCommentNodes: true,
            nodeFilter: { $0.type == .normal }))

        // If the graph has external ports, treat labels of external port dummies differently
        if let graphProps = layeredGraph.getProperty(InternalProperties.GRAPH_PROPERTIES) as? Set<GraphProperties>,
           graphProps.contains(.EXTERNAL_PORTS) {
            let portLabelPlacement: PortLabelPlacement = layeredGraph.getProperty(LayeredOptions.PORT_LABELS_PLACEMENT) as? PortLabelPlacement ?? []
            let placeNextToPort = portLabelPlacement.contains(.nextToPortIfPossible)
            let treatAsGroup: Bool = layeredGraph.getProperty(CoreOptions.PORT_LABELS_TREAT_AS_GROUP) as? Bool ?? true

            for layer in layeredGraph.getLayers() {
                for node in layer.getNodes() {
                    if node.type == .externalPort {
                        placeExternalPortDummyLabels(node, portLabelPlacement, placeNextToPort, treatAsGroup)
                    }
                }
            }
        }

        monitor.done()
    }

    /// Places the labels of the given external port dummy such that it results in correct
    /// node margins later on that will reserve enough space for the labels.
    private func placeExternalPortDummyLabels(_ dummy: LNode, _ graphPortLabelPlacement: PortLabelPlacement,
                                              _ placeNextToPortIfPossible: Bool, _ treatAsGroup: Bool) {

        let labelPortSpacingHorizontal: Double = dummy.getProperty(LayeredOptions.SPACING_LABEL_PORT_HORIZONTAL) ?? 0
        let labelPortSpacingVertical: Double = dummy.getProperty(LayeredOptions.SPACING_LABEL_PORT_VERTICAL) ?? 0
        let labelLabelSpacing: Double = dummy.getProperty(LayeredOptions.SPACING_LABEL_LABEL) ?? 0

        let dummySize = dummy.getSize()

        // External port dummies have exactly one port
        guard let dummyPort = dummy.getPorts().first else { return }
        let dummyPortPos = dummyPort.getPosition()

        guard let portLabelBox = computePortLabelBox(dummyPort, labelLabelSpacing) else { return }

        // Determine the position of the box
        if graphPortLabelPlacement.contains(.inside) {
            if let extPortSide: PortSide = dummy.getProperty(InternalProperties.EXT_PORT_SIDE) {
                switch extPortSide {
                case .NORTH:
                    portLabelBox.x = (dummySize.x - portLabelBox.width) / 2 - dummyPortPos.x
                    portLabelBox.y = labelPortSpacingVertical

                case .SOUTH:
                    portLabelBox.x = (dummySize.x - portLabelBox.width) / 2 - dummyPortPos.x
                    portLabelBox.y = -labelPortSpacingVertical - portLabelBox.height

                case .EAST:
                    if labelNextToPort(dummyPort, true, placeNextToPortIfPossible) {
                        let labelHeight = treatAsGroup
                            ? portLabelBox.height
                            : (dummyPort.getLabels().first?.getSize().y ?? 0)
                        portLabelBox.y = (dummySize.y - labelHeight) / 2 - dummyPortPos.y
                    } else {
                        portLabelBox.y = dummySize.y + labelPortSpacingVertical - dummyPortPos.y
                    }
                    portLabelBox.x = -labelPortSpacingHorizontal - portLabelBox.width

                case .WEST:
                    if labelNextToPort(dummyPort, true, placeNextToPortIfPossible) {
                        let labelHeight = treatAsGroup
                            ? portLabelBox.height
                            : (dummyPort.getLabels().first?.getSize().y ?? 0)
                        portLabelBox.y = (dummySize.y - labelHeight) / 2 - dummyPortPos.y
                    } else {
                        portLabelBox.y = dummySize.y + labelPortSpacingVertical - dummyPortPos.y
                    }
                    portLabelBox.x = labelPortSpacingHorizontal

                default:
                    break
                }
            }
        } else if graphPortLabelPlacement.contains(.outside) {
            if let extPortSide: PortSide = dummy.getProperty(InternalProperties.EXT_PORT_SIDE) {
                switch extPortSide {
                case .NORTH, .SOUTH:
                    portLabelBox.x = dummyPortPos.x + labelPortSpacingHorizontal

                case .EAST, .WEST:
                    if labelNextToPort(dummyPort, false, placeNextToPortIfPossible) {
                        let labelHeight = treatAsGroup
                            ? portLabelBox.height
                            : (dummyPort.getLabels().first?.getSize().y ?? 0)
                        portLabelBox.y = (dummySize.y - labelHeight) / 2 - dummyPortPos.y
                    } else {
                        portLabelBox.y = dummyPortPos.y + labelPortSpacingVertical
                    }

                default:
                    break
                }
            }
        }

        // Place the labels
        var currentY = portLabelBox.y
        for label in dummyPort.getLabels() {
            let labelPos = label.getPosition()
            labelPos.x = portLabelBox.x
            labelPos.y = currentY
            currentY += label.getSize().y + labelLabelSpacing
        }
    }

    /// Returns the amount of space required to place the labels later, or nil if there are no labels.
    private func computePortLabelBox(_ dummyPort: LPort, _ labelLabelSpacing: Double) -> ElkRectangle? {
        let labels = dummyPort.getLabels()
        if labels.isEmpty {
            return nil
        }

        let result = ElkRectangle()
        for label in labels {
            let labelSize = label.getSize()
            result.width = max(result.width, labelSize.x)
            result.height += labelSize.y
        }
        result.height += Double(labels.count - 1) * labelLabelSpacing
        return result
    }

    /// Checks whether the labels of the given port should be placed next to the port or below it.
    private func labelNextToPort(_ dummyPort: LPort, _ insideLabels: Bool, _ placeNextToPortIfPossible: Bool) -> Bool {
        if !placeNextToPortIfPossible {
            return false
        }
        if insideLabels {
            return dummyPort.getIncomingEdges().isEmpty && dummyPort.getOutgoingEdges().isEmpty
        } else {
            return !dummyPort.isConnectedToExternalNodes()
        }
    }
}
