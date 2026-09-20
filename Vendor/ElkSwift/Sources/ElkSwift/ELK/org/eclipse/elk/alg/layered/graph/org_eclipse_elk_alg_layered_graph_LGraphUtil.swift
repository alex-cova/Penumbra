/*******************************************************************************
 * Copyright (c) 2014, 2020 Kiel University and others.
 * 
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 *******************************************************************************/

// Note: This is a partial translation. Some imports and dependencies may need to be implemented or imported separately.

import Foundation

// MARK: - LGraphUtil

package final class LGraphUtil {
    
    private init() { }
    
    package static func toNodeArray(_ nodes: [LNode]) -> [LNode] {
        return nodes
    }
    
    package static func toEdgeArray(_ edges: [LEdge]) -> [LEdge] {
        return edges
    }
    
    package static func toPortArray(_ ports: [LPort]) -> [LPort] {
        return ports
    }
    
    // MARK: - Node Resizing
    
    package static func resizeNode(_ node: LNode, newSize: KVector, movePorts: Bool, moveLabels: Bool) {
        let oldSize = node.size
        
        let widthRatio = Double(newSize.x / oldSize.x)
        let heightRatio = Double(newSize.y / oldSize.y)
        let widthDiff = Double(newSize.x - oldSize.x)
        let heightDiff = Double(newSize.y - oldSize.y)

        if movePorts {
            let fixedPorts = node.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints == PortConstraints.FIXED_POS
            
            for port in node.getPorts() {
                switch port.side {
                case .NORTH:
                    if !fixedPorts {
                        port.position.x *= widthRatio
                    }
                case .EAST:
                    port.position.x += widthDiff
                    if !fixedPorts {
                        port.position.y *= heightRatio
                    }
                case .SOUTH:
                    if !fixedPorts {
                        port.position.x *= widthRatio
                    }
                    port.position.y += heightDiff
                case .WEST:
                    if !fixedPorts {
                        port.position.y *= heightRatio
                    }
                default:
                    break
                }
            }
        }
        
        if moveLabels {
            for label in node.getLabels() {
                let midx = label.position.x + label.size.x / 2
                let midy = label.position.y + label.size.y / 2
                let widthPercent = midx / oldSize.x
                let heightPercent = midy / oldSize.y
                
                if widthPercent + heightPercent >= 1 {
                    if widthPercent - heightPercent > 0 && midy >= 0 {
                        label.position.x += widthDiff
                        label.position.y += heightDiff * heightPercent
                    } else if widthPercent - heightPercent < 0 && midx >= 0 {
                        label.position.x += widthDiff * widthPercent
                        label.position.y += heightDiff
                    }
                }
            }
        }
        
        node.size.x = newSize.x
        node.size.y = newSize.y
        
        node.setProperty(LayeredOptions.NODE_SIZE_CONSTRAINTS, SizeConstraint.fixed)
    }
    
    // MARK: - Graph Offsetting
    
    package static func offsetGraphs(_ graphs: [LGraph], offsetx: Double, offsety: Double) {
        for graph in graphs {
            offsetGraph(graph, offsetx: offsetx, offsety: offsety)
        }
    }
    
    package static func offsetGraph(_ graph: LGraph, offsetx: Double, offsety: Double) {
        let graphOffset = KVector(offsetx, offsety)

        for node in graph.getLayerlessNodes() {
            node.position.add(graphOffset)
            for port in node.getPorts() {
                for edge in port.getOutgoingEdges() {
                    edge.getBendPoints().offset(graphOffset)
                    if let junctionPoints = edge.getProperty(LayeredOptions.JUNCTION_POINTS) as? KVectorChain {
                        junctionPoints.offset(graphOffset)
                    }
                    for label in edge.getLabels() {
                        label.position.add(graphOffset)
                    }
                }
            }
        }
    }
    
    /// Labeled overload with `dx:dy:` for callers that use those labels.
    package static func offsetGraph(_ graph: LGraph, dx: Double, dy: Double) {
        offsetGraph(graph, offsetx: dx, offsety: dy)
    }

    // MARK: - Layer Things
    
    package static func placeNodesHorizontally(_ layer: Layer, xoffset: Double) {
        var maxLeftMargin: Double = 0, maxRightMargin: Double = 0
        for node in layer.getNodes() {
            maxLeftMargin = max(maxLeftMargin, node.margin.left)
            maxRightMargin = max(maxRightMargin, node.margin.right)
        }

        for node in layer.getNodes() {
            let alignment = node.getProperty(LayeredOptions.ALIGNMENT) as? Alignment
            var ratio: Double = 0.5

            switch alignment {
            case .left:
                ratio = 0.0
            case .right:
                ratio = 1.0
            case .center:
                ratio = 0.5
            default:
                var inports = 0, outports = 0
                for port in node.getPorts() {
                    if !port.getIncomingEdges().isEmpty {
                        inports += 1
                    }
                    if !port.getOutgoingEdges().isEmpty {
                        outports += 1
                    }
                }
                
                if inports + outports == 0 {
                    ratio = 0.5
                } else {
                    ratio = Double(outports) / Double(inports + outports)
                }
            }
            
            let size = layer.getSize()
            let nodeSize = node.size.x
            var xpos = (size.x - nodeSize) * ratio
            if ratio > 0.5 {
                xpos -= maxRightMargin * 2 * (ratio - 0.5)
            } else if ratio < 0.5 {
                xpos += maxLeftMargin * 2 * (0.5 - ratio)
            }
            
            let leftMargin = node.margin.left
            if xpos < leftMargin {
                xpos = leftMargin
            }
            let rightMargin = node.margin.right
            if xpos > size.x - rightMargin - nodeSize {
                xpos = size.x - rightMargin - nodeSize
            }
            
            node.position.x = xoffset + xpos
        }
    }
    
    package static func findMaxNonDummyNodeWidth(_ layer: Layer, respectNodeMargins: Bool) -> Double {
        if (layer.getGraph().getProperty(LayeredOptions.DIRECTION) as? Direction ?? .RIGHT).isVertical() {
            return 0.0
        }

        var maxWidth: Double = 0.0

        for node in layer {
            if node.type == .NORMAL {
                var width = node.size.x
                if respectNodeMargins {
                    width += node.margin.left + node.margin.right
                }
                maxWidth = max(maxWidth, width)
            }
        }

        return maxWidth
    }
    
    // MARK: - Graph Properties
    
    package static func computeGraphProperties(_ layeredGraph: LGraph) {
        var props = Set<GraphProperties>()

        let direction = getDirection(layeredGraph)
        for node in layeredGraph.getLayerlessNodes() {
            if node.getProperty(LayeredOptions.COMMENT_BOX) as? Bool ?? false {
                props.insert(.COMMENTS)
            } else if node.getProperty(LayeredOptions.HYPERNODE) as? Bool ?? false {
                props.insert(.HYPERNODES)
                props.insert(.HYPEREDGES)
            } else if node.type == .EXTERNAL_PORT {
                props.insert(.EXTERNAL_PORTS)
            }

            let portConstraints = node.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .UNDEFINED
            if portConstraints == .UNDEFINED {
                node.setProperty(LayeredOptions.PORT_CONSTRAINTS, PortConstraints.FREE)
            } else if portConstraints != .FREE {
                props.insert(.NON_FREE_PORTS)
            }

            for port in node.getPorts() {
                if port.getIncomingEdges().count + port.getOutgoingEdges().count > 1 {
                    props.insert(.HYPEREDGES)
                }

                let portSide = port.side
                switch direction {
                case .UP, .DOWN:
                    if portSide == .EAST || portSide == .WEST {
                        props.insert(.NORTH_SOUTH_PORTS)
                    }
                default:
                    if portSide == .NORTH || portSide == .SOUTH {
                        props.insert(.NORTH_SOUTH_PORTS)
                    }
                }

                for edge in port.getOutgoingEdges() {
                    if edge.target?.getNode() === node {
                        props.insert(.SELF_LOOPS)
                    }

                    for label in edge.getLabels() {
                        switch label.getProperty(LayeredOptions.EDGE_LABELS_PLACEMENT) as? EdgeLabelPlacement {
                        case .center:
                            props.insert(.CENTER_LABELS)
                        case .head, .tail:
                            props.insert(.END_LABELS)
                        default:
                            break
                        }
                    }
                }
            }
        }

        layeredGraph.setProperty(InternalProperties.GRAPH_PROPERTIES, props)
    }
    
    // MARK: - Handling of Ports
    
    package static func createPort(_ node: LNode, _ endPoint: KVector?, _ type: PortType, _ layeredGraph: LGraph) -> LPort {
        var port: LPort
        let direction = getDirection(layeredGraph)
        let mergePorts = layeredGraph.getProperty(LayeredOptions.MERGE_EDGES) as? Bool ?? false

        if ((mergePorts || (node.getProperty(LayeredOptions.HYPERNODE) as? Bool ?? false)) &&
            !(node.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .UNDEFINED).isSideFixed()) {
            
            let defaultSide = PortSide.fromDirection(direction)
            port = provideCollectorPort(layeredGraph, node: node, type: type,
                                        side: type == .OUTPUT ? defaultSide : defaultSide.opposed())
        } else {
            port = LPort()
            port.setNode(node)
            
            if let endPoint = endPoint {
                let pos = port.position
                pos.x = endPoint.x - node.position.x
                pos.y = endPoint.y - node.position.y
                _ = try? pos.bound(0, 0, node.size.x, node.size.y)
                port.side = calcPortSide(port, direction: direction)
            } else {
                let defaultSide = PortSide.fromDirection(direction)
                port.side = type == .OUTPUT ? defaultSide : defaultSide.opposed()
            }
            
            var graphProperties = layeredGraph.getProperty(InternalProperties.GRAPH_PROPERTIES) as? Set<GraphProperties> ?? []
            let portSide = port.side
            var needsUpdate = false
            switch direction {
            case .LEFT, .RIGHT:
                if portSide == .NORTH || portSide == .SOUTH {
                    graphProperties.insert(.NORTH_SOUTH_PORTS)
                    needsUpdate = true
                }
            case .UP, .DOWN:
                if portSide == .EAST || portSide == .WEST {
                    graphProperties.insert(.NORTH_SOUTH_PORTS)
                    needsUpdate = true
                }
            default:
                break
            }
            if needsUpdate {
                layeredGraph.setProperty(InternalProperties.GRAPH_PROPERTIES, graphProperties)
            }
        }
        
        return port
    }
    
    package static func calcPortSide(_ port: LPort, direction: Direction) -> PortSide {
        guard let node = port.getNode() else { return .UNDEFINED }
        let nodeWidth = node.size.x
        let nodeHeight = node.size.y
        if nodeWidth <= 0 && nodeHeight <= 0 {
            return .UNDEFINED
        }

        let xpos = port.position.x
        let ypos = port.position.y
        let width = port.size.x
        let height = port.size.y
        
        switch direction {
        case .LEFT, .RIGHT:
            if xpos < 0 {
                return .WEST
            } else if xpos + width > nodeWidth {
                return .EAST
            }
        case .UP, .DOWN:
            if ypos < 0 {
                return .NORTH
            } else if ypos + height > nodeHeight {
                return .SOUTH
            }
            default: break
        }
        
        let widthPercent = (xpos + width / 2) / nodeWidth
        let heightPercent = (ypos + height / 2) / nodeHeight
        if widthPercent + heightPercent <= 1 && widthPercent - heightPercent <= 0 {
            return .WEST
        } else if widthPercent + heightPercent >= 1 && widthPercent - heightPercent >= 0 {
            return .EAST
        } else if heightPercent < 0.5 {
            return .NORTH
        } else {
            return .SOUTH
        }
    }
    
    package static func calcPortOffset(_ port: LPort, side: PortSide) -> Double {
        guard let node = port.getNode() else { return 0 }
        switch side {
        case .NORTH:
            return -(port.position.y + port.size.y)
        case .EAST:
            return port.position.x - node.size.x
        case .SOUTH:
            return port.position.y - node.size.y
        case .WEST:
            return -(port.position.x + port.size.x)
        default:
            return 0
        }
    }

    package static func centerPoint(_ point: KVector, boundary: KVector, side: PortSide) {
        switch side {
        case .NORTH:
            point.x = boundary.x / 2
            point.y = 0
        case .EAST:
            point.x = boundary.x
            point.y = boundary.y / 2
        case .SOUTH:
            point.x = boundary.x / 2
            point.y = boundary.y
        case .WEST:
            point.x = 0
            point.y = boundary.y / 2
        default:
            break
        }
    }

    package static func provideCollectorPort(_ layeredGraph: LGraph, node: LNode, type: PortType, side: PortSide) -> LPort {
        var port: LPort?
        
        switch type {
        case .INPUT:
            for inport in node.getPorts() {
                if inport.getProperty(InternalProperties.INPUT_COLLECT) as? Bool ?? false {
                    return inport
                }
            }
            port = LPort()
            port?.setProperty(InternalProperties.INPUT_COLLECT, true)
        case .OUTPUT:
            for outport in node.getPorts() {
                if outport.getProperty(InternalProperties.OUTPUT_COLLECT) as? Bool ?? false {
                    return outport
                }
            }
            port = LPort()
            port?.setProperty(InternalProperties.OUTPUT_COLLECT, true)
            default: break
        }
        
        guard let port = port else {
            // Fallback: create a default port if neither INPUT nor OUTPUT was matched
            let fallback = LPort()
            fallback.setNode(node)
            fallback.side = side
            centerPoint(fallback.position, boundary: node.size, side: side)
            return fallback
        }
        port.setNode(node)
        port.side = side
        centerPoint(port.position, boundary: node.size, side: side)
        return port
    }
    
    package static func initializePort(_ port: LPort, _ portConstraints: PortConstraints, _ direction: Direction, _ anchorPos: KVector?) {
        var portSide = port.side
        
        if portSide == .UNDEFINED && portConstraints.isSideFixed() {
            portSide = calcPortSide(port, direction: direction)
            port.side = portSide
            
            if !port.hasProperty(LayeredOptions.PORT_BORDER_OFFSET) &&
                portSide != .UNDEFINED &&
                (port.position.x != 0 || port.position.y != 0) {

                port.setProperty(LayeredOptions.PORT_BORDER_OFFSET, calcPortOffset(port, side: portSide))
            }
        }
        
        if portConstraints.isRatioFixed() {
            var ratio: Double = 0.0
            
            switch portSide {
            case .NORTH, .SOUTH:
                let nodeWidth = port.getNode()?.size.x ?? 0
                if nodeWidth > 0 {
                    ratio = port.position.x / nodeWidth
                }
            case .EAST, .WEST:
                let nodeHeight = port.getNode()?.size.y ?? 0
                if nodeHeight > 0 {
                    ratio = port.position.y / nodeHeight
                }
            default:
                break
            }
            
            port.setProperty(InternalProperties.PORT_RATIO_OR_POSITION, ratio)
        }

        let portSize = port.size
        let portAnchor = port.anchor
        
        if let anchorPos = anchorPos {
            portAnchor.x = anchorPos.x
            portAnchor.y = anchorPos.y
            port.setExplicitlySuppliedPortAnchor(true)
        } else if portConstraints.isSideFixed() && portSide != .UNDEFINED {
            switch portSide {
            case .NORTH:
                portAnchor.x = portSize.x / 2
            case .EAST:
                portAnchor.x = portSize.x
                portAnchor.y = portSize.y / 2
            case .SOUTH:
                portAnchor.x = portSize.x / 2
                portAnchor.y = portSize.y
            case .WEST:
                portAnchor.y = portSize.y / 2
            default:
                break
            }
        } else {
            portAnchor.x = portSize.x / 2
            portAnchor.y = portSize.y / 2
        }
    }
    
    // MARK: - External Ports
    
    package static func createExternalPortDummy(_ propertyHolder: IPropertyHolder,
                                        _ portConstraints: PortConstraints, _ portSide: PortSide, _ netFlow: Int,
                                        _ portNodeSize: KVector, _ portPosition: KVector, _ portSize: KVector,
                                        _ layoutDirection: Direction, _ layeredGraph: LGraph) -> LNode {
        
        var finalExternalPortSide = portSide
        
        let dummy = LNode(layeredGraph)
        dummy.type = .EXTERNAL_PORT
        dummy.setProperty(InternalProperties.EXT_PORT_SIZE, portSize)
        dummy.setProperty(LayeredOptions.PORT_CONSTRAINTS, PortConstraints.FIXED_POS)
        let portBorderOffset: Double = propertyHolder.getProperty(LayeredOptions.PORT_BORDER_OFFSET) as? Double ?? 0.0
        dummy.setProperty(LayeredOptions.PORT_BORDER_OFFSET, portBorderOffset)
        
        let dummyPort = LPort()
        dummyPort.setNode(dummy)
        
        if !portConstraints.isSideFixed() {
            let resolvedDirection = (layoutDirection == .UNDEFINED) ? Direction.RIGHT : layoutDirection
            if netFlow >= 0 {
                finalExternalPortSide = PortSide.fromDirection(resolvedDirection)
            } else {
                finalExternalPortSide = PortSide.fromDirection(resolvedDirection).opposed()
            }
            propertyHolder.setProperty(LayeredOptions.PORT_SIDE, finalExternalPortSide)
        }
        
        var anchor = KVector()
        var explicitAnchor = false
        
        if propertyHolder.hasProperty(LayeredOptions.PORT_ANCHOR) {
            anchor = propertyHolder.getProperty(LayeredOptions.PORT_ANCHOR) as? KVector ?? KVector()
            explicitAnchor = true
        } else {
            anchor = KVector(portSize.x / 2, portSize.y / 2)
        }
        
        switch finalExternalPortSide {
        case .WEST:
            dummy.setProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT, LayerConstraint.FIRST_SEPARATE)
            dummy.setProperty(InternalProperties.EDGE_CONSTRAINT, EdgeConstraint.OUTGOING_ONLY)
            dummy.size.y = portSize.y
            if portBorderOffset < 0 {
                dummy.size.x = -portBorderOffset
            }
            dummyPort.side = .EAST
            if !explicitAnchor {
                anchor.x = portSize.x
            }
            anchor.x -= portSize.x
            
        case .EAST:
            dummy.setProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT, LayerConstraint.LAST_SEPARATE)
            dummy.setProperty(InternalProperties.EDGE_CONSTRAINT, EdgeConstraint.INCOMING_ONLY)
            dummy.size.y = portSize.y
            if portBorderOffset < 0 {
                dummy.size.x = -portBorderOffset
            }
            dummyPort.side = .WEST
            if !explicitAnchor {
                anchor.x = 0
            }
            
        case .NORTH:
            dummy.setProperty(InternalProperties.IN_LAYER_CONSTRAINT, InLayerConstraint.TOP)
            dummy.size.x = portSize.x
            if portBorderOffset < 0 {
                dummy.size.y = -portBorderOffset
            }
            dummyPort.side = .SOUTH
            if !explicitAnchor {
                anchor.y = portSize.y
            }
            anchor.y -= portSize.y
            
        case .SOUTH:
            dummy.setProperty(InternalProperties.IN_LAYER_CONSTRAINT, InLayerConstraint.BOTTOM)
            dummy.size.x = portSize.x
            if portBorderOffset < 0 {
                dummy.size.y = -portBorderOffset
            }
            dummyPort.side = .NORTH
            if !explicitAnchor {
                anchor.y = 0
            }
            
        default:
            break
        }
        
        dummyPort.position = anchor
        dummy.setProperty(LayeredOptions.PORT_ANCHOR, anchor)
        
        if portConstraints.isOrderFixed() {
            var informationAboutIt: Double = 0
            
            if portConstraints == .FIXED_ORDER && propertyHolder.hasProperty(LayeredOptions.PORT_INDEX) {
                let index: Int = propertyHolder.getProperty(LayeredOptions.PORT_INDEX) as? Int ?? 0

                switch finalExternalPortSide {
                case .NORTH, .EAST:
                    informationAboutIt = Double(index)
                case .SOUTH, .WEST:
                    informationAboutIt = -1.0 * Double(index)
                default:
                    break
                }
            } else {
                switch finalExternalPortSide {
                case .WEST, .EAST:
                    informationAboutIt = portPosition.y
                    if portConstraints.isRatioFixed() {
                        informationAboutIt /= portNodeSize.y
                    }
                case .NORTH, .SOUTH:
                    informationAboutIt = portPosition.x
                    if portConstraints.isRatioFixed() {
                        informationAboutIt /= portNodeSize.x
                    }
                default:
                    break
                }
            }
            
            dummy.setProperty(InternalProperties.PORT_RATIO_OR_POSITION, informationAboutIt)
        }
        
        dummy.setProperty(InternalProperties.EXT_PORT_SIDE, finalExternalPortSide)
        
        return dummy
    }
    
    package static func getExternalPortPosition(_ graph: LGraph, _ portDummy: LNode, _ portWidth: Double, _ portHeight: Double) -> KVector {
        let portPosition = portDummy.position.clone()
        portPosition.x += portDummy.size.x / 2.0
        portPosition.y += portDummy.size.y / 2.0
        let portOffset = portDummy.getProperty(LayeredOptions.PORT_BORDER_OFFSET) as? Double ?? 0.0
        
        let graphSize = graph.size
        let padding = graph.padding
        let graphOffset = graph.offset
        
        switch portDummy.getProperty(InternalProperties.EXT_PORT_SIDE) as? PortSide {
        case .NORTH:
            portPosition.x += padding.left + graphOffset.x - (portWidth / 2.0)
            portPosition.y = -portHeight - portOffset
            portDummy.position.y = -(padding.top + portOffset + graphOffset.y)
            
        case .EAST:
            portPosition.x = graphSize.x + padding.left + padding.right + portOffset
            portPosition.y += padding.top + graphOffset.y - (portHeight / 2.0)
            portDummy.position.x = graphSize.x + padding.right + portOffset - graphOffset.x
            
        case .SOUTH:
            portPosition.x += padding.left + graphOffset.x - (portWidth / 2.0)
            portPosition.y = graphSize.y + padding.top + padding.bottom + portOffset
            portDummy.position.y = graphSize.y + padding.bottom + portOffset - graphOffset.y
            
        case .WEST:
            portPosition.x = -portWidth - portOffset
            portPosition.y += padding.top + graphOffset.y - (portHeight / 2.0)
            portDummy.position.x = -(padding.left + portOffset + graphOffset.x)
            
        default:
            break
        }
        
        return portPosition
    }
    
    // MARK: - Compound Graphs
    
    package static func isDescendant(_ child: LNode?, _ parent: LNode?) -> Bool {
        guard let child = child, let parent = parent else { return false }
        var current: LNode = child
        var next = current.getGraph()?.getParentNode()
        while let n = next {
            current = n
            if current === parent {
                return true
            }
            next = current.getGraph()?.getParentNode()
        }
        return false
    }
    
    package static func changeCoordSystem(_ point: KVector, oldGraph: LGraph, newGraph: LGraph) {
        if oldGraph === newGraph {
            return
        }

        var graph: LGraph = oldGraph
        var node: LNode?

        repeat {
            point.add(graph.offset)
            node = graph.getParentNode()
            if let n = node {
                let padding = graph.padding
                point.add(padding.left, padding.top)
                point.add(n.position)
                if let g = n.getGraph() { graph = g }
            }
        } while node != nil

        graph = newGraph
        repeat {
            point.sub(graph.offset)
            node = graph.getParentNode()
            if let n = node {
                let padding = graph.padding
                point.sub(padding.left, padding.top)
                point.sub(n.position)
                if let g = n.getGraph() { graph = g }
            }
        } while node != nil
    }
    
    // MARK: - Other Stuff
    
    package static func getIndividualOrInherited<T>(_ node: LNode, property: IProperty) -> T {
        var result: T?

        if node.hasProperty(CoreOptions.SPACING_INDIVIDUAL) {
            if let individualSpacings = node.getProperty(CoreOptions.SPACING_INDIVIDUAL) as? IPropertyHolder {
                if individualSpacings.hasProperty(property) {
                    result = individualSpacings.getProperty(property) as? T
                }
            }
        }

        if result == nil, let graph = node.getGraph() {
            result = graph.getProperty(property) as? T
        }

        guard let result = result else {
            assertionFailure("getIndividualOrInherited: no value found for property '\(property)' on node or its graph")
            // All current callers expect Double; fall back to zero.
            if let fallback = 0.0 as? T { return fallback }
            if let fallback = 0 as? T { return fallback }
            // Should never be reached — all current callers use numeric types.
            assertionFailure("getIndividualOrInherited: no fallback available for \(T.self)")
            return property.defaultValue as! T
        }
        return result
    }
    
    package static func getDirection(_ graph: LGraph) -> Direction {
        let direction: Direction = graph.getProperty(LayeredOptions.DIRECTION) as? Direction ?? .UNDEFINED
        if direction == .UNDEFINED {
            let aspectRatio: Double = graph.getProperty(LayeredOptions.ASPECT_RATIO) as? Double ?? 1.0
            if aspectRatio >= 1 {
                return .RIGHT
            } else {
                return .DOWN
            }
        }
        return direction
    }
    
    package static func getMinimalModelOrder(_ graph: LGraph) -> Int {
        var order = Int.max
        for node in graph.getLayerlessNodes() {
            if node.hasProperty(InternalProperties.MODEL_ORDER) {
                let nodeOrder: Int = node.getProperty(InternalProperties.MODEL_ORDER) as? Int ?? Int.max
                order = min(order, nodeOrder)
            }
        }
        return order
    }
}

// MARK: - Extensions

// PortSide.fromDirection() and .opposed() are already defined in org_eclipse_elk_core_options_PortSide.swift

// Direction.isVertical() is already defined in org_eclipse_elk_core_options_Direction.swift

extension Layer: Sequence {
    package func makeIterator() -> IndexingIterator<[LNode]> {
        return getNodes().makeIterator()
    }
}

extension LNode {
    package convenience init(layeredGraph: LGraph) {
        self.init(layeredGraph)
    }
}
