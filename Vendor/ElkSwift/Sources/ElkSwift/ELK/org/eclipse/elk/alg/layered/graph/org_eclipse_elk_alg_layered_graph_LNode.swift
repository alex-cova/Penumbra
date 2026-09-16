// Copyright (c) 2010, 2019 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

import Foundation

// MARK: - NodeType

package enum NodeType: String {
    case normal = "NORMAL"
    case longEdge = "LONG_EDGE"
    case externalPort = "EXTERNAL_PORT"
    case northSouthPort = "NORTH_SOUTH_PORT"
    case label = "LABEL"
    case breakingPoint = "BREAKING_POINT"
    case placeholder = "PLACEHOLDER"
    case nonShiftingPlaceholder = "NONSHIFTING_PLACEHOLDER"

    package static let NORMAL = NodeType.normal
    package static let LONG_EDGE = NodeType.longEdge
    package static let EXTERNAL_PORT = NodeType.externalPort
    package static let NORTH_SOUTH_PORT = NodeType.northSouthPort
    package static let LABEL = NodeType.label
    package static let BREAKING_POINT = NodeType.breakingPoint
    package static let PLACEHOLDER = NodeType.placeholder
    package static let NONSHIFTING_PLACEHOLDER = NodeType.nonShiftingPlaceholder

    package func getColor() -> String {
        switch self {
        case .externalPort: return "#cc99cc"
        case .longEdge: return "#eaed00"
        case .northSouthPort: return "#0034de"
        case .label: return "#75c3c3"
        case .breakingPoint: return "#eeeeff"
        default: return "#eeeeee"
        }
    }
}

// MARK: - LNode

package class LNode: LShape {

    package var graph: LGraph?
    package var layer: Layer?
    package var type: NodeType = .normal
    package var ports: [LPort] = []
    package var labels: [LLabel] = []
    package var nestedGraph: LGraph?
    package var margin = LMargin()
    package var padding = LPadding()
    package var portSideIndices: [PortSide: (Int, Int)]?
    package var portSidesCached = false

    package init(_ graph: LGraph) {
        self.graph = graph
    }

    package override init() {
        super.init()
    }

    // MARK: - Layer Management

    package func getLayer() -> Layer? {
        return layer
    }

    package func setLayer(_ theLayer: Layer?) {
        if let oldLayer = layer {
            oldLayer.nodes.removeAll { $0 === self }
        }
        layer = theLayer
        if let newLayer = layer {
            newLayer.nodes.append(self)
        }
    }

    package func setLayer(_ index: Int, _ theLayer: Layer) {
        if let oldLayer = layer {
            oldLayer.nodes.removeAll { $0 === self }
        }
        layer = theLayer
        theLayer.nodes.insert(self, at: min(index, theLayer.nodes.count))
    }

    // MARK: - Graph Management

    package func getGraph() -> LGraph? {
        if graph == nil, let layer = layer {
            return layer.getGraph()
        }
        return graph
    }

    package func setGraph(_ newGraph: LGraph) {
        graph = newGraph
    }

    // MARK: - Node Type

    package func getType() -> NodeType {
        return type
    }

    package func setType(_ type: NodeType) {
        self.type = type
    }

    // MARK: - Ports

    package func getPorts() -> [LPort] {
        return ports
    }

    package func getPorts(_ portType: PortType) -> [LPort] {
        switch portType {
        case .INPUT:
            return ports.filter { !$0.getIncomingEdges().isEmpty }
        case .OUTPUT:
            return ports.filter { !$0.getOutgoingEdges().isEmpty }
        default:
            return ports
        }
    }

    package func getPorts(_ side: PortSide) -> [LPort] {
        return ports.filter { $0.getSide() == side }
    }

    package func getPortSideView(_ side: PortSide) -> [LPort] {
        if !portSidesCached {
            findPortIndices()
        }
        guard let indices = portSideIndices?[side] else {
            return []
        }
        return Array(ports[indices.0..<indices.1])
    }

    /// Writes a reordered port list back into the node's `ports` array for the given side.
    /// This is needed because `getPortSideView` returns a value-type copy in Swift,
    /// whereas Java's `subList` returns a live view. Callers that reorder ports via the
    /// view must call this method to propagate changes back.
    package func setPortSideView(_ side: PortSide, _ reorderedPorts: [LPort]) {
        if !portSidesCached {
            findPortIndices()
        }
        guard let indices = portSideIndices?[side] else { return }
        let range = indices.0..<indices.1
        guard range.count == reorderedPorts.count else { return }
        ports.replaceSubrange(range, with: reorderedPorts)
    }

    package func getPorts(_ portType: PortType, _ side: PortSide) -> [LPort] {
        return getPorts(side).filter { port in
            switch portType {
            case .INPUT: return !port.getIncomingEdges().isEmpty
            case .OUTPUT: return !port.getOutgoingEdges().isEmpty
            default: return true
            }
        }
    }

    // MARK: - Edges

    package func getIncomingEdges() -> [LEdge] {
        return ports.flatMap { $0.getIncomingEdges() }
    }

    package func getOutgoingEdges() -> [LEdge] {
        return ports.flatMap { $0.getOutgoingEdges() }
    }

    package func getConnectedEdges() -> [LEdge] {
        return ports.flatMap { $0.getIncomingEdges() + $0.getOutgoingEdges() }
    }

    // MARK: - Labels

    package func getLabels() -> [LLabel] {
        return labels
    }

    // MARK: - Nested Graph

    package func getNestedGraph() -> LGraph? {
        return nestedGraph
    }

    package func setNestedGraph(_ nestedGraph: LGraph?) {
        self.nestedGraph = nestedGraph
    }

    // MARK: - Margin and Padding

    package func getMargin() -> LMargin {
        return margin
    }

    package func getPadding() -> LPadding {
        return padding
    }

    // MARK: - Coordinate Conversion

    /**
     * Converts the position of this node from coordinates relative to the parent node's border to
     * coordinates relative to that node's content area. The content area is the parent node border
     * minus padding minus offset.
     */
    package func borderToContentAreaCoordinates(_ horizontal: Bool, _ vertical: Bool) {
        guard let thegraph = getGraph() else { return }

        let graphPadding = thegraph.getPadding()
        let offset = thegraph.getOffset()
        let pos = getPosition()

        if horizontal {
            pos.x = pos.x - graphPadding.left - offset.x
        }

        if vertical {
            pos.y = pos.y - graphPadding.top - offset.y
        }
    }

    // MARK: - Index

    package func getIndex() -> Int {
        guard let layer = layer else { return -1 }
        return layer.nodes.firstIndex { $0 === self } ?? -1
    }

    // MARK: - Port Side Caching

    package func cachePortSides() {
        portSidesCached = true
        findPortIndices()
    }

    package func findPortIndices() {
        var indices: [PortSide: (Int, Int)] = [:]
        var firstIndexForCurrentSide = 0
        var currentSide = PortSide.NORTH
        var currentIndex = 0

        for port in ports {
            if port.getSide() != currentSide {
                if firstIndexForCurrentSide != currentIndex {
                    indices[currentSide] = (firstIndexForCurrentSide, currentIndex)
                }
                currentSide = port.getSide()
                firstIndexForCurrentSide = currentIndex
            }
            currentIndex += 1
        }

        indices[currentSide] = (firstIndexForCurrentSide, currentIndex)
        self.portSideIndices = indices
    }

    // MARK: - Interactive Reference

    /// Returns the center of the node (position + half size), used by interactive strategies.
    package func getInteractiveReferencePoint() -> KVector {
        return KVector(getPosition().x + getSize().x / 2, getPosition().y + getSize().y / 2)
    }

    package func isInlineEdgeLabel() -> Bool {
        guard type == .label else { return false }
        let representedLabels = getProperty(InternalProperties.REPRESENTED_LABELS) as? [LLabel] ?? []
        return representedLabels.allSatisfy { label in
            label.getProperty(LayeredOptions.EDGE_LABELS_INLINE) as? Bool ?? false
        }
    }

    // MARK: - Designation

    package override func getDesignation() -> String? {
        if !labels.isEmpty, let firstLabel = labels.first {
            let text = firstLabel.getText()
            if !text.isEmpty {
                return text
            }
        }
        if let designation = super.getDesignation(), !designation.isEmpty {
            return designation
        }
        return String(getIndex())
    }

    // MARK: - String Representation

    package func toString() -> String {
        var result = "n"
        if type != .normal {
            result += "(\(type.rawValue.lowercased()))"
        }
        result += "_\(getDesignation() ?? "")"
        return result
    }
}
