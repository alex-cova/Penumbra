import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_GraphTransformer {

    package var mode: org_eclipse_elk_alg_layered_intermediate_GraphTransformer_Mode = .defaults

    package init() {}

    package init(_ mode: org_eclipse_elk_alg_layered_intermediate_GraphTransformer_Mode) {
        self.mode = mode
    }

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("Graph transformation (\(mode))", 1)

        // Collect all nodes (layerless + in layers)
        var nodes = [LNode]()
        nodes.append(contentsOf: layeredGraph.layerlessNodes)
        for layer in layeredGraph.layers {
            nodes.append(contentsOf: layer.nodes)
        }

        // Default is READING_DIRECTION per ELK's Layered.melk definition
        let congruency = layeredGraph.getProperty(LayeredOptions.DIRECTION_CONGRUENCY) as? DirectionCongruency ?? .READING_DIRECTION
        if congruency == .READING_DIRECTION {
            let direction = layeredGraph.getProperty(LayeredOptions.DIRECTION) as? Direction ?? .UNDEFINED
            switch direction {
            case .LEFT:
                mirrorAllX(layeredGraph, nodes)
            case .DOWN:
                transposeAll(layeredGraph, nodes)
            case .UP:
                if mode == .TO_INTERNAL_LTR {
                    transposeAll(layeredGraph, nodes)
                    mirrorAllY(layeredGraph, nodes)
                } else {
                    mirrorAllY(layeredGraph, nodes)
                    transposeAll(layeredGraph, nodes)
                }
            default:
                break
            }
        } else {
            let direction = layeredGraph.getProperty(LayeredOptions.DIRECTION) as? Direction ?? .UNDEFINED
            if mode == .TO_INTERNAL_LTR {
                switch direction {
                case .LEFT:
                    mirrorAllX(layeredGraph, nodes)
                    mirrorAllY(layeredGraph, nodes)
                case .DOWN:
                    rotate90Clockwise(layeredGraph, nodes)
                case .UP:
                    rotate90CounterClockwise(layeredGraph, nodes)
                default:
                    break
                }
            } else {
                switch direction {
                case .LEFT:
                    mirrorAllX(layeredGraph, nodes)
                    mirrorAllY(layeredGraph, nodes)
                case .DOWN:
                    rotate90CounterClockwise(layeredGraph, nodes)
                case .UP:
                    rotate90Clockwise(layeredGraph, nodes)
                default:
                    break
                }
            }
        }

        monitor.done()
    }

    // MARK: - Convenience

    private func rotate90Clockwise(_ graph: LGraph, _ nodes: [LNode]) {
        transposeAll(graph, nodes)
        mirrorAllX(graph, nodes)
    }

    private func rotate90CounterClockwise(_ graph: LGraph, _ nodes: [LNode]) {
        mirrorAllX(graph, nodes)
        transposeAll(graph, nodes)
    }

    private func mirrorAllX(_ graph: LGraph, _ nodes: [LNode]) {
        mirrorX(nodes, graph)
        mirrorXSpacing(graph.getPadding())
        if let padding = graph.getProperty(LayeredOptions.NODE_LABELS_PADDING) as? Spacing {
            mirrorXSpacing(padding)
        }
    }

    private func mirrorAllY(_ graph: LGraph, _ nodes: [LNode]) {
        mirrorY(nodes, graph)
        mirrorYSpacing(graph.getPadding())
        if let padding = graph.getProperty(LayeredOptions.NODE_LABELS_PADDING) as? Spacing {
            mirrorYSpacing(padding)
        }
    }

    private func transposeAll(_ graph: LGraph, _ nodes: [LNode]) {
        transposeNodes(nodes)
        transposeEdgeLabelPlacement(graph)
        transposeVec(graph.getOffset())
        transposeVec(graph.getSize())
        transposeSpacing(graph.getPadding())
        if let padding = graph.getProperty(LayeredOptions.NODE_LABELS_PADDING) as? Spacing {
            transposeSpacing(padding)
        }
    }

    // MARK: - Mirror Horizontally

    private func mirrorX(_ nodes: [LNode], _ graph: LGraph) {
        var offset: Double = 0

        if graph.getSize().x == 0 {
            for node in nodes {
                offset = max(offset, node.getPosition().x + node.getSize().x + node.getMargin().right)
            }
        } else {
            offset = graph.getSize().x - graph.getOffset().x
        }
        offset -= graph.getOffset().x

        for node in nodes {
            mirrorXVec(node.getPosition(), offset - node.getSize().x)
            mirrorXSpacing(node.getPadding())
            mirrorNodeLabelPlacementX(node)

            if node.getAllProperties().keys.contains(LayeredOptions.POSITION.id) {
                if let pos = node.getProperty(LayeredOptions.POSITION) as? KVector {
                    mirrorXVec(pos, offset - node.getSize().x)
                }
            }

            // Mirror alignment
            let alignment = node.getProperty(LayeredOptions.ALIGNMENT) as? Alignment
            if alignment == .left {
                node.setProperty(LayeredOptions.ALIGNMENT, value: Alignment.right)
            } else if alignment == .right {
                node.setProperty(LayeredOptions.ALIGNMENT, value: Alignment.left)
            }

            let nodeSize = node.getSize()
            for port in node.getPorts() {
                mirrorXVec(port.getPosition(), nodeSize.x - port.getSize().x)
                mirrorXVec(port.getAnchor(), port.getSize().x)
                mirrorPortSideX(port)
                reverseIndex(port)

                for edge in port.outgoingEdges {
                    for bendPoint in edge.bendPoints {
                        mirrorXVec(bendPoint, offset)
                    }

                    if let junctionPoints = edge.getProperty(LayeredOptions.JUNCTION_POINTS) as? KVectorChain {
                        for jp in junctionPoints {
                            mirrorXVec(jp, offset)
                        }
                    }

                    for label in edge.labels {
                        mirrorXVec(label.getPosition(), offset - label.getSize().x)
                    }
                }

                for label in port.getLabels() {
                    mirrorXVec(label.getPosition(), port.getSize().x - label.getSize().x)
                }
            }

            if node.type == .externalPort {
                mirrorExternalPortSideX(node)
                mirrorLayerConstraintX(node)
            }

            for label in node.getLabels() {
                mirrorNodeLabelPlacementX(label)
                mirrorXVec(label.getPosition(), nodeSize.x - label.getSize().x)
            }
        }
    }

    private func mirrorXVec(_ v: KVector, _ offset: Double) {
        v.x = offset - v.x
    }

    private func mirrorXSpacing(_ spacing: Spacing) {
        let oldLeft = spacing.left
        let oldRight = spacing.right
        spacing.left = oldRight
        spacing.right = oldLeft
    }

    private func mirrorNodeLabelPlacementX(_ shape: LShape) {
        if !shape.hasProperty(LayeredOptions.NODE_LABELS_PLACEMENT) { return }

        if var oldPlacement = shape.getProperty(LayeredOptions.NODE_LABELS_PLACEMENT) as? NodeLabelPlacement {
            if oldPlacement.contains(.hLeft) {
                oldPlacement.remove(.hLeft)
                oldPlacement.insert(.hRight)
            } else if oldPlacement.contains(.hRight) {
                oldPlacement.remove(.hRight)
                oldPlacement.insert(.hLeft)
            }
            shape.setProperty(LayeredOptions.NODE_LABELS_PLACEMENT, value: oldPlacement)
        }
    }

    private func mirrorPortSideX(_ port: LPort) {
        port.setSide(getMirroredPortSideX(port.getSide()))
    }

    private func mirrorExternalPortSideX(_ node: LNode) {
        if let side = node.getProperty(InternalProperties.EXT_PORT_SIDE) as? PortSide {
            node.setProperty(InternalProperties.EXT_PORT_SIDE, value: getMirroredPortSideX(side))
        }
    }

    private func getMirroredPortSideX(_ side: PortSide) -> PortSide {
        switch side {
        case .EAST: return .WEST
        case .WEST: return .EAST
        default: return side
        }
    }

    private func mirrorLayerConstraintX(_ node: LNode) {
        let constraint = node.getProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT) as? LayerConstraint ?? .NONE
        switch constraint {
        case .FIRST:
            node.setProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT, value: LayerConstraint.LAST)
        case .FIRST_SEPARATE:
            node.setProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT, value: LayerConstraint.LAST_SEPARATE)
        case .LAST:
            node.setProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT, value: LayerConstraint.FIRST)
        case .LAST_SEPARATE:
            node.setProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT, value: LayerConstraint.FIRST_SEPARATE)
        default:
            break
        }
    }

    // MARK: - Mirror Vertically

    private func mirrorY(_ nodes: [LNode], _ graph: LGraph) {
        var offset: Double = 0
        if graph.getSize().y == 0 {
            for node in nodes {
                offset = max(offset, node.getPosition().y + node.getSize().y + node.getMargin().bottom)
            }
        } else {
            offset = graph.getSize().y - graph.getOffset().y
        }
        offset -= graph.getOffset().y

        for node in nodes {
            mirrorYVec(node.getPosition(), offset - node.getSize().y)
            mirrorYSpacing(node.getPadding())
            mirrorNodeLabelPlacementY(node)

            if node.getAllProperties().keys.contains(LayeredOptions.POSITION.id) {
                if let pos = node.getProperty(LayeredOptions.POSITION) as? KVector {
                    mirrorYVec(pos, offset - node.getSize().y)
                }
            }

            let alignment = node.getProperty(LayeredOptions.ALIGNMENT) as? Alignment
            if alignment == .top {
                node.setProperty(LayeredOptions.ALIGNMENT, value: Alignment.bottom)
            } else if alignment == .bottom {
                node.setProperty(LayeredOptions.ALIGNMENT, value: Alignment.top)
            }

            let nodeSize = node.getSize()
            for port in node.getPorts() {
                mirrorYVec(port.getPosition(), nodeSize.y - port.getSize().y)
                mirrorYVec(port.getAnchor(), port.getSize().y)
                mirrorPortSideY(port)
                reverseIndex(port)

                for edge in port.outgoingEdges {
                    for bendPoint in edge.bendPoints {
                        mirrorYVec(bendPoint, offset)
                    }

                    if let junctionPoints = edge.getProperty(LayeredOptions.JUNCTION_POINTS) as? KVectorChain {
                        for jp in junctionPoints {
                            mirrorYVec(jp, offset)
                        }
                    }

                    for label in edge.labels {
                        mirrorYVec(label.getPosition(), offset - label.getSize().y)
                    }
                }

                for label in port.getLabels() {
                    mirrorYVec(label.getPosition(), port.getSize().y - label.getSize().y)
                }
            }

            if node.type == .externalPort {
                mirrorExternalPortSideY(node)
                mirrorInLayerConstraintY(node)
            }

            for label in node.getLabels() {
                mirrorNodeLabelPlacementY(label)
                mirrorYVec(label.getPosition(), nodeSize.y - label.getSize().y)
            }
        }
    }

    private func mirrorYVec(_ v: KVector, _ offset: Double) {
        v.y = offset - v.y
    }

    private func mirrorYSpacing(_ spacing: Spacing) {
        let oldTop = spacing.top
        let oldBottom = spacing.bottom
        spacing.top = oldBottom
        spacing.bottom = oldTop
    }

    private func mirrorNodeLabelPlacementY(_ shape: LShape) {
        if !shape.hasProperty(LayeredOptions.NODE_LABELS_PLACEMENT) { return }

        if var oldPlacement = shape.getProperty(LayeredOptions.NODE_LABELS_PLACEMENT) as? NodeLabelPlacement {
            if oldPlacement.contains(.vTop) {
                oldPlacement.remove(.vTop)
                oldPlacement.insert(.vBottom)
            } else if oldPlacement.contains(.vBottom) {
                oldPlacement.remove(.vBottom)
                oldPlacement.insert(.vTop)
            }
            shape.setProperty(LayeredOptions.NODE_LABELS_PLACEMENT, value: oldPlacement)
        }
    }

    private func mirrorPortSideY(_ port: LPort) {
        port.setSide(getMirroredPortSideY(port.getSide()))
    }

    private func mirrorExternalPortSideY(_ node: LNode) {
        if let side = node.getProperty(InternalProperties.EXT_PORT_SIDE) as? PortSide {
            node.setProperty(InternalProperties.EXT_PORT_SIDE, value: getMirroredPortSideY(side))
        }
    }

    private func getMirroredPortSideY(_ side: PortSide) -> PortSide {
        switch side {
        case .NORTH: return .SOUTH
        case .SOUTH: return .NORTH
        default: return side
        }
    }

    private func mirrorInLayerConstraintY(_ node: LNode) {
        let constraint = node.getProperty(InternalProperties.IN_LAYER_CONSTRAINT) as? InLayerConstraint ?? .NONE
        switch constraint {
        case .TOP:
            node.setProperty(InternalProperties.IN_LAYER_CONSTRAINT, value: InLayerConstraint.BOTTOM)
        case .BOTTOM:
            node.setProperty(InternalProperties.IN_LAYER_CONSTRAINT, value: InLayerConstraint.TOP)
        default:
            break
        }
    }

    // MARK: - Transpose

    private func transposeNodes(_ nodes: [LNode]) {
        for node in nodes {
            transposeVec(node.getPosition())
            transposeVec(node.getSize())
            transposeSpacing(node.getPadding())
            transposeNodeLabelPlacement(node)
            transposeProperties(node)

            for port in node.getPorts() {
                transposeVec(port.getPosition())
                transposeVec(port.getAnchor())
                transposeVec(port.getSize())
                transposePortSide(port)
                reverseIndex(port)

                for edge in port.outgoingEdges {
                    for bendPoint in edge.bendPoints {
                        transposeVec(bendPoint)
                    }

                    if let junctionPoints = edge.getProperty(LayeredOptions.JUNCTION_POINTS) as? KVectorChain {
                        for jp in junctionPoints {
                            transposeVec(jp)
                        }
                    }

                    for label in edge.labels {
                        transposeVec(label.getPosition())
                        transposeVec(label.getSize())
                    }
                }

                for label in port.getLabels() {
                    transposeVec(label.getPosition())
                    transposeVec(label.getSize())
                }
            }

            if node.type == .externalPort {
                transposeExternalPortSide(node)
                transposeLayerConstraint(node)
            }

            for label in node.getLabels() {
                transposeNodeLabelPlacement(label)
                transposeVec(label.getSize())
                transposeVec(label.getPosition())
            }
        }
    }

    private func transposeVec(_ v: KVector) {
        let temp = v.x
        v.x = v.y
        v.y = temp
    }

    private func transposeSpacing(_ spacing: Spacing) {
        let oldTop = spacing.top
        let oldBottom = spacing.bottom
        let oldLeft = spacing.left
        let oldRight = spacing.right

        spacing.top = oldLeft
        spacing.bottom = oldRight
        spacing.left = oldTop
        spacing.right = oldBottom
    }

    private func transposeNodeLabelPlacement(_ shape: LShape) {
        if !shape.hasProperty(LayeredOptions.NODE_LABELS_PLACEMENT) { return }
        guard let oldPlacement = shape.getProperty(LayeredOptions.NODE_LABELS_PLACEMENT) as? NodeLabelPlacement else { return }
        if oldPlacement.isEmpty { return }

        var newPlacement: NodeLabelPlacement = []

        // Inside or outside
        if oldPlacement.contains(.inside) {
            newPlacement.insert(.inside)
        } else {
            newPlacement.insert(.outside)
        }

        // Horizontal priority
        if !oldPlacement.contains(.hPriority) {
            newPlacement.insert(.hPriority)
        }

        // Horizontal alignment -> vertical
        if oldPlacement.contains(.hLeft) {
            newPlacement.insert(.vTop)
        } else if oldPlacement.contains(.hCenter) {
            newPlacement.insert(.vCenter)
        } else if oldPlacement.contains(.hRight) {
            newPlacement.insert(.vBottom)
        }

        // Vertical alignment -> horizontal
        if oldPlacement.contains(.vTop) {
            newPlacement.insert(.hLeft)
        } else if oldPlacement.contains(.vCenter) {
            newPlacement.insert(.hCenter)
        } else if oldPlacement.contains(.vBottom) {
            newPlacement.insert(.hRight)
        }

        shape.setProperty(LayeredOptions.NODE_LABELS_PLACEMENT, value: newPlacement)
    }

    private func transposePortSide(_ port: LPort) {
        port.setSide(transposedPortSide(port.getSide()))
    }

    private func transposedPortSide(_ side: PortSide) -> PortSide {
        switch side {
        case .NORTH: return .WEST
        case .WEST: return .NORTH
        case .SOUTH: return .EAST
        case .EAST: return .SOUTH
        default: return .UNDEFINED
        }
    }

    private func transposeEdgeLabelPlacement(_ graph: LGraph) {
        if let oldSide = graph.getProperty(LayeredOptions.EDGE_LABELS_SIDE_SELECTION) as? EdgeLabelSideSelection {
            graph.setProperty(LayeredOptions.EDGE_LABELS_SIDE_SELECTION, value: oldSide.transpose())
        }
    }

    private func transposeExternalPortSide(_ node: LNode) {
        if let side = node.getProperty(InternalProperties.EXT_PORT_SIDE) as? PortSide {
            node.setProperty(InternalProperties.EXT_PORT_SIDE, value: transposedPortSide(side))
        }
    }

    private func transposeLayerConstraint(_ node: LNode) {
        let layerConstraint = node.getProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT) as? LayerConstraint ?? .NONE
        let inLayerConstraint = node.getProperty(InternalProperties.IN_LAYER_CONSTRAINT) as? InLayerConstraint ?? .NONE

        if layerConstraint == .FIRST_SEPARATE {
            node.setProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT, value: LayerConstraint.NONE)
            node.setProperty(InternalProperties.IN_LAYER_CONSTRAINT, value: InLayerConstraint.TOP)
        } else if layerConstraint == .LAST_SEPARATE {
            node.setProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT, value: LayerConstraint.NONE)
            node.setProperty(InternalProperties.IN_LAYER_CONSTRAINT, value: InLayerConstraint.BOTTOM)
        } else if inLayerConstraint == .TOP {
            node.setProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT, value: LayerConstraint.FIRST_SEPARATE)
            node.setProperty(InternalProperties.IN_LAYER_CONSTRAINT, value: InLayerConstraint.NONE)
        } else if inLayerConstraint == .BOTTOM {
            node.setProperty(LayeredOptions.LAYERING_LAYER_CONSTRAINT, value: LayerConstraint.LAST_SEPARATE)
            node.setProperty(InternalProperties.IN_LAYER_CONSTRAINT, value: InLayerConstraint.NONE)
        }
    }

    private func transposeProperties(_ node: LNode) {
        // Transpose MIN_HEIGHT and MIN_WIDTH (NODE_SIZE_MINIMUM)
        if let minSize = node.getProperty(LayeredOptions.NODE_SIZE_MINIMUM) as? KVector {
            node.setProperty(LayeredOptions.NODE_SIZE_MINIMUM, value: KVector(minSize.y, minSize.x))
        }

        // Transpose ALIGNMENT
        let alignment = node.getProperty(LayeredOptions.ALIGNMENT) as? Alignment
        switch alignment {
        case .left:
            node.setProperty(LayeredOptions.ALIGNMENT, value: Alignment.top)
        case .right:
            node.setProperty(LayeredOptions.ALIGNMENT, value: Alignment.bottom)
        case .top:
            node.setProperty(LayeredOptions.ALIGNMENT, value: Alignment.left)
        case .bottom:
            node.setProperty(LayeredOptions.ALIGNMENT, value: Alignment.right)
        default:
            break
        }

        // POSITION
        if node.getAllProperties().keys.contains(LayeredOptions.POSITION.id) {
            if let pos = node.getProperty(LayeredOptions.POSITION) as? KVector {
                let tmp = pos.x
                pos.x = pos.y
                pos.y = tmp
            }
        }
    }

    private func reverseIndex(_ port: LPort) {
        if let index = port.getProperty(LayeredOptions.PORT_INDEX) as? Int {
            port.setProperty(LayeredOptions.PORT_INDEX, value: -index)
        }
    }
}
