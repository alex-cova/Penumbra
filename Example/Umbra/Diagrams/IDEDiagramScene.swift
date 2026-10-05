import CoreGraphics
import DiagramKit
import Foundation

/// Edge routing for diagram documents; the session caches routes by this fingerprint.
nonisolated enum IDEDiagramRouting {
    static func geometryFingerprint(for document: IDEDiagramDocument) -> UInt64 {
        let frames = document.nodes.map { ($0.id, $0.frame) }
        let edges = document.edges.map {
            (id: $0.id, source: $0.sourceID, destination: $0.destinationID, sourceAnchor: EdgeAnchor.auto, targetAnchor: EdgeAnchor.auto)
        }
        return EdgeRouteCache.fingerprint(
            nodeFrames: frames,
            edges: edges,
            style: document.canvas.edgeRouting,
            avoidObstacles: document.canvas.avoidObstacles
        )
    }

    static func computeRoutes(for document: IDEDiagramDocument) -> [(id: UUID, route: EdgeRoute)] {
        let frames = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0.frame) })
        let context = EdgeRoutingContext(
            style: document.canvas.edgeRouting,
            obstacles: document.nodes.map(\.frame),
            avoidObstacles: document.canvas.avoidObstacles
        )
        return document.edges.compactMap { edge in
            guard let source = frames[edge.sourceID], let target = frames[edge.destinationID] else { return nil }
            return (edge.id, EdgeRouting.route(source: source, target: target, context: context))
        }
    }

    static let provider = DiagramRoutingProvider<IDEDiagramDocument>(
        fingerprint: { geometryFingerprint(for: $0) },
        computeRoutes: { computeRoutes(for: $0) }
    )
}

/// Colors per kind of box, chosen for the app's light and dark appearance.
nonisolated struct IDEDiagramPalette: Sendable {
    let fill: UInt32
    let stroke: UInt32
    let header: UInt32

    static func colors(for kind: IDEDiagramNodeKind, dark: Bool) -> IDEDiagramPalette {
        if dark {
            switch kind {
            case .classType, .abstractClass: return IDEDiagramPalette(fill: 0x2B2F3A, stroke: 0x8E9BB8, header: 0x363D4D)
            case .interfaceType: return IDEDiagramPalette(fill: 0x25332D, stroke: 0x6FBF93, header: 0x2F4A3E)
            case .enumType: return IDEDiagramPalette(fill: 0x383224, stroke: 0xD0A24A, header: 0x4A412B)
            case .recordType: return IDEDiagramPalette(fill: 0x322C3F, stroke: 0xAB8BDB, header: 0x42395A)
            case .annotationType: return IDEDiagramPalette(fill: 0x3A2B34, stroke: 0xD98BB0, header: 0x4C3644)
            case .externalType: return IDEDiagramPalette(fill: 0x2A2B2E, stroke: 0x7C7E86, header: 0x2A2B2E)
            case .project: return IDEDiagramPalette(fill: 0x25324A, stroke: 0x6A9BEF, header: 0x25324A)
            case .library: return IDEDiagramPalette(fill: 0x2B2D33, stroke: 0x8A8F9C, header: 0x2B2D33)
            case .replacedLibrary: return IDEDiagramPalette(fill: 0x3B3023, stroke: 0xE8A04A, header: 0x3B3023)
            case .unresolvedLibrary: return IDEDiagramPalette(fill: 0x3D2727, stroke: 0xE56B6B, header: 0x3D2727)
            }
        }
        switch kind {
        case .classType, .abstractClass: return IDEDiagramPalette(fill: 0xF8FAFD, stroke: 0x5B6B8A, header: 0xE4EAF6)
        case .interfaceType: return IDEDiagramPalette(fill: 0xF4FBF7, stroke: 0x3F8F66, header: 0xDDF1E5)
        case .enumType: return IDEDiagramPalette(fill: 0xFCF8EE, stroke: 0xB07B22, header: 0xF3E6C8)
        case .recordType: return IDEDiagramPalette(fill: 0xF8F4FC, stroke: 0x7B5BB0, header: 0xE8DEF5)
        case .annotationType: return IDEDiagramPalette(fill: 0xFCF4F8, stroke: 0xB05B84, header: 0xF4DDE8)
        case .externalType: return IDEDiagramPalette(fill: 0xF4F4F5, stroke: 0x9A9AA2, header: 0xF4F4F5)
        case .project: return IDEDiagramPalette(fill: 0xEAF1FD, stroke: 0x3B6FD1, header: 0xEAF1FD)
        case .library: return IDEDiagramPalette(fill: 0xF4F4F6, stroke: 0x7A7F8C, header: 0xF4F4F6)
        case .replacedLibrary: return IDEDiagramPalette(fill: 0xFFF3E3, stroke: 0xD98A1E, header: 0xFFF3E3)
        case .unresolvedLibrary: return IDEDiagramPalette(fill: 0xFDECEC, stroke: 0xD14343, header: 0xFDECEC)
        }
    }

    @MainActor
    static func theme(dark: Bool) -> DiagramTheme {
        var theme = DiagramThemeCatalog.resolved(id: DiagramThemeCatalog.light.id, forDarkAppearance: dark)
        let scheme = IDEAppearance.scheme
        theme.canvasBackground = codable(scheme.editor)
        theme.defaultEdgeStroke = codable(scheme.muted)
        theme.accent = codable(scheme.accent)
        theme.selectionStroke = codable(scheme.accent)
        return theme
    }

    static func codable(_ hex: UInt32) -> CodableColor {
        CodableColor(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// The edge and node descriptors the canvas draws from. Rebuilt on every pass: a diagram is a few hundred
/// boxes at most, and routes are cached by the session.
nonisolated enum IDEDiagramSceneBuilder {
    static func build(
        document: IDEDiagramDocument,
        routes: [(id: UUID, route: EdgeRoute)],
        selection: Set<UUID>,
        theme: DiagramTheme,
        dark: Bool
    ) -> DiagramScene {
        let routeMap = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, $0.route) })
        let nodeIDs = Set(document.nodes.map(\.id))
        let nodes = document.nodes.enumerated().map { index, node in
            let colors = IDEDiagramPalette.colors(for: node.kind, dark: dark)
            return SceneNode(
                id: node.id,
                frame: node.frame,
                shape: .roundedRectangle(cornerRadius: 6),
                style: DiagramShapeStyle(fill: IDEDiagramPalette.codable(colors.fill), stroke: IDEDiagramPalette.codable(colors.stroke)),
                zIndex: index,
                title: node.title,
                compartments: node.attributes + node.methods,
                interactive: selection.contains(node.id)
            )
        }
        let edges = document.edges.compactMap { edge -> SceneEdge? in
            guard let route = routeMap[edge.id] else { return nil }
            let style = EdgeHighlightResolver.sceneEdgeStyle(
                edgeID: edge.id,
                sourceID: edge.sourceID,
                destinationID: edge.destinationID,
                selection: selection,
                theme: theme,
                nodeIDs: nodeIDs
            )
            return SceneEdge(
                id: edge.id,
                sourceID: edge.sourceID,
                destinationID: edge.destinationID,
                route: route,
                isDashed: edge.kind.isDashed,
                stroke: style.stroke,
                lineWidth: style.lineWidth,
                label: edge.label,
                labelPoint: midpoint(of: route.points),
                selected: style.selected
            )
        }
        return DiagramScene(
            fingerprint: IDEDiagramRouting.geometryFingerprint(for: document),
            nodes: nodes,
            edges: edges,
            dirtyNodeIDs: []
        )
    }

    /// The point half way along the polyline, where an edge's label sits.
    static func midpoint(of points: [CGPoint]) -> CGPoint {
        guard points.count >= 2 else { return points.first ?? .zero }
        var lengths: [CGFloat] = []
        var total: CGFloat = 0
        for index in 1..<points.count {
            let length = hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
            lengths.append(length)
            total += length
        }
        var remaining = total / 2
        for (offset, length) in lengths.enumerated() {
            if remaining <= length, length > 0 {
                let t = remaining / length
                let a = points[offset]
                let b = points[offset + 1]
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            remaining -= length
        }
        return points[points.count - 1]
    }
}
