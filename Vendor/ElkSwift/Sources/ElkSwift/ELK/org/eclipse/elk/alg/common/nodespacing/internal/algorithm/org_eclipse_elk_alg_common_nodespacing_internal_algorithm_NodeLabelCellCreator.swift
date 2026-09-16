/*******************************************************************************
 * Copyright (c) 2017, 2019 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 *******************************************************************************/

/**
 * Knows how to take all of a node's labels and create the appropriate grid cells.
 */
package final class NodeLabelCellCreator {

    private init() {}

    /**
     * Iterates over all of the node's labels and creates all required cell containers and label cells.
     */
    package static func createNodeLabelCells(_ nodeContext: NodeContext, _ onlyInside: Bool,
            _ horizontalLayoutMode: Bool) {
        createNodeLabelCellContainers(nodeContext, onlyInside)

        for label in nodeContext.node.getLabels() {
            handleNodeLabel(nodeContext, label, onlyInside, horizontalLayoutMode)
        }
    }

    /**
     * Handles the given node label by adding it to the corresponding node label cell.
     */
    package static func handleNodeLabel(_ nodeContext: NodeContext, _ label: LabelAdapter,
            _ onlyInside: Bool, _ horizontalLayoutMode: Bool) {

        // Find the effective label location
        let labelPlacement: NodeLabelPlacement
        if label.hasProperty(CoreOptions.NODE_LABELS_PLACEMENT) {
            labelPlacement = label.getProperty(CoreOptions.NODE_LABELS_PLACEMENT) ?? nodeContext.nodeLabelPlacement
        } else {
            labelPlacement = nodeContext.nodeLabelPlacement
        }
        let labelLocation = NodeLabelLocation.fromNodeLabelPlacement(labelPlacement)

        if labelLocation == .UNDEFINED {
            return
        }

        if onlyInside && !labelLocation.isInsideLocation() {
            return
        }

        retrieveNodeLabelCell(nodeContext, labelLocation, horizontalLayoutMode).addLabel(label)
    }


    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Cell Creation and Retrieval

    /**
     * Creates all node label containers.
     */
    package static func createNodeLabelCellContainers(_ nodeContext: NodeContext, _ onlyInside: Bool) {
        let symmetry = !nodeContext.sizeOptions.contains(.asymmetrical)
        let tabularNodeLabels = nodeContext.sizeOptions.contains(.forceTabularNodeLabels)

        // Inside container
        nodeContext.insideNodeLabelContainer = GridContainerCell(
                tabular: tabularNodeLabels, symmetrical: symmetry, gap: nodeContext.labelCellSpacing)

        nodeContext.insideNodeLabelContainer?.padding.copy(nodeContext.nodeLabelsPadding)
        nodeContext.nodeContainerMiddleRow.setCell(.center, cell: nodeContext.insideNodeLabelContainer)

        // Outside containers, if requested
        if !onlyInside {
            let northContainer = StripContainerCell(
                    mode: .HORIZONTAL, symmetrical: symmetry, gap: nodeContext.labelCellSpacing)
            northContainer.padding.bottom = nodeContext.nodeLabelSpacing
            nodeContext.outsideNodeLabelContainers[.NORTH] = northContainer

            let southContainer = StripContainerCell(
                    mode: .HORIZONTAL, symmetrical: symmetry, gap: nodeContext.labelCellSpacing)
            southContainer.padding.top = nodeContext.nodeLabelSpacing
            nodeContext.outsideNodeLabelContainers[.SOUTH] = southContainer

            let westContainer = StripContainerCell(
                    mode: .VERTICAL, symmetrical: symmetry, gap: nodeContext.labelCellSpacing)
            westContainer.padding.right = nodeContext.nodeLabelSpacing
            nodeContext.outsideNodeLabelContainers[.WEST] = westContainer

            let eastContainer = StripContainerCell(
                    mode: .VERTICAL, symmetrical: symmetry, gap: nodeContext.labelCellSpacing)
            eastContainer.padding.left = nodeContext.nodeLabelSpacing
            nodeContext.outsideNodeLabelContainers[.EAST] = eastContainer
        }
    }

    /**
     * Retrieves the node label cell for the given location. If it doesn't exist yet, it is created.
     */
    package static func retrieveNodeLabelCell(_ nodeContext: NodeContext,
            _ nodeLabelLocation: NodeLabelLocation, _ horizontalLayoutMode: Bool) -> LabelCell {

        if let existing = nodeContext.nodeLabelCells[nodeLabelLocation] {
            return existing
        }

        // The node label cell doesn't exist yet, so create one and add it to the relevant container
        let newLabelCell = LabelCell(gap: nodeContext.labelLabelSpacing, nodeLabelLocation: nodeLabelLocation, horizontalLayoutMode: horizontalLayoutMode)
        nodeContext.nodeLabelCells[nodeLabelLocation] = newLabelCell

        // Find the correct container and add the cell to it
        if nodeLabelLocation.isInsideLocation() {
            nodeContext.insideNodeLabelContainer?.setCell(
                    nodeLabelLocation.getContainerRow(),
                    nodeLabelLocation.getContainerColumn(),
                    newLabelCell)
        } else {
            let outsideSide = nodeLabelLocation.getOutsideSide()
            guard let containerCell = nodeContext.outsideNodeLabelContainers[outsideSide] else {
                assertionFailure("Expected container for side \(outsideSide)")
                return newLabelCell
            }

            switch outsideSide {
            case .NORTH, .SOUTH:
                newLabelCell.setContributesToMinimumHeight(true)
                containerCell.setCell(nodeLabelLocation.getContainerColumn(), cell: newLabelCell)

            case .WEST, .EAST:
                newLabelCell.setContributesToMinimumWidth(true)
                containerCell.setCell(nodeLabelLocation.getContainerRow(), cell: newLabelCell)
            default: break
            }
        }

        return newLabelCell
    }
}
