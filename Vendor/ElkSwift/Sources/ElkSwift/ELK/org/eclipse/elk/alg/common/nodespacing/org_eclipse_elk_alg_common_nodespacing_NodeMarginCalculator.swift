import Foundation

/**
 * Sets the node margins. Node margins are influenced by both port positions and sizes
 * and label positions and sizes.
 */
package final class NodeMarginCalculator {

    package var includeLabels = true
    package var includePorts = true
    package var includePortLabels = true
    package var includeEdgeHeadTailLabels = true

    package let adapter: GraphAdapter

    package init(_ adapter: GraphAdapter) {
        self.adapter = adapter
    }

    // MARK: - Configure

    @discardableResult
    package func excludeLabels() -> NodeMarginCalculator {
        self.includeLabels = false
        return self
    }

    @discardableResult
    package func excludePorts() -> NodeMarginCalculator {
        self.includePorts = false
        return self
    }

    @discardableResult
    package func excludePortLabels() -> NodeMarginCalculator {
        self.includePortLabels = false
        return self
    }

    @discardableResult
    package func excludeEdgeHeadTailLabels() -> NodeMarginCalculator {
        self.includeEdgeHeadTailLabels = false
        return self
    }

    // MARK: - Process

    package func process() {
        let spacing: Double = adapter.getProperty(CoreOptions.SPACING_LABEL_NODE) ?? 0.0

        for node in adapter.getNodes() {
            process(node: node, spacing: spacing)
        }
    }

    package func process(node: NodeAdapter) {
        let spacing: Double = adapter.getProperty(CoreOptions.SPACING_LABEL_NODE) ?? 0.0
        process(node: node, spacing: spacing)
    }

    package func process(node: NodeAdapter, spacing labelSpacing: Double) {
        let nodePos = node.getPosition()
        let nodeSize = node.getSize()

        let boundingBox = ElkRectangle(
            x: nodePos.x,
            y: nodePos.y,
            width: nodeSize.x,
            height: nodeSize.y
        )

        let elementBox = ElkRectangle()

        // Put the node's labels into the bounding box
        if includeLabels {
            for label in node.getLabels() {
                let labelPos = label.getPosition()
                let labelSize = label.getSize()
                elementBox.x = labelPos.x + nodePos.x
                elementBox.y = labelPos.y + nodePos.y
                elementBox.width = labelSize.x
                elementBox.height = labelSize.y
                boundingBox.union(elementBox)
            }
        }

        // Do the same for ports and their labels
        for port in node.getPorts() {
            let portPos = port.getPosition()
            let portSize = port.getSize()
            let portX = portPos.x + nodePos.x
            let portY = portPos.y + nodePos.y

            if includePorts {
                elementBox.x = portX
                elementBox.y = portY
                elementBox.width = portSize.x
                elementBox.height = portSize.y
                boundingBox.union(elementBox)
            }

            if includePortLabels {
                for label in port.getLabels() {
                    let labelPos = label.getPosition()
                    let labelSize = label.getSize()
                    elementBox.x = labelPos.x + portX
                    elementBox.y = labelPos.y + portY
                    elementBox.width = labelSize.x
                    elementBox.height = labelSize.y
                    boundingBox.union(elementBox)
                }
            }

            if includeEdgeHeadTailLabels {
                let requiredPortLabelSpace = KVector(x: -labelSpacing, y: -labelSpacing)

                let portLabelsPlacement: PortLabelPlacement = node.getProperty(CoreOptions.PORT_LABELS_PLACEMENT) ?? PortLabelPlacement()
                if portLabelsPlacement.contains(.outside) {
                    for label in port.getLabels() {
                        let labelSize = label.getSize()
                        requiredPortLabelSpace.x += labelSize.x + labelSpacing
                        requiredPortLabelSpace.y += labelSize.y + labelSpacing
                    }
                }

                requiredPortLabelSpace.x = max(requiredPortLabelSpace.x, 0.0)
                requiredPortLabelSpace.y = max(requiredPortLabelSpace.y, 0.0)

                processEdgeHeadTailLabels(
                    boundingBox,
                    outgoingEdges: port.getOutgoingEdges(),
                    incomingEdges: port.getIncomingEdges(),
                    node: node,
                    port: port,
                    portLabelSpace: requiredPortLabelSpace,
                    labelSpacing: labelSpacing
                )
            }
        }

        // Process end labels of edges directly connected to the node
        if includeEdgeHeadTailLabels {
            processEdgeHeadTailLabels(
                boundingBox,
                outgoingEdges: node.getOutgoingEdges(),
                incomingEdges: node.getIncomingEdges(),
                node: node,
                port: nil,
                portLabelSpace: nil,
                labelSpacing: labelSpacing
            )
        }

        // Reset the margin
        let margin = node.getMargin()
        margin.top = max(0, nodePos.y - boundingBox.y)
        margin.bottom = max(0, boundingBox.y + boundingBox.height - (nodePos.y + nodeSize.y))
        margin.left = max(0, nodePos.x - boundingBox.x)
        margin.right = max(0, boundingBox.x + boundingBox.width - (nodePos.x + nodeSize.x))
        node.setMargin(margin)
    }

    package func processEdgeHeadTailLabels(
        _ boundingBox: ElkRectangle,
        outgoingEdges: [EdgeAdapter],
        incomingEdges: [EdgeAdapter],
        node: NodeAdapter,
        port: PortAdapter?,
        portLabelSpace: KVector?,
        labelSpacing: Double
    ) {
        let labelBox = ElkRectangle()

        for edge in outgoingEdges {
            for label in edge.getLabels() {
                let placement: EdgeLabelPlacement? = label.getProperty(CoreOptions.EDGE_LABELS_PLACEMENT)
                if placement == .tail {
                    computeLabelBox(
                        labelBox,
                        label: label,
                        incomingEdge: false,
                        node: node,
                        port: port,
                        portLabelSpace: portLabelSpace,
                        labelSpacing: labelSpacing
                    )
                    boundingBox.union(labelBox)
                }
            }
        }

        for edge in incomingEdges {
            for label in edge.getLabels() {
                let placement: EdgeLabelPlacement? = label.getProperty(CoreOptions.EDGE_LABELS_PLACEMENT)
                if placement == .head {
                    computeLabelBox(
                        labelBox,
                        label: label,
                        incomingEdge: true,
                        node: node,
                        port: port,
                        portLabelSpace: portLabelSpace,
                        labelSpacing: labelSpacing
                    )
                    boundingBox.union(labelBox)
                }
            }
        }
    }

    package func computeLabelBox(
        _ labelBox: ElkRectangle,
        label: LabelAdapter,
        incomingEdge: Bool,
        node: NodeAdapter,
        port: PortAdapter?,
        portLabelSpace: KVector?,
        labelSpacing: Double
    ) {
        let nodePos = node.getPosition()
        let nodeSize = node.getSize()
        let labelSize = label.getSize()

        labelBox.x = nodePos.x
        labelBox.y = nodePos.y
        if let port = port {
            let portPos = port.getPosition()
            labelBox.x += portPos.x
            labelBox.y += portPos.y
        }

        labelBox.width = labelSize.x
        labelBox.height = labelSize.y

        if port == nil {
            if incomingEdge {
                labelBox.x -= labelSpacing + labelSize.x
            } else {
                labelBox.x += nodeSize.x + labelSpacing
            }
        } else if let port = port {
            let portSize = port.getSize()
            let portSide = port.getSide()
            switch portSide {
            case .UNDEFINED, .EAST:
                labelBox.x += portSize.x
                    + labelSpacing
                    + (portLabelSpace?.x ?? 0)
                    + labelSpacing

            case .WEST:
                labelBox.x -= labelSpacing
                    + (portLabelSpace?.x ?? 0)
                    + labelSpacing
                    + labelSize.x

            case .NORTH:
                labelBox.x += portSize.x
                    + labelSpacing
                labelBox.y -= labelSpacing
                    + (portLabelSpace?.y ?? 0)
                    + labelSpacing
                    + labelSize.y

            case .SOUTH:
                labelBox.x += portSize.x
                    + labelSpacing
                labelBox.y += portSize.y
                    + labelSpacing
                    + (portLabelSpace?.y ?? 0)
                    + labelSpacing
            }
        }
    }
}
