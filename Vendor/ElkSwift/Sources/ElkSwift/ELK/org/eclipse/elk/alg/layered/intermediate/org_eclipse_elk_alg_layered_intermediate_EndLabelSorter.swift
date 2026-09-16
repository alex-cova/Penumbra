import Foundation

/**
 * Copyright (c) 2020 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 ******************************************************************************/

// MARK: - EndLabelSorter

package final class EndLabelSorter: ILayoutProcessor {

    package typealias G = LGraph

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("Sort end labels", 1)

        let normalNodes = layeredGraph.layers.flatMap { $0.nodes }.filter { $0.type == .normal }
        normalNodes.forEach { processNode($0) }

        monitor.done()
    }

    // MARK: - Node Processing and Initialization

    package func processNode(_ node: LNode) {
        var initializeMethodCalled = false

        guard let labelCellMap = node.getProperty(InternalProperties.END_LABELS) as? [LPort: LabelCell] else { return }

        for port in node.ports {
            if needsSorting(port) {
                if !initializeMethodCalled {
                    if let graph = node.graph {
                        initialize(graph)
                    }
                    initializeMethodCalled = true
                }

                if let portLabelCell = labelCellMap[port] {
                    sort(port: port, portLabelCell: portLabelCell)
                }
            }
        }
    }

    /**
     * A port requires its end labels to be sorted if there are end labels of at least two edges there.
     */
    package func needsSorting(_ port: LPort) -> Bool {
        var edgesWithEndLabels = 0

        for inEdge in port.incomingEdges {
            let hasHeadLabels = inEdge.labels.contains(where: { (label: LLabel) -> Bool in
                label.getProperty(LayeredOptions.EDGE_LABELS_PLACEMENT) as? EdgeLabelPlacement == EdgeLabelPlacement.head
            })
            if hasHeadLabels {
                edgesWithEndLabels += 1
            }
        }

        for outEdge in port.outgoingEdges {
            let hasTailLabels = outEdge.labels.contains(where: { (label: LLabel) -> Bool in
                label.getProperty(LayeredOptions.EDGE_LABELS_PLACEMENT) as? EdgeLabelPlacement == EdgeLabelPlacement.tail
            })
            if hasTailLabels {
                edgesWithEndLabels += 1
            }
        }

        return edgesWithEndLabels >= 2
    }

    /**
     * Called once we find the first instance of labels that have to be sorted. This method initializes everything.
     */
    package func initialize(_ lGraph: LGraph) {
        var nextElementID = 0
        for layer in lGraph {
            for node in layer.nodes {
                node.id = nextElementID
                nextElementID += 1

                for port in node.ports {
                    port.id = nextElementID
                    nextElementID += 1
                }
            }
        }
    }

    // MARK: - Sorting

    /**
     * Sorts the labels of the given port which are contained in the given label cell.
     */
    package func sort(port: LPort, portLabelCell: LabelCell) {
        let labelGroups = createLabelGroups(portLabelCell)
        let sortedGroups = labelGroups.sorted(by: EndLabelSorter.LABEL_GROUP_COMPARATOR)

        // Re-add the label cell's labels in the proper order
        var portLabelCellLabels = portLabelCell.labels
        portLabelCellLabels.removeAll()
        for group in sortedGroups {
            portLabelCellLabels.append(contentsOf: group.labels)
        }
        portLabelCell.labels = portLabelCellLabels
    }


    /**
     * Creates a list of LabelGroup that group labels from the same edge.
     */
    package func createLabelGroups(_ portLabelCell: LabelCell) -> [LabelGroup] {
        var edgeToGroupMap = [LEdge: LabelGroup]()

        // Make sure every label is contained in a label group
        for label in portLabelCell.labels {
            let optEdge: LEdge? = label.getProperty(InternalProperties.END_LABEL_EDGE)
            guard let edge = optEdge else { continue }

            if edgeToGroupMap[edge] == nil {
                edgeToGroupMap[edge] = LabelGroup(edge)
            }

            edgeToGroupMap[edge]?.labels.append(label)
        }

        return Array(edgeToGroupMap.values)
    }

    // MARK: - LabelGroup

    /**
     * A group of labels that have a certain order and belong to a single edge.
     */
    package class LabelGroup {

        /** The edge the labels belong to. */
        package let edge: LEdge
        /** List of labels that belong to this group. */
        var labels: [LabelAdapter]

        init(_ edge: LEdge) {
            self.edge = edge
            self.labels = []
        }

    }

    package static let LABEL_GROUP_COMPARATOR: (LabelGroup, LabelGroup) -> Bool = { group1, group2 in
        let source1 = group1.edge.source
        let source2 = group2.edge.source
        let sourcePortDiff = (source1?.id ?? 0) - (source2?.id ?? 0)
        if sourcePortDiff != 0 {
            return sourcePortDiff < 0
        }

        let target1Node = group1.edge.target?.node
        let target2Node = group2.edge.target?.node
        let targetNodeDiff = (target1Node?.id ?? 0) - (target2Node?.id ?? 0)
        if targetNodeDiff != 0 {
            return targetNodeDiff < 0
        }

        let target1Id = group2.edge.target?.id ?? 0
        let target2Id = group1.edge.target?.id ?? 0
        return (target1Id - target2Id) < 0
    }

}
