// Copyright (c) 2012, 2020 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

import Foundation

// MARK: - Actual Transpiled Code

package class EndLabelPreprocessor {

    package init() {}

    package func process(_ layeredGraph: LGraph, monitor: IElkProgressMonitor) {
        _ = monitor.begin("End label pre-processing", 1)

        let edgeLabelSpacing: Double = layeredGraph.getProperty(LayeredOptions.SPACING_EDGE_LABEL) as? Double ?? 0.0
        let labelLabelSpacing: Double = layeredGraph.getProperty(LayeredOptions.SPACING_LABEL_LABEL) as? Double ?? 0.0
        let direction = layeredGraph.getProperty(LayeredOptions.DIRECTION) as? Direction ?? .UNDEFINED
        let verticalLayout = direction.isVertical()

        // We iterate over each node and place the end labels of its incident edges
        let nodes = layeredGraph.layers.flatMap { $0.nodes }
        for node in nodes {
            processNode(node, edgeLabelSpacing: edgeLabelSpacing, labelLabelSpacing: labelLabelSpacing, verticalLayout: verticalLayout)
        }

        monitor.done()
    }

    package func processNode(_ node: LNode, edgeLabelSpacing: Double, labelLabelSpacing: Double, verticalLayout: Bool) {
        // Iterate over all ports and collect their labels in label cells
        let portCount = node.ports.count
        var portLabelCells: [LabelCell?] = Array(repeating: nil, count: portCount)

        for portIndex in 0..<portCount {
            let port = node.ports[portIndex]
            port.id = portIndex

            portLabelCells[portIndex] = createConfiguredLabelCell(
                EndLabelPreprocessor.gatherLabels(port: port), labelLabelSpacing: labelLabelSpacing, verticalLayout: verticalLayout)
        }

        // Actually go off and place them labels!
        placeLabels(node: node, portLabelCells: portLabelCells, labelLabelSpacing: labelLabelSpacing, edgeLabelSpacing: edgeLabelSpacing, verticalLayout: verticalLayout)

        // Turn the array into a map and save that in the node
        var portToLabelCellMap: [LPort: LabelCell] = [:]
        for index in 0..<portLabelCells.count {
            if let labelCell = portLabelCells[index] {
                portToLabelCellMap[node.ports[index]] = labelCell
            }
        }

        if !portToLabelCellMap.isEmpty {
            node.setProperty(InternalProperties.END_LABELS, portToLabelCellMap)

            // Update the node's margins
            updateNodeMargins(node: node, labelCells: portLabelCells)
        }
    }

    /**
     * Creates label cell for the given port with the given labels, if any.
     */
    package func createConfiguredLabelCell(_ labels: [LLabel]?, labelLabelSpacing: Double, verticalLayout: Bool) -> LabelCell? {

        guard let labels = labels, !labels.isEmpty else {
            return nil
        }

        // Create the new label cell and setup its alignments depending on the port's side
        let labelCell = LabelCell(gap: labelLabelSpacing, horizontalLayoutMode: !verticalLayout)

        for label in labels {
            labelCell.addLabel(LGraphAdapters.adapt(label))
        }

        // Setup the label cell's size
        let labelCellRect = labelCell.getCellRectangle()
        labelCellRect.height = labelCell.getMinimumHeight()
        labelCellRect.width = labelCell.getMinimumWidth()

        return labelCell
    }

    // MARK: - Label Gathering

    package static let NO_INCIDENT_EDGE_THICKNESS: Double = -1

    /**
     * Returns a list that contains all end labels to be placed at the given port.
     */
    package static func gatherLabels(port: LPort) -> [LLabel]? {
        var labels: [LLabel] = []

        // Gather labels of the port itself
        var maxEdgeThickness = gatherLabels(port: port, targetList: &labels)

        // If it has a dummy associated with it, go through the dummy's ports
        if let dummyNode = port.getProperty(InternalProperties.PORT_DUMMY) as? LNode {
            for dummyPort in dummyNode.ports {
                if let origin = dummyPort.getProperty(InternalProperties.ORIGIN) as? LPort, origin === port {
                    maxEdgeThickness = max(
                        maxEdgeThickness,
                        gatherLabels(port: dummyPort, targetList: &labels)
                    )
                }
            }
        }

        // Only save the maximum edge thickness if we'll be interested in it later
        if !labels.isEmpty {
            port.setProperty(InternalProperties.MAX_EDGE_THICKNESS, maxEdgeThickness)
        }

        return maxEdgeThickness != NO_INCIDENT_EDGE_THICKNESS ? labels : nil
    }

    /**
     * Puts all relevant end labels of edges connected to the given port into the given list.
     */
    package static func gatherLabels(port: LPort, targetList: inout [LLabel]) -> Double {
        var maxEdgeThickness: Double = -1

        for incidentEdge in port.getConnectedEdges() {
            let thickness: Double = incidentEdge.getProperty(LayeredOptions.EDGE_THICKNESS) as? Double ?? 0.0
            maxEdgeThickness = max(maxEdgeThickness, thickness)

            if incidentEdge.source === port {
                // It's an outgoing edge; all tail labels belong to this port
                let edgeLabels = incidentEdge.labels.filter { label in
                    (label.getProperty(LayeredOptions.EDGE_LABELS_PLACEMENT) as? EdgeLabelPlacement) == EdgeLabelPlacement.tail
                }
                targetList.append(contentsOf: edgeLabels)

                for label in edgeLabels {
                    if !label.hasProperty(InternalProperties.END_LABEL_EDGE) {
                        label.setProperty(InternalProperties.END_LABEL_EDGE, incidentEdge)
                    }
                }
            } else {
                // It's an incoming edge; all head labels belong to this port
                let edgeLabels = incidentEdge.labels.filter { label in
                    (label.getProperty(LayeredOptions.EDGE_LABELS_PLACEMENT) as? EdgeLabelPlacement) == EdgeLabelPlacement.head
                }
                targetList.append(contentsOf: edgeLabels)

                for label in edgeLabels {
                    if !label.hasProperty(InternalProperties.END_LABEL_EDGE) {
                        label.setProperty(InternalProperties.END_LABEL_EDGE, incidentEdge)
                    }
                }
            }
        }

        return maxEdgeThickness
    }

    // MARK: - Label Placement

    /**
     * Places end labels of all of the node's ports.
     */
    package func placeLabels(node: LNode, portLabelCells: [LabelCell?], labelLabelSpacing: Double, edgeLabelSpacing: Double, verticalLayout: Bool) {
        for port in node.ports {
            if let labelCell = portLabelCells[port.id] {
                placeLabels(port: port, labelCell: labelCell, edgeLabelSpacing: edgeLabelSpacing)
            }
        }
    }

    /**
     * Places the edge end labels that are to be placed near the given port.
     */
    package func placeLabels(port: LPort, labelCell: LabelCell, edgeLabelSpacing: Double) {
        // Some necessary position information
        let labelCellRect = labelCell.getCellRectangle()
        guard let ownerNode = port.node else { return }
        let nodeSize = ownerNode.size
        let nodeMargin = ownerNode.margin
        let portPos = port.position
        let portAnchor = KVector.sum(portPos, port.anchor)

        // Calculate cell position depending on port side
        switch port.side {
        case .NORTH:
            labelCell.setVerticalAlignment(.bottom)
            labelCellRect.y = -nodeMargin.top
                - edgeLabelSpacing
                - labelCellRect.height

            if getLabelSide(labelCell) == .ABOVE {
                labelCell.setHorizontalAlignment(.right)
                labelCellRect.x = portAnchor.x
                    - maxEdgeThickness(port: port)
                    - edgeLabelSpacing
                    - labelCellRect.width
            } else {
                labelCell.setHorizontalAlignment(.left)
                labelCellRect.x = portAnchor.x
                    + maxEdgeThickness(port: port)
                    + edgeLabelSpacing
            }

        case .EAST:
            labelCell.setHorizontalAlignment(.left)
            labelCellRect.x = nodeSize.x
                + nodeMargin.right
                + edgeLabelSpacing

            if getLabelSide(labelCell) == .ABOVE {
                labelCell.setVerticalAlignment(.bottom)
                labelCellRect.y = portAnchor.y
                    - maxEdgeThickness(port: port)
                    - edgeLabelSpacing
                    - labelCellRect.height
            } else {
                labelCell.setVerticalAlignment(.top)
                labelCellRect.y = portAnchor.y
                    + maxEdgeThickness(port: port)
                    + edgeLabelSpacing
            }

        case .SOUTH:
            labelCell.setVerticalAlignment(.top)
            labelCellRect.y = nodeSize.y
                + nodeMargin.bottom
                + edgeLabelSpacing

            if getLabelSide(labelCell) == .ABOVE {
                labelCell.setHorizontalAlignment(.right)
                labelCellRect.x = portAnchor.x
                    - maxEdgeThickness(port: port)
                    - edgeLabelSpacing
                    - labelCellRect.width
            } else {
                labelCell.setHorizontalAlignment(.left)
                labelCellRect.x = portAnchor.x
                    + maxEdgeThickness(port: port)
                    + edgeLabelSpacing
            }

        case .WEST:
            labelCell.setHorizontalAlignment(.right)
            labelCellRect.x = -nodeMargin.left
                - edgeLabelSpacing
                - labelCellRect.width

            if getLabelSide(labelCell) == .ABOVE {
                labelCell.setVerticalAlignment(.bottom)
                labelCellRect.y = portAnchor.y
                    - maxEdgeThickness(port: port)
                    - edgeLabelSpacing
                    - labelCellRect.height
            } else {
                labelCell.setVerticalAlignment(.top)
                labelCellRect.y = portAnchor.y
                    + maxEdgeThickness(port: port)
                    + edgeLabelSpacing
            }

        case .UNDEFINED: break
        }
    }

    // MARK: - Node Margins

    /**
     * Updates the node's margins to account for its end labels.
     */
    package func updateNodeMargins(node: LNode, labelCells: [LabelCell?]) {
        let nodeMargin = node.margin
        let nodeSize = node.size

        // Calculate the rectangle that describes the node's current margin
        let nodeMarginRectangle = ElkRectangle(
            x: -nodeMargin.left,
            y: -nodeMargin.top,
            width: nodeMargin.left + nodeSize.x + nodeMargin.right,
            height: nodeMargin.top + nodeSize.y + nodeMargin.bottom
        )

        // Union the rectangle with each rectangle that describes a label cell
        for labelCell in labelCells {
            if let labelCell = labelCell {
                nodeMarginRectangle.union(labelCell.getCellRectangle())
            }
        }

        // Reapply the new rectangle to the margin
        nodeMargin.left = -nodeMarginRectangle.x
        nodeMargin.top = -nodeMarginRectangle.y
        nodeMargin.right = nodeMarginRectangle.width - nodeMargin.left - nodeSize.x
        nodeMargin.bottom = nodeMarginRectangle.height - nodeMargin.top - nodeSize.y
    }

    // MARK: - Utility Methods

    /**
     * Retrieve the side of the edge the labels of the given cell should be placed at.
     */
    package func getLabelSide(_ labelCell: LabelCell) -> LabelSide {
        assert(labelCell.hasLabels())

        guard let firstLabel = labelCell.getLabels().first else { return .ABOVE }
        let sideValue: LabelSide? = firstLabel.getProperty(InternalProperties.LABEL_SIDE)
        return sideValue ?? .ABOVE
    }

    /**
     * Returns the maximum thickness of all edges incident to the port.
     */
    package func maxEdgeThickness(port: LPort) -> Double {
        return port.getProperty(InternalProperties.MAX_EDGE_THICKNESS) as? Double ?? 0.0
    }

    /**
     * Returns the overlap removal direction appropriate for the given port side.
     */
    package func portSideToOverlapRemovalDirection(_ portSide: PortSide) -> RectangleStripOverlapRemover.OverlapRemovalDirection {
        switch portSide {
        case .NORTH:
            return .up
        case .SOUTH:
            return .down
        case .EAST:
            return .right
        case .WEST:
            return .left
        case .UNDEFINED:
            return .down
        }
    }
}
