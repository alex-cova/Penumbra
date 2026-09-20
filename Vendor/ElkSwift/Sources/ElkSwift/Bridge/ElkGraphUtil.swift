// Copyright (c) 2016 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

// ElkGraphUtil - Utility class for ELK graph creation and traversal.
// This file provides the ElkGraphUtil API expected by transpiled code.
// Parameter labels use `_` to match Java-style positional call sites.

import Foundation

/// Factory for ELK graph elements using concrete Impl2 classes.
package class ElkGraphFactoryImpl {
    package init() {}

    package func createElkNode() -> any ElkNode {
        return ElkNodeImpl2()
    }

    package func createElkPort() -> any ElkPort {
        return ElkPortImpl2()
    }

    package func createElkLabel() -> any ElkLabel {
        return ElkLabelImpl2()
    }

    package func createElkEdge() -> any ElkEdge {
        return ElkEdgeImpl2()
    }

    package func createElkEdgeSection() -> any ElkEdgeSection {
        return ElkEdgeSectionImpl2()
    }

    package func createElkBendPoint() -> any ElkBendPoint {
        return ElkBendPointImpl2()
    }
}

final class ElkGraphUtil {

    private init() {}

    // MARK: - Graph Creation

    static func createGraph() -> ElkNode {
        return createNode(nil)
    }

    /// Create a node, optionally adding it to a parent.
    /// Call sites: `createNode(parentElkNode)` and `createNode(parent: elkGraph)`
    static func createNode(_ parent: ElkNode?) -> ElkNode {
        let node = ElkGraphFactoryImpl().createElkNode()
        node.parent = parent
        return node
    }

    static func createNode(parent: ElkNode?) -> ElkNode {
        return createNode(parent)
    }

    /// Create a port, optionally adding it to a parent node.
    static func createPort(_ parent: ElkNode?) -> ElkPort {
        let port = ElkGraphFactoryImpl().createElkPort()
        if let parent = parent {
            port.parent = parent
        }
        return port
    }

    static func createPort(parent: ElkNode?) -> ElkPort {
        return createPort(parent)
    }

    /// Create a label on a parent element. Positional: `createLabel(elknode)`
    static func createLabel(_ parent: ElkGraphElement?) -> ElkLabel {
        let label = ElkGraphFactoryImpl().createElkLabel()
        if let parent = parent {
            label.parent = parent
        }
        return label
    }

    static func createLabel(parent: ElkGraphElement?) -> ElkLabel {
        return createLabel(parent)
    }

    /// Create a label with text. Positional: `createLabel("text", node)`
    static func createLabel(_ text: String, _ parent: ElkGraphElement?) -> ElkLabel {
        let label = createLabel(parent)
        label.text = text
        return label
    }

    static func createLabel(text: String, parent: ElkGraphElement?) -> ElkLabel {
        return createLabel(text, parent)
    }

    /// Create an edge with an optional containing node.
    static func createEdge(_ containingNode: ElkNode?) -> ElkEdge {
        let edge = ElkGraphFactoryImpl().createElkEdge()
        edge.containingNode = containingNode
        return edge
    }

    static func createEdge(containingNode: ElkNode?) -> ElkEdge {
        return createEdge(containingNode)
    }

    /// Create a simple edge between source and target.
    static func createSimpleEdge(_ source: ElkConnectableShape, _ target: ElkConnectableShape) -> ElkEdge {
        let edge = createEdge(nil)
        edge.sources.append(source)
        edge.targets.append(target)
        updateContainment(edge)
        return edge
    }

    static func createSimpleEdge(source: ElkConnectableShape, target: ElkConnectableShape) -> ElkEdge {
        return createSimpleEdge(source, target)
    }

    // MARK: - Edge Sections

    static func createEdgeSection(_ edge: ElkEdge?) -> ElkEdgeSection {
        let section = ElkGraphFactoryImpl().createElkEdgeSection()
        if let edge = edge {
            edge.sections.append(section)
        }
        return section
    }

    /// Get or create the first edge section.
    /// Java signature: firstEdgeSection(ElkEdge, boolean resetSection, boolean removeOtherSections)
    /// Call sites use both positional and labeled forms:
    ///   - `firstEdgeSection(edge, true, true)`
    ///   - `firstEdgeSection(elkedge, create: true, createSource: true, createTarget: true)`
    static func firstEdgeSection(_ edge: ElkEdge, _ resetSection: Bool, _ removeOtherSections: Bool) -> ElkEdgeSection {
        if edge.sections.isEmpty {
            return createEdgeSection(edge)
        } else {
            let section = edge.sections[0]

            if resetSection {
                section.bendPoints.removeAll()
                section.startX = 0
                section.startY = 0
                section.endX = 0
                section.endY = 0
            }

            if removeOtherSections {
                while edge.sections.count > 1 {
                    edge.sections.removeLast()
                }
            }

            return section
        }
    }

    /// Overload for labeled call sites: `firstEdgeSection(elkedge, create:, createSource:, createTarget:)`
    /// These map to the same reset/remove semantics.
    static func firstEdgeSection(_ edge: ElkEdge, create: Bool, createSource: Bool, createTarget: Bool) -> ElkEdgeSection {
        return firstEdgeSection(edge, create, createSource)
    }

    static func firstEdgeSection(edge: ElkEdge, resetSection: Bool, removeOtherSections: Bool) -> ElkEdgeSection {
        return firstEdgeSection(edge, resetSection, removeOtherSections)
    }

    // MARK: - Bend Points

    @discardableResult
    static func createBendPoint(_ edgeSection: ElkEdgeSection?, _ x: Double, _ y: Double) -> ElkBendPoint {
        let bendPoint = ElkGraphFactoryImpl().createElkBendPoint()
        bendPoint.set(x: x, y: y)
        if let edgeSection = edgeSection {
            edgeSection.bendPoints.append(bendPoint)
        }
        return bendPoint
    }

    @discardableResult
    static func createBendPoint(_ edgeSection: ElkEdgeSection?) -> ElkBendPoint {
        return createBendPoint(edgeSection, 0, 0)
    }

    // MARK: - Edge Containment

    static func updateContainment(_ edge: ElkEdge) {
        edge.containingNode = findBestEdgeContainment(edge)
    }

    static func updateContainment(edge: ElkEdge) {
        updateContainment(edge)
    }

    static func findBestEdgeContainment(_ edge: ElkEdge) -> ElkNode? {
        let incidentCount = edge.sources.count + edge.targets.count

        switch incidentCount {
        case 0:
            return nil
        case 1:
            if edge.sources.isEmpty {
                return connectableShapeToNode(edge.targets[0]).parent
            } else {
                return connectableShapeToNode(edge.sources[0]).parent
            }
        default:
            if edge.sources.count == 1 && edge.targets.count == 1 {
                let sourceNode = connectableShapeToNode(edge.sources[0])
                let targetNode = connectableShapeToNode(edge.targets[0])

                if sourceNode.parent === targetNode.parent {
                    return sourceNode.parent
                } else if sourceNode === targetNode.parent {
                    return sourceNode
                } else if targetNode === sourceNode.parent {
                    return targetNode
                }
            }

            // General case: find lowest common ancestor
            let shapes = allIncidentShapes(edge)
            guard let firstShape = shapes.first else { return nil }
            var commonAncestor = connectableShapeToNode(firstShape)

            for shape in shapes.dropFirst() {
                let incidentNode = connectableShapeToNode(shape)
                if incidentNode !== commonAncestor && !isDescendant(incidentNode, commonAncestor) {
                    if incidentNode.parent === commonAncestor.parent {
                        if let p = incidentNode.parent {
                            commonAncestor = p
                        }
                    } else {
                        commonAncestor = findLowestCommonAncestor(commonAncestor, incidentNode) ?? commonAncestor.parent ?? commonAncestor
                    }
                }
            }

            return commonAncestor
        }
    }

    static func findBestEdgeContainment(edge: ElkEdge) -> ElkNode? {
        return findBestEdgeContainment(edge)
    }

    static func findLowestCommonAncestor(_ node1: ElkNode, _ node2: ElkNode) -> ElkNode? {
        var ancestors1: [ElkNode] = []
        var current: ElkNode? = node1
        while let c = current {
            ancestors1.append(c)
            current = c.parent
        }

        var ancestors2: [ElkNode] = []
        current = node2
        while let c = current {
            ancestors2.append(c)
            current = c.parent
        }

        var commonAncestor: ElkNode? = nil
        var i1 = ancestors1.count - 1
        var i2 = ancestors2.count - 1

        while i1 >= 0 && i2 >= 0 && ancestors1[i1] === ancestors2[i2] {
            commonAncestor = ancestors1[i1]
            i1 -= 1
            i2 -= 1
        }

        return commonAncestor
    }

    // MARK: - Edge Queries (Convenience)

    /// All incoming edges for a node (direct + through ports).
    static func allIncomingEdges(_ node: ElkNode) -> [ElkEdge] {
        var edges = Array(node.incomingEdges)
        for port in node.ports {
            edges.append(contentsOf: port.incomingEdges)
        }
        return edges
    }

    static func allIncomingEdges(node: ElkNode) -> [ElkEdge] {
        return allIncomingEdges(node)
    }

    /// All outgoing edges for a node (direct + through ports).
    static func allOutgoingEdges(_ node: ElkNode) -> [ElkEdge] {
        var edges = Array(node.outgoingEdges)
        for port in node.ports {
            edges.append(contentsOf: port.outgoingEdges)
        }
        return edges
    }

    static func allOutgoingEdges(node: ElkNode) -> [ElkEdge] {
        return allOutgoingEdges(node)
    }

    /// All incident edges on a connectable shape (node or port).
    static func allIncidentEdges(_ shape: ElkConnectableShape) -> [ElkEdge] {
        return Array(shape.incomingEdges) + Array(shape.outgoingEdges)
    }

    /// All incident edges for a node (all incoming + all outgoing, including through ports).
    static func allIncidentEdges(_ node: ElkNode) -> [ElkEdge] {
        return allOutgoingEdges(node) + allIncomingEdges(node)
    }

    /// All incident shapes (sources + targets) of an edge.
    static func allIncidentShapes(_ edge: ElkEdge) -> [ElkConnectableShape] {
        return Array(edge.sources) + Array(edge.targets)
    }

    static func allIncidentShapes(edge: ElkEdge) -> [ElkConnectableShape] {
        return allIncidentShapes(edge)
    }

    // MARK: - Descendant Check

    /// Check if `child` is a descendant of `ancestor`.
    static func isDescendant(_ child: ElkNode, _ ancestor: ElkNode) -> Bool {
        var current = child
        while let parent = current.parent {
            if parent === ancestor {
                return true
            }
            current = parent
        }
        return false
    }

    static func isDescendant(child: ElkNode, ancestor: ElkNode) -> Bool {
        return isDescendant(child, ancestor)
    }

    // MARK: - Shape Conversion

    /// Convert a connectable shape (node or port) to its owning node.
    static func connectableShapeToNode(_ shape: ElkConnectableShape) -> ElkNode {
        if let node = shape as? ElkNode {
            return node
        } else if let port = shape as? ElkPort, let parent = port.parent {
            return parent
        } else {
            assertionFailure("ElkGraphUtil.connectableShapeToNode: shape is neither ElkNode nor ElkPort")
            return ElkGraphUtil.createNode(nil)
        }
    }

    /// Convert a connectable shape to a port, or nil if it's a node.
    static func connectableShapeToPort(_ shape: ElkConnectableShape) -> ElkPort? {
        return shape as? ElkPort
    }

    // MARK: - Simple Edge Accessors

    static func getSourceNode(_ simpleEdge: ElkEdge) -> ElkNode {
        return connectableShapeToNode(simpleEdge.sources[0])
    }

    static func sourceNode(_ edge: ElkEdge) -> ElkNode {
        return connectableShapeToNode(edge.sources[0])
    }

    static func getTargetNode(_ simpleEdge: ElkEdge) -> ElkNode {
        return connectableShapeToNode(simpleEdge.targets[0])
    }

    static func targetNode(_ edge: ElkEdge) -> ElkNode {
        return connectableShapeToNode(edge.targets[0])
    }

    static func getSourcePort(_ simpleEdge: ElkEdge) -> ElkPort? {
        return connectableShapeToPort(simpleEdge.sources[0])
    }

    static func sourcePort(_ edge: ElkEdge) -> ElkPort? {
        return connectableShapeToPort(edge.sources[0])
    }

    static func getTargetPort(_ simpleEdge: ElkEdge) -> ElkPort? {
        return connectableShapeToPort(simpleEdge.targets[0])
    }

    static func targetPort(_ edge: ElkEdge) -> ElkPort? {
        return connectableShapeToPort(edge.targets[0])
    }

    // MARK: - Graph Containment

    static func containingGraph(_ element: ElkGraphElement) -> ElkNode? {
        if let edge = element as? ElkEdge {
            return edge.containingNode
        } else if let node = element as? ElkNode {
            return node.parent
        } else if let port = element as? ElkPort {
            return port.parent
        } else if let label = element as? ElkLabel {
            return label.parent as? ElkNode ?? (label.parent as? ElkPort)?.parent
        }
        return nil
    }

    static func containingGraph(element: ElkGraphElement) -> ElkNode? {
        return containingGraph(element)
    }

    // MARK: - Property Value Checks

    static func isAdvancedPropertyValue(_ enumValue: Any) -> Bool {
        // Placeholder - would require metadata/reflection
        return false
    }

    static func isExperimentalPropertyValue(_ enumValue: Any) -> Bool {
        // Placeholder - would require metadata/reflection
        return false
    }

    // MARK: - Graph Element Traversal

    /// Iterates over all elements in a graph tree (nodes, ports, edges, labels).
    /// Used by `applyVisitors` in ElkUtil.
    static func propertiesSkippingIteratorFor(_ graph: ElkNode, _ skipProperties: Bool) -> AnySequence<Any> {
        return AnySequence { () -> AnyIterator<Any> in
            var stack = ArrayDeque<Any>([graph])
            return AnyIterator {
                while !stack.isEmpty {
                    let element = stack.removeFirst()
                    if let node = element as? ElkNode {
                        // Add children, ports, edges, labels
                        stack.append(contentsOf: node.children)
                        stack.append(contentsOf: node.ports)
                        stack.append(contentsOf: node.labels)
                        stack.append(contentsOf: node.containedEdges)
                    } else if let port = element as? ElkPort {
                        stack.append(contentsOf: port.labels)
                    } else if let edge = element as? ElkEdge {
                        stack.append(contentsOf: edge.labels)
                        stack.append(contentsOf: edge.sections)
                    }
                    return element
                }
                return nil
            }
        }
    }

    // MARK: - All Contents (eAllContents equivalent)

    /// Returns all elements contained in the graph tree (depth-first).
    static func allContents(_ graph: ElkNode) -> [ElkGraphElement] {
        var result: [ElkGraphElement] = []
        var stack = ArrayDeque<ElkGraphElement>([graph])
        while !stack.isEmpty {
            let element = stack.removeFirst()
            result.append(element)
            if let node = element as? ElkNode {
                stack.append(contentsOf: node.children as [ElkGraphElement])
                stack.append(contentsOf: node.ports as [ElkGraphElement])
                stack.append(contentsOf: node.labels as [ElkGraphElement])
                stack.append(contentsOf: node.containedEdges as [ElkGraphElement])
            } else if let port = element as? ElkPort {
                stack.append(contentsOf: port.labels as [ElkGraphElement])
            } else if let edge = element as? ElkEdge {
                stack.append(contentsOf: edge.labels as [ElkGraphElement])
            }
        }
        return result
    }

    // MARK: - Label Utilities

    static func elementLabeledBy(_ label: ElkLabel) -> ElkGraphElement? {
        var element: Any? = label.parent
        while let current = element as? ElkLabel {
            element = current.parent
        }
        return element as? ElkGraphElement
    }
}
