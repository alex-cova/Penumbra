/*******************************************************************************
 * Copyright (c) 2012, 2022 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 *******************************************************************************/



/**
 * After the EndLabelPreprocessor has done all the major work for us, each node may have a list of label
 * cells full of edge end labels associated with it, along with proper label cell coordinates.
 *
 * <dl>
 *   <dt>Precondition:</dt>
 *     <dd>a layered graph</dd>
 *   <dt>Postcondition:</dt>
 *     <dd>end labels have proper coordinates assigned to them</dd>
 *   <dt>Slots:</dt>
 *     <dd>After phase 5.</dd>
 * </dl>
 */
package final class EndLabelPostprocessor: ILayoutProcessor {

    package typealias G = LGraph

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("End label post-processing", 1)

        // We iterate over each node's label cells and offset and place them
        let nodes = layeredGraph.layers.flatMap { $0.nodes }
        let filteredNodes = nodes.filter { node in
            (node.type == .normal || node.type == .externalPort) && node.hasProperty(InternalProperties.END_LABELS)
        }
        filteredNodes.forEach { node in
            self.processNode(node)
        }

        monitor.done()
    }

    package func processNode(_ node: LNode) {
        assert(node.hasProperty(InternalProperties.END_LABELS))

        // The node should have a non-empty list of label cells, or something went TERRIBLY WRONG!!!
        guard let endLabelCells = node.getProperty(InternalProperties.END_LABELS) as? [LPort: LabelCell], !endLabelCells.isEmpty else {
            return
        }

        let nodePos = node.position

        for labelCell in endLabelCells.values {
            var labelCellRect = labelCell.cellRectangle
            labelCellRect.move(by: nodePos)

            labelCell.applyLabelLayout()
        }

        // Remove label cells
        node.setProperty(InternalProperties.END_LABELS, value: nil)
    }

}
