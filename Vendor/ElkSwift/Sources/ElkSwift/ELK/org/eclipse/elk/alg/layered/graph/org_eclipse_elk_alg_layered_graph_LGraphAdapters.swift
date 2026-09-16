// Copyright (c) 2014, 2019 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

import Foundation

/// Provides implementations of the GraphAdapters interfaces for the LGraph.
package final class LGraphAdapters {

    private init() {}

    package static func adapt(_ graph: LGraph) -> LGraphAdapter {
        return LGraphAdapter(graph, transparentNorthSouthEdges: false, transparentCommentNodes: false, nodeFilter: { _ in true })
    }

    package static func adapt(_ graph: LGraph, transparentNorthSouthEdges: Bool) -> LGraphAdapter {
        return LGraphAdapter(graph, transparentNorthSouthEdges: transparentNorthSouthEdges, transparentCommentNodes: false, nodeFilter: { _ in true })
    }

    package static func adapt(_ graph: LGraph, transparentNorthSouthEdges: Bool, transparentCommentNodes: Bool, nodeFilter: @escaping (LNode) -> Bool) -> LGraphAdapter {
        return LGraphAdapter(graph, transparentNorthSouthEdges: transparentNorthSouthEdges, transparentCommentNodes: transparentCommentNodes, nodeFilter: nodeFilter)
    }

    package static func adapt(_ node: LNode, transparentNorthSouthEdges: Bool) -> LNodeAdapter {
        return LNodeAdapter(parentGraphAdapter: nil, element: node, transparentNorthSouthEdges: transparentNorthSouthEdges)
    }

    package static func adapt(_ label: LLabel) -> LLabelAdapter {
        return LLabelAdapter(label)
    }

    // MARK: - LGraphAdapter

    package class LGraphAdapter: GraphAdapter {
        package let element: LGraph
        package var nodeAdapters: [NodeAdapter]?
        package let transparentNorthSouthEdges: Bool
        package let transparentCommentNodes: Bool
        package let nodeFilter: (LNode) -> Bool

        init(_ element: LGraph, transparentNorthSouthEdges: Bool, transparentCommentNodes: Bool, nodeFilter: @escaping (LNode) -> Bool) {
            self.element = element
            self.transparentNorthSouthEdges = transparentNorthSouthEdges
            self.transparentCommentNodes = transparentCommentNodes
            self.nodeFilter = nodeFilter
        }

        package func getSize() -> KVector { return element.getSize() }
        package func setSize(_ size: KVector) { element.size = size }
        package func getPosition() -> KVector { return element.offset }
        package func setPosition(_ pos: KVector) { element.offset = pos }
        package func getProperty<P>(_ prop: IProperty) -> P? { return element.getProperty(prop) as? P }
        package func hasProperty(_ prop: IProperty) -> Bool { return element.hasProperty(prop) }
        package func getVolatileId() -> Int { return element.id }
        package func setVolatileId(_ id: Int) { element.id = id }

        package func getNodes() -> [NodeAdapter] {
            if let cached = nodeAdapters { return cached }
            var computed: [NodeAdapter] = []
            for layer in element.getLayers() {
                for node in layer.getNodes() {
                    if nodeFilter(node) {
                        computed.append(LNodeAdapter(parentGraphAdapter: self, element: node, transparentNorthSouthEdges: transparentNorthSouthEdges))
                    }
                }
            }
            nodeAdapters = computed
            return computed
        }
    }

    // MARK: - LNodeAdapter

    package class LNodeAdapter: NodeAdapter {
        package weak var parentGraphAdapter: LGraphAdapter?
        package let element: LNode
        package var labelAdapters: [LabelAdapter]?
        package var portAdapters: [PortAdapter]?
        package let transparentNorthSouthEdges: Bool

        init(parentGraphAdapter: LGraphAdapter?, element: LNode, transparentNorthSouthEdges: Bool) {
            self.parentGraphAdapter = parentGraphAdapter
            self.element = element
            self.transparentNorthSouthEdges = transparentNorthSouthEdges
        }

        package func getSize() -> KVector { return element.getSize() }
        package func setSize(_ size: KVector) { element.size = size }
        package func getPosition() -> KVector { return element.getPosition() }
        package func setPosition(_ pos: KVector) { element.position = pos }
        package func getProperty<P>(_ prop: IProperty) -> P? { return element.getProperty(prop) as? P }
        package func hasProperty(_ prop: IProperty) -> Bool { return element.hasProperty(prop) }
        package func getVolatileId() -> Int { return element.id }
        package func setVolatileId(_ id: Int) { element.id = id }

        package func getGraph() -> GraphAdapter? { return parentGraphAdapter }

        package func getLabels() -> [LabelAdapter] {
            if let cached = labelAdapters { return cached }
            let computed = element.getLabels().map { LLabelAdapter($0) }
            labelAdapters = computed
            return computed
        }

        package func getPorts() -> [PortAdapter] {
            if let cached = portAdapters { return cached }
            let computed = element.getPorts().map { LPortAdapter($0, transparentNorthSouthEdges: transparentNorthSouthEdges) }
            portAdapters = computed
            return computed
        }

        package func getIncomingEdges() -> [EdgeAdapter] { return [] }
        package func getOutgoingEdges() -> [EdgeAdapter] { return [] }

        package func sortPortList() {}
        package func sortPortList(_ comparator: Any) {}

        package func isCompoundNode() -> Bool {
            return element.getProperty(InternalProperties.COMPOUND_NODE) as? Bool ?? false
        }

        package func getPadding() -> ElkPadding {
            let p = element.getPadding()
            return ElkPadding(p.top, p.right, p.bottom, p.left)
        }

        package func setPadding(_ padding: ElkPadding) {
            let p = element.getPadding()
            p.set(padding.top, padding.right, padding.bottom, padding.left)
        }

        package func getMargin() -> ElkMargin {
            let m = element.getMargin()
            return ElkMargin(m.top, m.right, m.bottom, m.left)
        }

        package func setMargin(_ margin: ElkMargin) {
            let m = element.getMargin()
            m.set(margin.top, margin.right, margin.bottom, margin.left)
        }
    }

    // MARK: - LPortAdapter

    package class LPortAdapter: PortAdapter {
        package let element: LPort
        package var labelAdapters: [LabelAdapter]?
        package let transparentNorthSouthEdges: Bool

        init(_ element: LPort, transparentNorthSouthEdges: Bool) {
            self.element = element
            self.transparentNorthSouthEdges = transparentNorthSouthEdges
        }

        package func getSize() -> KVector { return element.getSize() }
        package func setSize(_ size: KVector) { element.size = size }
        package func getPosition() -> KVector { return element.getPosition() }
        package func setPosition(_ pos: KVector) { element.position = pos }
        package func getProperty<P>(_ prop: IProperty) -> P? { return element.getProperty(prop) as? P }
        package func hasProperty(_ prop: IProperty) -> Bool { return element.hasProperty(prop) }
        package func getVolatileId() -> Int { return element.id }
        package func setVolatileId(_ id: Int) { element.id = id }

        package func getSide() -> PortSide { return element.getSide() }

        package func getLabels() -> [LabelAdapter] {
            if let cached = labelAdapters { return cached }
            let computed = element.getLabels().map { LLabelAdapter($0) }
            labelAdapters = computed
            return computed
        }

        package func getIncomingEdges() -> [EdgeAdapter] {
            return element.getIncomingEdges().map { LEdgeAdapter($0) }
        }

        package func getOutgoingEdges() -> [EdgeAdapter] {
            return element.getOutgoingEdges().map { LEdgeAdapter($0) }
        }

        package func hasCompoundConnections() -> Bool {
            return element.getProperty(InternalProperties.INSIDE_CONNECTIONS) as? Bool ?? false
        }
    }

    // MARK: - LLabelAdapter

    package class LLabelAdapter: LabelAdapter {
        package let element: LLabel

        init(_ element: LLabel) {
            self.element = element
        }

        package func getSize() -> KVector { return element.getSize() }
        package func setSize(_ size: KVector) { element.size = size }
        package func getPosition() -> KVector { return element.getPosition() }
        package func setPosition(_ pos: KVector) { element.position = pos }
        package func getProperty<P>(_ prop: IProperty) -> P? { return element.getProperty(prop) as? P }
        package func hasProperty(_ prop: IProperty) -> Bool { return element.hasProperty(prop) }
        package func getVolatileId() -> Int { return element.id }
        package func setVolatileId(_ id: Int) { element.id = id }

        package func getSide() -> LabelSide {
            return element.getProperty(LabelSide.LABEL_SIDE) as? LabelSide ?? .UNKNOWN
        }

        package func getText() -> String {
            return element.getText()
        }
    }

    // MARK: - LEdgeAdapter

    package class LEdgeAdapter: EdgeAdapter {
        package let element: LEdge

        init(_ edge: LEdge) {
            self.element = edge
        }

        package func getSize() -> KVector { return KVector() }
        package func setSize(_ size: KVector) {}
        package func getPosition() -> KVector { return KVector() }
        package func setPosition(_ pos: KVector) {}
        package func getProperty<P>(_ prop: IProperty) -> P? { return element.getProperty(prop) as? P }
        package func hasProperty(_ prop: IProperty) -> Bool { return element.hasProperty(prop) }
        package func getVolatileId() -> Int { return element.id }
        package func setVolatileId(_ id: Int) { element.id = id }

        package func getLabels() -> [LabelAdapter] {
            return element.getLabels().map { LLabelAdapter($0) }
        }
    }
}
