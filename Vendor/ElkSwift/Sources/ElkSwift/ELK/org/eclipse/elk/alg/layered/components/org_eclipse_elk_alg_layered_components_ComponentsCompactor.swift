// Copyright (c) 2016 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

import Foundation

// MARK: - Core Classes

package class ComponentsCompactor {

    package var compactor: OneDimensionalComponentsCompaction<LNode, Set<LEdge>>?

    package var yetAnotherOffset = KVector()
    package var compactedGraphSize = KVector()

    package var graphTopLeft = KVector(x: Double.greatestFiniteMagnitude, y: Double.greatestFiniteMagnitude)
    package var graphBottomRight = KVector(x: -Double.greatestFiniteMagnitude, y: -Double.greatestFiniteMagnitude)

    package static let EPSILON: Double = 0.0001

    package var offset: KVector { return yetAnotherOffset }
    package var graphSize: KVector { return compactedGraphSize }

    package func getOffset() -> KVector {
        return yetAnotherOffset
    }

    package func getGraphSize() -> KVector {
        return compactedGraphSize
    }

    package func compact(_ graphs: [LGraph], _ originalGraphsSize: KVector, _ spacing: Double) {

        // Determine extreme points of the current diagram
        graphTopLeft = KVector(x: Double.greatestFiniteMagnitude, y: Double.greatestFiniteMagnitude)
        graphBottomRight = KVector(x: -Double.greatestFiniteMagnitude, y: -Double.greatestFiniteMagnitude)

        for graph in graphs {
            for node in graph.layerlessNodes {
                let margin = node.margin
                graphTopLeft.x = min(graphTopLeft.x, node.position.x - margin.left)
                graphTopLeft.y = min(graphTopLeft.y, node.position.y - margin.top)
                graphBottomRight.x = max(graphBottomRight.x, node.position.x + node.size.x + margin.right)
                graphBottomRight.y = max(graphBottomRight.y, node.position.y + node.size.y + margin.bottom)
            }
        }

        // Create connected components
        let ccs = InternalConnectedComponents()
        for graph in graphs {
            let component = transformLGraph(graph)
            ccs.components.append(component)
            if !component.externalExtensionSides.isEmpty {
                component.containsRegularNodes = true
            }
        }

        // Initialize and execute compaction
        compactor = OneDimensionalComponentsCompaction<LNode, Set<LEdge>>.initCompaction(ccs, spacing: spacing)
        compactor?.compact(monitor: BasicProgressMonitor())

        yetAnotherOffset = KVector()
        guard let compactor = compactor else { return }
        compactedGraphSize = compactor.getGraphSize()

        // Apply positions
        for cc in ccs.components {
            let ccOffset = compactor.getOffset(cc)
            LGraphUtil.offsetGraph(cc.graph, offsetx: ccOffset.x, offsety: ccOffset.y)

            for node in cc.getNodes() {
                if node.type == NodeType.EXTERNAL_PORT {
                    if let extPortSide: PortSide = node.getProperty(InternalProperties.EXT_PORT_SIDE) {
                        let newPos = getExternalPortPosition(node.position, extPortSide)
                        node.position = newPos
                    }
                }
            }
        }

        // External edges contribute to graph size
        for cc in ccs.components {
            for edge in cc.getExternalEdges() {
                guard let src = edge.source, let tgt = edge.target else { continue }
                let vc = KVectorChain(edge.bendPoints.elements)
                vc.insert(src.absoluteAnchor, at: 0)
                vc.append(tgt.absoluteAnchor)

                var last: KVector?
                for v in vc {
                    if let lastV = last {
                        if DoubleMath.fuzzyEquals(lastV.x, v.x, ComponentsCompactor.EPSILON) {
                            yetAnotherOffset.x = min(yetAnotherOffset.x, lastV.x)
                            compactedGraphSize.x = max(compactedGraphSize.x, lastV.x)
                        } else if DoubleMath.fuzzyEquals(lastV.y, v.y, ComponentsCompactor.EPSILON) {
                            yetAnotherOffset.y = min(yetAnotherOffset.y, lastV.y)
                            compactedGraphSize.y = max(compactedGraphSize.y, lastV.y)
                        }
                    }
                    last = v
                }
            }
        }

        yetAnotherOffset.negate()
        compactedGraphSize = compactedGraphSize.clone().add(yetAnotherOffset)
    }

    package func transformLGraph(_ graph: LGraph) -> InternalComponent {
        let component = InternalComponent(graph: graph)

        if !component.containsRegularNodes {
            _ = createDummyNode(graph)
        }

        let hullPoints = componentHullPoints(graph)

        var externalExtensionsByDir: [Direction: [LEdge]] = [:]
        var outerSegments = OuterSegments()

        for node in graph.layerlessNodes {
            for port in node.ports {
                for edge in port.outgoingEdges {
                    if isExternalEdge(edge) {
                        let iee = transformLEdge(edge, hullPoints: hullPoints, outerSegments: &outerSegments)
                        let dir = portSideToDirection(iee.externalPortSide)
                        externalExtensionsByDir[dir, default: []].append(iee.edge)
                    }
                }
            }
        }

        var extensions: [InternalUnionExternalExtension] = []
        let extSides: Set<PortSide> = component.externalExtensionSides
        for ps in extSides {
            let minVal = outerSegments.minValues[ps.ordinal]
            let maxVal = outerSegments.maxValues[ps.ordinal]
            let extent = outerSegments.extent[ps.ordinal]

            var extensionRect: ElkRectangle?
            var placeholderRect: ElkRectangle?

            switch ps {
            case .WEST:
                let rect = ElkRectangle(x: graphTopLeft.x, y: minVal,
                                        width: hullPoints.topLeft.x - graphTopLeft.x,
                                        height: maxVal - minVal)
                extensionRect = rect
                placeholderRect = ElkRectangle(x: graphTopLeft.x, y: minVal,
                                               width: extent, height: maxVal - minVal)
                hullPoints.addPoint(Point(x: rect.x + rect.width, y: rect.y))
                hullPoints.addPoint(Point(x: rect.x + rect.width, y: rect.y + rect.height))

            case .EAST:
                let rect = ElkRectangle(x: hullPoints.bottomRight.x, y: minVal,
                                        width: graphBottomRight.x - hullPoints.bottomRight.x,
                                        height: maxVal - minVal)
                extensionRect = rect
                placeholderRect = ElkRectangle(x: graphBottomRight.x - extent, y: minVal,
                                               width: extent, height: maxVal - minVal)
                hullPoints.addPoint(Point(x: rect.x, y: rect.y))
                hullPoints.addPoint(Point(x: rect.x, y: rect.y + rect.height))

            case .NORTH:
                let rect = ElkRectangle(x: minVal, y: graphTopLeft.y,
                                        width: maxVal - minVal,
                                        height: hullPoints.topLeft.y - graphTopLeft.y)
                extensionRect = rect
                placeholderRect = ElkRectangle(x: minVal, y: graphTopLeft.y,
                                               width: maxVal - minVal, height: extent)
                hullPoints.addPoint(Point(x: rect.x, y: rect.y + rect.height))
                hullPoints.addPoint(Point(x: rect.x + rect.width, y: rect.y + rect.height))

            case .SOUTH:
                let rect = ElkRectangle(x: minVal, y: hullPoints.bottomRight.y,
                                        width: maxVal - minVal,
                                        height: graphBottomRight.y - hullPoints.bottomRight.y)
                extensionRect = rect
                placeholderRect = ElkRectangle(x: minVal, y: graphBottomRight.y - extent,
                                               width: maxVal - minVal, height: extent)
                hullPoints.addPoint(Point(x: rect.x, y: rect.y))
                hullPoints.addPoint(Point(x: rect.x + rect.width, y: rect.y))
            default:
                break
            }

            if let extRect = extensionRect {
                let iuee = InternalUnionExternalExtension()
                iuee.side = ps
                iuee.extensionRect = extRect
                iuee.placeholderRect = placeholderRect
                iuee.edges = Set(externalExtensionsByDir[portSideToDirection(ps)] ?? [])
                extensions.append(iuee)
            }
        }

        component.externalExtensions = extensions
        // component.rectilinearConvexHull = RectilinearConvexHull.of(hullPoints.points).splitIntoRectangles()

        return component
    }

    package func createDummyNode(_ graph: LGraph) -> LNode {
        assert(graph.layerlessNodes.count == 1)

        let extPortDummy = graph.layerlessNodes[0]
        let dummy = LNode(graph)
        graph.layerlessNodes.append(dummy)

        dummy.size.x = max(1, extPortDummy.size.x)
        dummy.size.y = max(1, extPortDummy.size.y)
        dummy.position = extPortDummy.position.clone()

        let extPortSide: PortSide? = extPortDummy.getProperty(InternalProperties.EXT_PORT_SIDE)
        switch extPortSide {
        case .WEST:
            dummy.position.x += 2
        case .NORTH:
            dummy.position.y += 2
        case .EAST:
            dummy.position.x -= 2
        case .SOUTH:
            dummy.position.y -= 2
        default:
            break
        }

        let dummyPort = LPort()
        dummyPort.node = dummy
        let dummyEdge = LEdge()
        let extPortDummyPort = extPortDummy.ports[0]
        dummyEdge.source = extPortDummyPort
        dummyEdge.target = dummyPort
        dummyPort.position = extPortDummyPort.position.clone()
        dummyPort.anchor = extPortDummyPort.anchor.clone()

        return dummy
    }

    package func componentHullPoints(_ graph: LGraph) -> Hullpoints {
        let pts = Hullpoints()

        for node in graph.layerlessNodes {
            guard node.type != .EXTERNAL_PORT else { continue }

            addLGraphElementBounds(pts, node, KVector())

            for port in node.ports {
                for edge in port.outgoingEdges {
                    guard !isExternalEdge(edge) else { continue }

                    for bp in edge.bendPoints {
                        pts.addPoint(Point(x: bp.x, y: bp.y))
                    }
                }
            }
        }

        return pts
    }

    package func addLGraphElementBounds(_ pts: Hullpoints, _ element: LShape, _ offset: KVector) {
        var margins = LMargin()
        if let node = element as? LNode {
            margins = node.margin
        } else if let port = element as? LPort {
            margins = port.margin
        }

        pts.addPoint(Point(x: element.position.x - margins.left + offset.x,
                           y: element.position.y - margins.top + offset.y))
        pts.addPoint(Point(x: element.position.x - margins.left + offset.x,
                           y: element.position.y + element.size.y + margins.bottom + offset.y))
        pts.addPoint(Point(x: element.position.x + element.size.x + margins.right + offset.x,
                           y: element.position.y - margins.top + offset.y))
        pts.addPoint(Point(x: element.position.x + element.size.x + margins.right + offset.x,
                           y: element.position.y + element.size.y + margins.bottom + offset.y))
    }

    package func isExternalEdge(_ edge: LEdge) -> Bool {
        return edge.source?.node?.type == .EXTERNAL_PORT || edge.target?.node?.type == .EXTERNAL_PORT
    }

    package func transformLEdge(_ externalEdge: LEdge, hullPoints: Hullpoints, outerSegments: inout OuterSegments) -> InternalExternalExtension {
        let externalExtension = InternalExternalExtension(edge: externalEdge)

        let segments = edgeToSegments(externalEdge, externalExtension: externalExtension)

        let thickness: Double = max(externalEdge.getProperty(LayeredOptions.EDGE_THICKNESS) ?? 1.0, 1)
        for segment in segments.innerSegments {
            let rect = segmentToRectangle(segment.first, segment.second, thickness)
            hullPoints.addRect(rect)
        }

        let side = externalExtension.externalPortSide
        let outerSegmentRect = segmentToRectangle(segments.outerSegment.first, segments.outerSegment.second, thickness)

        if side == .WEST || side == .EAST {
            outerSegments.minValues[side.ordinal] = min(outerSegments.minValues[side.ordinal], outerSegmentRect.y)
            outerSegments.maxValues[side.ordinal] = max(outerSegments.maxValues[side.ordinal], outerSegmentRect.y + outerSegmentRect.height)
        } else {
            outerSegments.minValues[side.ordinal] = min(outerSegments.minValues[side.ordinal], outerSegmentRect.x)
            outerSegments.maxValues[side.ordinal] = max(outerSegments.maxValues[side.ordinal], outerSegmentRect.x + outerSegmentRect.width)
        }

        var extent = -Double.greatestFiniteMagnitude
        guard let extPortNode = externalExtension.externalPort.node else { return externalExtension }
        let margins = extPortNode.margin
        switch side {
        case .WEST:
            extent = margins.right
        case .EAST:
            extent = margins.left
        case .NORTH:
            extent = margins.bottom
        case .SOUTH:
            extent = margins.top
        default:
            break
        }
        outerSegments.extent[side.ordinal] = max(outerSegments.extent[side.ordinal], extent)

        return externalExtension
    }

    package func segmentToRectangle(_ p1: KVector, _ p2: KVector, _ extent: Double) -> ElkRectangle {
        return ElkRectangle(x: min(p1.x, p2.x) - extent / 2,
                            y: min(p1.y, p2.y) - extent / 2,
                            width: abs(p1.x - p2.x) + extent,
                            height: abs(p1.y - p2.y) + extent)
    }

    package func edgeToSegments(_ edge: LEdge, externalExtension: InternalExternalExtension) -> Segments {
        let externalPort = externalExtension.externalPort
        let externalPortSide = externalExtension.externalPortSide

        guard let edgeSource = edge.source, let edgeTarget = edge.target else { return Segments() }

        var p1 = edgeSource.absoluteAnchor
        var p2 = edgeTarget.absoluteAnchor

        if externalPort === edgeSource {
            p1 = getExternalPortPosition(p1, externalPortSide)
            p2 = getPortPositionOnMargin(edgeTarget)
        } else {
            p1 = getPortPositionOnMargin(edgeSource)
            p2 = getExternalPortPosition(p2, externalPortSide)
        }

        let points = KVectorChain(edge.bendPoints.elements)
        points.insert(p1, at: 0)
        points.append(p2)

        let outerSegmentIsFirst = (edgeSource === externalPort)

        let segments = Segments()
        for i in 0..<points.count - 1 {
            let segment = (first: points[i], second: points[i + 1])

            if (outerSegmentIsFirst && i == 0) || (!outerSegmentIsFirst && i == points.count - 2) {
                segments.outerSegment = segment
            } else {
                segments.innerSegments.append(segment)
            }
        }

        return segments
    }

    package func getExternalPortPosition(_ pos: KVector, _ ps: PortSide) -> KVector {
        switch ps {
        case .NORTH:
            return KVector(x: pos.x, y: min(graphTopLeft.y, pos.y))
        case .EAST:
            return KVector(x: max(graphBottomRight.x, pos.x), y: pos.y)
        case .SOUTH:
            return KVector(x: pos.x, y: max(graphBottomRight.y, pos.y))
        case .WEST:
            return KVector(x: min(pos.x, graphTopLeft.x), y: pos.y)
        default:
            return pos.clone()
        }
    }

    package func getPortPositionOnMargin(_ port: LPort) -> KVector {
        let pos = port.absoluteAnchor.clone()
        guard let portNode = port.node else { return pos }
        let margins = portNode.margin

        switch port.side {
        case .NORTH:
            pos.y -= margins.top
        case .EAST:
            pos.x += margins.right
        case .SOUTH:
            pos.y += margins.bottom
        case .WEST:
            pos.x -= margins.left
        default:
            break
        }

        return pos
    }

    package func portSideToDirection(_ side: PortSide) -> Direction {
        switch side {
        case .NORTH:
            return .UP
        case .WEST:
            return .LEFT
        case .EAST:
            return .RIGHT
        case .SOUTH:
            return .DOWN
        default:
            return .UNDEFINED
        }
    }
}

// MARK: - Interface Implementations

package class InternalConnectedComponents {
    package var components: [InternalComponent] = []
    package var containsExternalPorts = false

    package func getComponents() -> [InternalComponent] {
        return components
    }

    package func isContainsExternalExtensions() -> Bool {
        return containsExternalPorts
    }
}

package class InternalComponent {
    package var graph: LGraph
    package var containsRegularNodes: Bool

    package var rectilinearConvexHull: [ElkRectangle] = []
    package var externalExtensions: [InternalUnionExternalExtension] = []

    package init(graph: LGraph) {
        self.graph = graph
        containsRegularNodes = false
        for node in graph.layerlessNodes {
            if node.type == .NORMAL {
                containsRegularNodes = true
                break
            }
        }
    }

    package var externalExtensionSides: Set<PortSide> {
        return graph.getProperty(InternalProperties.EXT_PORT_CONNECTIONS) ?? []
    }

    package func getHull() -> [ElkRectangle] {
        return rectilinearConvexHull
    }

    package func getExternalExtensions() -> [InternalUnionExternalExtension] {
        return externalExtensions
    }

    package func getNodes() -> [LNode] {
        return graph.layerlessNodes
    }

    package func getExternalEdges() -> [LEdge] {
        var edges: [LEdge] = []
        for ee in externalExtensions {
            edges.append(contentsOf: ee.edges)
        }
        return edges
    }
}

package class InternalUnionExternalExtension {
    package var edges: Set<LEdge> = []
    package var side: PortSide = .UNDEFINED
    package var extensionRect: ElkRectangle = ElkRectangle()
    package var placeholderRect: ElkRectangle?

    package init() {}

    package func getRepresentative() -> Set<LEdge> {
        return edges
    }

    package func getRepresentor() -> ElkRectangle {
        return extensionRect
    }

    package func getDirection() -> Direction {
        switch side {
        case .NORTH: return .UP
        case .WEST: return .LEFT
        case .EAST: return .RIGHT
        case .SOUTH: return .DOWN
        default: return .UNDEFINED
        }
    }

    package func getPlaceholder() -> ElkRectangle? {
        return placeholderRect
    }
}

package class InternalExternalExtension {
    package var edge: LEdge
    package var externalPort: LPort
    package var externalPortSide: PortSide

    package var externalExtension: ElkRectangle = ElkRectangle()
    package var parent: ElkRectangle = ElkRectangle()

    package init(edge: LEdge) {
        self.edge = edge
        if let src = edge.source, let srcNode = src.node, srcNode.type == .EXTERNAL_PORT {
            externalPort = src
            externalPortSide = srcNode.getProperty(InternalProperties.EXT_PORT_SIDE) ?? .UNDEFINED
        } else if let tgt = edge.target, let tgtNode = tgt.node, tgtNode.type == .EXTERNAL_PORT {
            externalPort = tgt
            externalPortSide = tgtNode.getProperty(InternalProperties.EXT_PORT_SIDE) ?? .UNDEFINED
        } else {
            assertionFailure("Edge is not an external edge.")
            externalPort = LPort()
            externalPortSide = .UNDEFINED
        }
    }

    package func getDirection() -> Direction {
        switch externalPortSide {
        case .NORTH: return .UP
        case .WEST: return .LEFT
        case .EAST: return .RIGHT
        case .SOUTH: return .DOWN
        default: return .UNDEFINED
        }
    }
}

package class Hullpoints {
    package var points: [Point] = []
    package var topLeft = KVector(x: Double.greatestFiniteMagnitude, y: Double.greatestFiniteMagnitude)
    package var bottomRight = KVector(x: -Double.greatestFiniteMagnitude, y: -Double.greatestFiniteMagnitude)

    package func addPoint(_ newElement: Point) {
        topLeft.x = min(topLeft.x, newElement.x)
        topLeft.y = min(topLeft.y, newElement.y)
        bottomRight.x = max(bottomRight.x, newElement.x)
        bottomRight.y = max(bottomRight.y, newElement.y)
        points.append(newElement)
    }

    package func addKVector(_ vector: KVector) {
        addPoint(Point(x: vector.x, y: vector.y))
    }

    package func addRect(_ rect: ElkRectangle) {
        addPoint(Point(x: rect.x, y: rect.y))
        addPoint(Point(x: rect.x + rect.width, y: rect.y))
        addPoint(Point(x: rect.x, y: rect.y + rect.height))
        addPoint(Point(x: rect.x + rect.width, y: rect.y + rect.height))
    }
}

package class Segments {
    package var innerSegments: [(first: KVector, second: KVector)] = []
    package var outerSegment: (first: KVector, second: KVector) = (KVector(), KVector())
}

package class OuterSegments {
    package var minValues: [Double] = Array(repeating: Double.greatestFiniteMagnitude, count: 5)
    package var maxValues: [Double] = Array(repeating: -Double.greatestFiniteMagnitude, count: 5)
    package var extent: [Double] = Array(repeating: -Double.greatestFiniteMagnitude, count: 5)
}
