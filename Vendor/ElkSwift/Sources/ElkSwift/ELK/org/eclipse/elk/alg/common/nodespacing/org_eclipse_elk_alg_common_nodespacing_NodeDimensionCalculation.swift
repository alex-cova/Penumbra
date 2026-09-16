//
//  NodeDimensionCalculation.swift
//  Transpiled from Java
//
//  Copyright (c) 2014, 2015 Kiel University and others.
//
//  This program and the accompanying materials are made available under the
//  terms of the Eclipse Public License 2.0 which is available at
//  http://www.eclipse.org/legal/epl-2.0.
//
//  SPDX-License-Identifier: EPL-2.0
//

import Foundation

/**
 * Entry points to apply several methods for node dimension calculation, including positioning of
 * labels, ports, etc.
 */
package final class NodeDimensionCalculation {

    private init() {}

    /**
     * Calculates label sizes and node sizes also considering ports. Make sure that the port lists
     * are sorted properly.
     */
    package static func calculateLabelAndNodeSizes(_ adapter: GraphAdapter) {
        NodeLabelAndSizeCalculator.process(adapter)
    }

    /**
     * Calculates node margins for the nodes of the passed graph.
     */
    package static func calculateNodeMargins(_ adapter: GraphAdapter) {
        let calculator = NodeMarginCalculator(adapter)
        calculator.process()
    }

    /**
     * Returns a configurable NodeMarginCalculator that can be executed using the
     * process() method.
     */
    package static func getNodeMarginCalculator(_ adapter: GraphAdapter) -> NodeMarginCalculator {
        return NodeMarginCalculator(adapter)
    }

    /**
     * Sorts the port lists of all nodes of the graph clockwise.
     */
    package static func sortPortLists(_ adapter: GraphAdapter) {
        for node in adapter.getNodes() {
            node.sortPortList()
        }
    }
}
