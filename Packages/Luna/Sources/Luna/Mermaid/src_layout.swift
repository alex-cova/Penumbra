// Ported from original/src/layout.ts
import Foundation

private typealias _ParsedGraph = original_src_types.MermaidGraph
private typealias _ParsedNode = original_src_types.MermaidNode
private typealias _ParsedEdge = original_src_types.MermaidEdge

private typealias _ElkNode = [String: Any]

public struct _PositionedPointPayload: Sendable {
    public var x: Double
    public var y: Double
}

public struct _PositionedNodePayload: Sendable {
    public var id: String
    public var label: String
    public var shape: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var inlineStyle: [String: String]
}

public struct _PositionedEdgePayload: Sendable {
    public var source: String
    public var target: String
    public var label: String?
    public var style: String
    public var hasArrowStart: Bool
    public var hasArrowEnd: Bool
    /// "none", "arrow", "circle" or "cross" at the edge start.
    public var startMarker: String
    /// "none", "arrow", "circle" or "cross" at the edge end.
    public var endMarker: String
    public var points: [_PositionedPointPayload]
    public var labelPosition: _PositionedPointPayload?
    public var inlineStyle: [String: String]?

    public init(
        source: String,
        target: String,
        label: String? = nil,
        style: String,
        hasArrowStart: Bool,
        hasArrowEnd: Bool,
        startMarker: String = "none",
        endMarker: String = "none",
        points: [_PositionedPointPayload] = [],
        labelPosition: _PositionedPointPayload? = nil,
        inlineStyle: [String: String]? = nil
    ) {
        self.source = source
        self.target = target
        self.label = label
        self.style = style
        self.hasArrowStart = hasArrowStart
        self.hasArrowEnd = hasArrowEnd
        self.startMarker = startMarker
        self.endMarker = endMarker
        self.points = points
        self.labelPosition = labelPosition
        self.inlineStyle = inlineStyle
    }
}

private func _asDict(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

private func _asDictArray(_ value: Any?) -> [[String: Any]] {
    if let direct = value as? [[String: Any]] { return direct }
    if let anyArray = value as? [Any] { return anyArray.compactMap { $0 as? [String: Any] } }
    return []
}

private func _asString(_ value: Any?) -> String? {
    value as? String
}

private func _asDouble(_ value: Any?) -> Double? {
    if let d = value as? Double { return d }
    if let i = value as? Int { return Double(i) }
    if let f = value as? Float { return Double(f) }
    if let n = value as? NSNumber { return n.doubleValue }
    return nil
}

private func _mapDirection(_ direction: original_src_types.Direction) -> String {
    switch direction {
    case .LR: return "RIGHT"
    case .RL: return "LEFT"
    case .BT: return "UP"
    case .TD, .TB: return "DOWN"
    }
}

private func _nodeSize(_ node: _ParsedNode) -> (width: Double, height: Double) {
    let metrics = original_src_text_metrics.measureMultilineText(
        node.label,
        fontSize: original_src_styles.FONT_SIZES.nodeLabel,
        fontWeight: original_src_styles.FONT_WEIGHTS.nodeLabel
    )
    // Match TS NODE_PADDING: horizontal=20 (*2=40), vertical=10 (*2=20)
    var width = metrics.width + 40
    var height = metrics.height + 20

    switch node.shape {
    case .diamond:
        let side = max(width, height) + 24  // TS diamondExtra=24
        width = side; height = side
    case .circle:
        let d = ceil(sqrt(width * width + height * height)) + 8
        width = d; height = d
    case .doublecircle:
        let d = ceil(sqrt(width * width + height * height)) + 8 + 12
        width = d; height = d
    case .hexagon:
        width += 20  // TS adds NODE_PADDING.horizontal
    case .trapezoid, .trapezoidAlt, .leanRight, .leanLeft:
        width += 20
    case .asymmetric:
        width += 12
    case .cylinder:
        height += 14
    case .stateStart, .stateEnd:
        return (28, 28)
    default: break
    }

    width = max(width, 60)
    height = max(height, 36)
    return (width, height)
}

/// Build a map of subgraph ID -> set of all transitively contained node IDs
private func _buildSubgraphOwnership(
    _ subs: [original_src_types.MermaidSubgraph]
) -> [String: Set<String>] {
    var result: [String: Set<String>] = [:]
    for sub in subs {
        result[sub.id] = _allNodeIds(in: sub)
        for (k, v) in _buildSubgraphOwnership(sub.children) {
            result[k] = v
        }
    }
    return result
}

private func _allNodeIds(in sub: original_src_types.MermaidSubgraph) -> Set<String> {
    var ids = Set(sub.nodeIds)
    for child in sub.children {
        ids.formUnion(_allNodeIds(in: child))
    }
    return ids
}

private func _subgraphContainsNode(_ sub: original_src_types.MermaidSubgraph, nodeId: String) -> Bool {
    if sub.nodeIds.contains(nodeId) { return true }
    return sub.children.contains { _subgraphContainsNode($0, nodeId: nodeId) }
}

public struct _PositionedGroupPayload: Sendable {
    public var id: String
    public var label: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var headerHeight: Double = 28
    public var children: [_PositionedGroupPayload]
    /// Lane groups (swimlanes) render beneath everything with a class fill or clear.
    public var isLane: Bool = false
    /// CSS fill from the lane's first class; nil renders clear, never white.
    public var laneFill: String? = nil
}

/// Collect all leaf-node children from the ELK result, including those nested inside compound nodes.
/// Returns tuples of (child dict, cumulative parent offset).
private func _collectAllChildren(
    _ elkNode: [String: Any],
    nodeById: [String: original_src_types.MermaidNode],
    parentOffset: (x: Double, y: Double) = (0, 0)
) -> [([String: Any], (x: Double, y: Double))] {
    var result: [([String: Any], (x: Double, y: Double))] = []
    for child in _asDictArray(elkNode["children"]) {
        guard let id = _asString(child["id"]) else { continue }
        if nodeById[id] != nil && _asDictArray(child["children"]).isEmpty {
            // Leaf node
            result.append((child, parentOffset))
        } else {
            // Compound node — recurse into its children with accumulated offset
            let cx = (_asDouble(child["x"]) ?? 0) + parentOffset.x
            let cy = (_asDouble(child["y"]) ?? 0) + parentOffset.y
            result += _collectAllChildren(child, nodeById: nodeById, parentOffset: (cx, cy))
        }
    }
    return result
}

/// Routed edge points collected from the layout result, grouped by original edge index.
/// The compound engine routes every edge end to end, so each edge has one `sections` entry.
private struct _EdgeSegments {
    var external: [_PositionedPointPayload]?
    var labelPosition: _PositionedPointPayload?
}

/// Recursively collect routed edge points from the layout result.
/// Edge IDs are "e{index}" matching the source edge order.
private func _collectEdgeSegments(
    _ elkNode: [String: Any],
    segments: inout [Int: _EdgeSegments],
    offsetX: Double,
    offsetY: Double
) {
    for elkEdge in _asDictArray(elkNode["edges"]) {
        guard let eid = _asString(elkEdge["id"]) else { continue }

        // Parse edge ID: "e3" → 3.
        guard eid.hasPrefix("e"), let edgeIndex = Int(eid.dropFirst()) else { continue }

        // Extract points from sections
        var points: [_PositionedPointPayload] = []
        if let section = _asDictArray(elkEdge["sections"]).first {
            if let s = _asDict(section["startPoint"]) {
                points.append(_PositionedPointPayload(
                    x: (_asDouble(s["x"]) ?? 0) + offsetX,
                    y: (_asDouble(s["y"]) ?? 0) + offsetY
                ))
            }
            for bp in _asDictArray(section["bendPoints"]) {
                points.append(_PositionedPointPayload(
                    x: (_asDouble(bp["x"]) ?? 0) + offsetX,
                    y: (_asDouble(bp["y"]) ?? 0) + offsetY
                ))
            }
            if let e = _asDict(section["endPoint"]) {
                points.append(_PositionedPointPayload(
                    x: (_asDouble(e["x"]) ?? 0) + offsetX,
                    y: (_asDouble(e["y"]) ?? 0) + offsetY
                ))
            }
        }

        // Extract label position
        var labelPos: _PositionedPointPayload?
        if let label = _asDictArray(elkEdge["labels"]).first {
            if let lx = _asDouble(label["x"]), let ly = _asDouble(label["y"]) {
                let lw = _asDouble(label["width"]) ?? 0
                let lh = _asDouble(label["height"]) ?? 0
                labelPos = _PositionedPointPayload(
                    x: lx + lw / 2 + offsetX,
                    y: ly + lh / 2 + offsetY
                )
            }
        }

        // Store the routed points.
        if segments[edgeIndex] == nil {
            segments[edgeIndex] = _EdgeSegments()
        }
        segments[edgeIndex]?.external = points
        if let lp = labelPos {
            segments[edgeIndex]?.labelPosition = lp
        }
    }

    // Recurse into compound children with accumulated offset
    for child in _asDictArray(elkNode["children"]) {
        if !_asDictArray(child["children"]).isEmpty {
            let cx = (_asDouble(child["x"]) ?? 0) + offsetX
            let cy = (_asDouble(child["y"]) ?? 0) + offsetY
            _collectEdgeSegments(child, segments: &segments, offsetX: cx, offsetY: cy)
        }
    }
}

/// Extract positioned subgraph groups from the ELK result.
private func _extractSubgraphGroups(
    _ elkNode: [String: Any],
    source: _ParsedGraph,
    graphHeight: Double,
    parentOffset: (x: Double, y: Double) = (0, 0)
) -> [_PositionedGroupPayload] {
    let subgraphIds = Set(_allSubgraphIds(source.subgraphs))
    var groups: [_PositionedGroupPayload] = []
    for child in _asDictArray(elkNode["children"]) {
        guard let id = _asString(child["id"]) else { continue }
        let isLane = (child["luna.lane"] as? Bool) == true
        // Synthetic default lanes exist only in the layout dict, not the source model.
        guard subgraphIds.contains(id) || isLane else { continue }
        let rawX = (_asDouble(child["x"]) ?? 0) + parentOffset.x
        let rawY = (_asDouble(child["y"]) ?? 0) + parentOffset.y
        let w = _asDouble(child["width"]) ?? 0
        let h = _asDouble(child["height"]) ?? 0
        let label = _findSubgraphLabel(id, in: source.subgraphs) ?? (isLane ? "" : id)
        let childGroups = _extractSubgraphGroups(
            child, source: source, graphHeight: graphHeight,
            parentOffset: (rawX, rawY)
        )
        var payload = _PositionedGroupPayload(
            id: id, label: label,
            x: rawX, y: rawY,
            width: w, height: h,
            children: childGroups
        )
        payload.isLane = isLane
        if isLane, let className = source.classAssignments[id],
           let fill = source.classDefs[className]?["fill"], !fill.isEmpty {
            payload.laneFill = fill
        }
        groups.append(payload)
    }
    return groups
}

private func _allSubgraphIds(_ subs: [original_src_types.MermaidSubgraph]) -> [String] {
    subs.flatMap { [$0.id] + _allSubgraphIds($0.children) }
}

private func _findSubgraphLabel(_ id: String, in subs: [original_src_types.MermaidSubgraph]) -> String? {
    for sub in subs {
        if sub.id == id { return sub.label }
        if let found = _findSubgraphLabel(id, in: sub.children) { return found }
    }
    return nil
}

private func _resolveInlineStyle(_ id: String, _ graph: _ParsedGraph) -> [String: String] {
    var style: [String: String] = [:]
    if let className = graph.classAssignments[id], let classStyle = graph.classDefs[className] {
        for (k, v) in classStyle { style[k] = v }
    }
    if let nodeStyle = graph.nodeStyles[id] {
        for (k, v) in nodeStyle { style[k] = v }
    }
    return style
}

/// Resolve inline styles for an edge from linkStyles map.
/// Default link style (key -1) is applied first, then index-specific overrides.
private func _resolveEdgeStyle(edgeIndex: Int, graph: _ParsedGraph) -> [String: String]? {
    var result: [String: String]?
    if let defaultStyle = graph.linkStyles[-1] {
        result = defaultStyle
    }
    if let indexStyle = graph.linkStyles[edgeIndex] {
        if var r = result {
            for (k, v) in indexStyle { r[k] = v }
            result = r
        } else {
            result = indexStyle
        }
    }
    return result
}

private func _extractPositionedGraph(
    _ source: _ParsedGraph,
    _ laidOut: _ElkNode,
    diagramType: DiagramType
) -> PositionedGraph {
    let nodeById = Dictionary(source.nodesInOrder.map { ($0.id, $0.node) }, uniquingKeysWith: { _, last in last })
    let graphHeight = _asDouble(laidOut["height"]) ?? 0

    // Collect nodes from root and all compound children (subgraphs) recursively
    let allChildren = _collectAllChildren(laidOut, nodeById: nodeById)

    // ELK coordinates (y=0 at top) — rendering handles CGContext flip
    var nodes: [_PositionedNodePayload] = allChildren.compactMap { (child, parentOffset) in
        guard
            let id = _asString(child["id"]),
            let original = nodeById[id]
        else { return nil }
        let w = _asDouble(child["width"]) ?? _nodeSize(original).width
        let h = _asDouble(child["height"]) ?? _nodeSize(original).height
        let rawX = (_asDouble(child["x"]) ?? 0) + parentOffset.x
        let rawY = (_asDouble(child["y"]) ?? 0) + parentOffset.y
        return _PositionedNodePayload(
            id: id,
            label: original.label,
            shape: original.shape.rawValue,
            x: rawX,
            y: rawY,
            width: w,
            height: h,
            inlineStyle: _resolveInlineStyle(id, source)
        )
    }

    // Collect each edge's routed points from all levels (root + subgraphs).
    // The compound engine routes every edge end to end, so each edge has one
    // `sections` entry; Pele's port spreading keeps every line distinct.
    var segmentsByIndex: [Int: _EdgeSegments] = [:]
    _collectEdgeSegments(laidOut, segments: &segmentsByIndex, offsetX: 0, offsetY: 0)

    // Extract subgraph groups.
    var groups = _extractSubgraphGroups(laidOut, source: source, graphHeight: graphHeight)

    var edges: [_PositionedEdgePayload] = []
    for (idx, edge) in source.edges.enumerated() {
        let seg = segmentsByIndex[idx]
        let points: [_PositionedPointPayload] = seg?.external ?? []

        // Label position from the engine, or fall back to path midpoint later.
        let labelPos = seg?.labelPosition

        var finalLabelPos: _PositionedPointPayload? = nil
        if edge.label != nil, !points.isEmpty {
            finalLabelPos = labelPos
        }

        edges.append(
            _PositionedEdgePayload(
                source: edge.source,
                target: edge.target,
                label: edge.label,
                style: edge.style.rawValue,
                hasArrowStart: edge.hasArrowStart,
                hasArrowEnd: edge.hasArrowEnd,
                startMarker: edge.startMarker.rawValue,
                endMarker: edge.endMarker.rawValue,
                points: points,
                labelPosition: finalLabelPos,
                inlineStyle: _resolveEdgeStyle(edgeIndex: idx, graph: source)
            )
        )
    }

    // Shape clipping: adjust edge endpoints to actual shape boundaries
    let nodeMap = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    for i in edges.indices {
        guard edges[i].points.count >= 2 else { continue }
        if let srcNode = nodeMap[edges[i].source] {
            edges[i].points = _clipEdgeToShape(points: edges[i].points, node: srcNode, isStart: true)
        }
        if let tgtNode = nodeMap[edges[i].target] {
            edges[i].points = _clipEdgeToShape(points: edges[i].points, node: tgtNode, isStart: false)
        }
    }

    // Compute label positions for edges that don't have an ELK-provided position
    for i in edges.indices {
        if let label = edges[i].label, !label.isEmpty, edges[i].points.count >= 2,
           edges[i].labelPosition == nil {
            edges[i].labelPosition = _edgePathMidpoint(edges[i].points, direction: source.direction)
        }
    }

    // Calculate final bounds including all edge points and labels
    var minX: Double = 0
    var minY: Double = 0
    var maxX = _asDouble(laidOut["width"]) ?? 0
    var maxY = graphHeight
    let arrowMargin: Double = 10
    let padding: Double = 40
    let labelHalfW: Double = 60  // estimated half-width of label pill
    let labelHalfH: Double = 16  // estimated half-height of label pill
    for edge in edges {
        for p in edge.points {
            maxX = max(maxX, p.x + arrowMargin + padding)
            maxY = max(maxY, p.y + arrowMargin + padding)
        }
        if let lp = edge.labelPosition {
            minX = min(minX, lp.x - labelHalfW - padding)
            minY = min(minY, lp.y - labelHalfH - padding)
            maxX = max(maxX, lp.x + labelHalfW + padding)
            maxY = max(maxY, lp.y + labelHalfH + padding)
        }
    }

    // If any label extends past origin, shift everything right/down
    if minX < 0 || minY < 0 {
        let shiftX = minX < 0 ? -minX : 0
        let shiftY = minY < 0 ? -minY : 0
        for i in nodes.indices {
            nodes[i].x += shiftX
            nodes[i].y += shiftY
        }
        for i in edges.indices {
            for j in edges[i].points.indices {
                edges[i].points[j].x += shiftX
                edges[i].points[j].y += shiftY
            }
            if var lp = edges[i].labelPosition {
                lp.x += shiftX
                lp.y += shiftY
                edges[i].labelPosition = lp
            }
        }
        for i in groups.indices {
            groups[i].x += shiftX
            groups[i].y += shiftY
        }
        maxX += shiftX
        maxY += shiftY
    }

    let content: PositionedContent
    switch diagramType {
    case .stateDiagram:
        content = .stateDiagram(nodes: nodes, edges: edges, groups: groups)
    default:
        content = .flowchart(nodes: nodes, edges: edges, groups: groups)
    }
    return PositionedGraph(
        diagram: MermaidGraph(type: diagramType, payload: source),
        width: maxX,
        height: maxY,
        content: content
    )
}

public func layoutGraphSync(
    _ graph: MermaidGraph,
    _ options: RenderOptions = RenderOptions()
) throws -> PositionedGraph {
    // layout.ts re-exports layout-engine.ts; route through the same public entry.
    return try _layoutGraphSyncEntry(graph, options)
}

/// Overload that accepts LayoutConfig to control ELK spacing parameters.
public func layoutGraphSync(
    _ graph: MermaidGraph,
    config: LayoutConfig
) throws -> PositionedGraph {
    return try _layoutGraphSyncWithConfig(graph, config)
}

private func _layoutGraphSyncWithConfig(
    _ graph: MermaidGraph,
    _ config: LayoutConfig
) throws -> PositionedGraph {
    guard let parsed = graph.payload as? _ParsedGraph else {
        return PositionedGraph(diagram: graph)
    }

    // One compound builder for every graph: nested subgraphs become nested compounds,
    // each laid out in its own direction, cross-border edges routed through ports.
    // Swimlanes run the lane engine over their top-level subgraphs.
    var elkGraph = _buildCompoundGraph(parsed, lanes: graph.type == .swimlane)

    // Override ELK spacing options with LayoutConfig values
    _applyLayoutConfig(config, to: &elkGraph)

    do {
        let laidOut = try lunaLayoutSync(elkGraph)
        return _extractPositionedGraph(parsed, laidOut, diagramType: graph.type)
    } catch {
        var flatGraph = _buildFlatElkGraph(parsed)
        _applyLayoutConfig(config, to: &flatGraph)
        let laidOut = try lunaLayoutSync(flatGraph)
        return _extractPositionedGraph(parsed, laidOut, diagramType: graph.type)
    }
}

/// Patch ELK layout options on a built graph with LayoutConfig values.
private func _applyLayoutConfig(_ config: LayoutConfig, to elkGraph: inout _ElkNode) {
    var opts = (elkGraph["layoutOptions"] as? [String: String]) ?? [:]
    let p = Int(config.padding)
    opts["elk.spacing.nodeNode"] = "\(Int(config.nodeSpacing))"
    opts["elk.layered.spacing.nodeNodeBetweenLayers"] = "\(Int(config.layerSpacing))"
    opts["elk.padding"] = "[top=\(p),left=\(p),bottom=\(p),right=\(p)]"
    opts["elk.spacing.componentComponent"] = "\(Int(config.componentSpacing))"
    elkGraph["layoutOptions"] = opts
}

public func layoutGraphWithDiagnosticsSync(
    _ graph: MermaidGraph,
    _ options: RenderOptions = RenderOptions()
) throws -> PositionedGraph {
    return try _layoutGraphWithDiagnosticsEntry(graph, options)
}

private func _layoutGraphSyncEntry(
    _ graph: MermaidGraph,
    _ options: RenderOptions
) throws -> PositionedGraph {
    try _layoutGraphSyncFromLayoutEngine(graph, options)
}

private func _layoutGraphWithDiagnosticsEntry(
    _ graph: MermaidGraph,
    _ options: RenderOptions
) throws -> PositionedGraph {
    try _layoutGraphWithDiagnosticsSyncFromLayoutEngine(graph, options)
}

/// Spread width for a node from its shape, across the flow direction.
private func _nodeSpan(_ node: _ParsedNode, size: (width: Double, height: Double), direction: original_src_types.Direction) -> Double {
    shapeSpan(shape: node.shape.rawValue, w: size.width, h: size.height,
              sideways: direction == .LR || direction == .RL)
}

/// Build one compound graph for the layout engine: nested subgraphs become nested
/// compounds (each keeping its own `elk.direction` override), internal edges ride inside
/// their subgraph dicts, and root-level plus cross-hierarchy edges ride at the root.
/// Leaf nodes carry `luna.span` from their shape; groups carry `luna.minWidth`.
private func _buildCompoundGraph(_ graph: _ParsedGraph, lanes: Bool = false) -> _ElkNode {
    let subgraphOwnership = _buildSubgraphOwnership(graph.subgraphs)
    let allClaimedNodes = Set(subgraphOwnership.values.flatMap { $0 })
    let nodeById = Dictionary(graph.nodesInOrder.map { ($0.id, $0.node) }, uniquingKeysWith: { _, last in last })

    func _deepestSubgraph(for nodeId: String, in subs: [original_src_types.MermaidSubgraph]) -> String? {
        for sub in subs {
            if let deeper = _deepestSubgraph(for: nodeId, in: sub.children) { return deeper }
            if sub.nodeIds.contains(nodeId) { return sub.id }
        }
        return nil
    }

    // Classify edges into: internal (same subgraph), root-level (no subgraph),
    // cross-hierarchy (different subgraph levels). Matching TS edge ordering:
    // root-level edges first, then cross-hierarchy edges.
    var edgesBySubgraph: [String: [[String: Any]]] = [:]
    var rootLevelEdges: [[String: Any]] = []
    var crossHierarchyEdges: [[String: Any]] = []
    var includedEdgeIndices = Set<Int>()
    for (idx, edge) in graph.edges.enumerated() {
        let srcSub = _deepestSubgraph(for: edge.source, in: graph.subgraphs)
        let tgtSub = _deepestSubgraph(for: edge.target, in: graph.subgraphs)
        var edict: [String: Any] = ["id": "e\(idx)", "sources": [edge.source], "targets": [edge.target]]
        if let label = edge.label, !label.isEmpty {
            let m = original_src_text_metrics.measureMultilineText(label, fontSize: original_src_styles.FONT_SIZES.edgeLabel, fontWeight: original_src_styles.FONT_WEIGHTS.edgeLabel)
            edict["labels"] = [["text": label, "width": m.width + 8, "height": m.height + 6, "layoutOptions": ["elk.edgeLabels.inline": "true", "elk.edgeLabels.placement": "CENTER"]] as [String: Any]]
        }
        if let s = srcSub, let t = tgtSub, s == t {
            // Internal edge: both endpoints in same subgraph
            edgesBySubgraph[s, default: []].append(edict)
            includedEdgeIndices.insert(idx)
        } else if srcSub == nil && tgtSub == nil {
            // Root-level edge: neither endpoint in a subgraph
            rootLevelEdges.append(edict)
            includedEdgeIndices.insert(idx)
        } else {
            // Cross-hierarchy edge: endpoints in different levels
            crossHierarchyEdges.append(edict)
            includedEdgeIndices.insert(idx)
        }
    }
    // Match TS ordering: root-level edges first, then cross-hierarchy
    let rootEdges = rootLevelEdges + crossHierarchyEdges

    func buildSubgraphNode(_ sub: original_src_types.MermaidSubgraph) -> [String: Any] {
        let directNodeIds = sub.nodeIds.filter { nodeId in
            !sub.children.contains { child in _subgraphContainsNode(child, nodeId: nodeId) }
        }
        var children: [[String: Any]] = []
        for nodeId in directNodeIds {
            guard let node = nodeById[nodeId] else { continue }
            let size = _nodeSize(node)
            children.append([
                "id": nodeId,
                "width": size.width,
                "height": size.height,
                "labels": [["text": node.label]],
                "luna.span": _nodeSpan(node, size: size, direction: graph.direction),
            ])
        }
        for child in sub.children { children.append(buildSubgraphNode(child)) }

        // Match TS subgraph options. Our Swift ELK port doesn't implement
        // option inheritance, so we explicitly set considerModelOrder
        // (elk.js inherits it from root via LayoutConfigurator).
        var opts: [String: String] = [
            "elk.algorithm": "layered",
            "elk.padding": "[top=44,left=16,bottom=16,right=16]",
            "elk.edgeRouting": "ORTHOGONAL",
            "elk.contentAlignment": "H_CENTER V_CENTER",
            "elk.spacing.edgeEdge": "12",
            "elk.layered.spacing.edgeEdgeBetweenLayers": "12",
            "elk.layered.spacing.edgeNodeBetweenLayers": "12",
            "elk.layered.nodePlacement.bk.fixedAlignment": "BALANCED",
            "elk.layered.spacing.nodeNodeBetweenLayers": "48",
            "elk.spacing.nodeNode": "28"
        ]
        // Only set direction on subgraph if it has an explicit override.
        // In INCLUDE_CHILDREN mode, direction inherits from root automatically.
        // Setting it explicitly can cause ELK to create different external port
        // dummy structures, leading to wider compound nodes.
        if let dir = sub.direction {
            opts["elk.direction"] = _mapDirection(dir)
        }

        let subLabel = sub.label
        let headerW = original_src_text_metrics.measureMultilineText(
            subLabel,
            fontSize: original_src_styles.FONT_SIZES.nodeLabel,
            fontWeight: original_src_styles.FONT_WEIGHTS.nodeLabel
        ).width
        var result: [String: Any] = [
            "id": sub.id,
            "layoutOptions": opts,
            "children": children,
            "labels": [["text": subLabel]],
            "luna.minWidth": headerW + 24,
        ]
        if let subEdges = edgesBySubgraph[sub.id], !subEdges.isEmpty {
            result["edges"] = subEdges
        }
        return result
    }

    var rootChildren: [[String: Any]] = []
    for entry in graph.nodesInOrder {
        if !allClaimedNodes.contains(entry.id) {
            let size = _nodeSize(entry.node)
            rootChildren.append([
                "id": entry.id,
                "width": size.width,
                "height": size.height,
                "labels": [["text": entry.node.label]],
                "luna.span": _nodeSpan(entry.node, size: size, direction: graph.direction),
            ])
        }
    }
    // In lanes mode the top-level groups go last-declared-first, the order the lane
    // engine reads them in as written order.
    let topSubs = lanes ? Array(graph.subgraphs.reversed()) : graph.subgraphs
    for sub in topSubs {
        var built = buildSubgraphNode(sub)
        if lanes { built["luna.lane"] = true }
        rootChildren.append(built)
    }
    if lanes {
        // Nodes outside every lane go into one unnamed default lane.
        var stray: [[String: Any]] = []
        for entry in graph.nodesInOrder {
            if !allClaimedNodes.contains(entry.id) {
                let size = _nodeSize(entry.node)
                stray.append([
                    "id": entry.id,
                    "width": size.width,
                    "height": size.height,
                    "labels": [["text": entry.node.label]],
                    "luna.span": _nodeSpan(entry.node, size: size, direction: graph.direction),
                ])
            }
        }
        if !stray.isEmpty {
            // Move the strays out of the root children into the default lane.
            rootChildren.removeAll { child in
                guard let id = child["id"] as? String else { return false }
                return stray.contains { ($0["id"] as? String) == id }
            }
            rootChildren.append([
                "id": "__luna_default_lane",
                "layoutOptions": ["elk.padding": "[top=44,left=16,bottom=16,right=16]"],
                "children": stray,
                "labels": [["text": ""]],
                "luna.lane": true,
            ])
        }
    }

    var rootDict: [String: Any] = [
        "id": "root",
        "layoutOptions": [
            "elk.algorithm": "layered",
            "elk.direction": _mapDirection(graph.direction),
            "elk.spacing.nodeNode": "28",
            "elk.spacing.edgeEdge": "12",
            "elk.layered.spacing.nodeNodeBetweenLayers": "48",
            "elk.layered.spacing.edgeEdgeBetweenLayers": "12",
            "elk.layered.spacing.edgeNodeBetweenLayers": "12",
            "elk.padding": "[top=40,left=40,bottom=40,right=40]",
            "elk.edgeRouting": "ORTHOGONAL",
            "elk.contentAlignment": "H_CENTER V_CENTER",
            "elk.layered.nodePlacement.bk.fixedAlignment": "BALANCED",
            "elk.layered.considerModelOrder.strategy": "NODES_AND_EDGES",
            "elk.layered.thoroughness": "3",
            "elk.layered.compaction.postCompaction.strategy": "LEFT_RIGHT_CONSTRAINT_LOCKING",
            "elk.layered.highDegreeNodes.treatment": "true",
            "elk.layered.highDegreeNodes.threshold": "8",
            "elk.layered.wrapping.strategy": "OFF",
            "elk.hierarchyHandling": "INCLUDE_CHILDREN"
        ],
        "children": rootChildren,
        "edges": rootEdges
    ]
    if lanes { rootDict["luna.lanes"] = true }
    return rootDict
}

private func _buildFlatElkGraph(_ graph: _ParsedGraph) -> _ElkNode {
    var children: [[String: Any]] = []
    for entry in graph.nodesInOrder {
        let size = _nodeSize(entry.node)
        children.append([
            "id": entry.id,
            "width": size.width,
            "height": size.height
        ])
    }
    var edges: [[String: Any]] = []
    for (idx, edge) in graph.edges.enumerated() {
        var out: [String: Any] = [
            "id": "e\(idx)",
            "sources": [edge.source],
            "targets": [edge.target]
        ]
        if let label = edge.label, !label.isEmpty {
            let m = original_src_text_metrics.measureMultilineText(
                label,
                fontSize: original_src_styles.FONT_SIZES.edgeLabel,
                fontWeight: original_src_styles.FONT_WEIGHTS.edgeLabel
            )
            out["labels"] = [[
                "text": label,
                "width": m.width + 8,
                "height": m.height + 6,
                "layoutOptions": [
                    "elk.edgeLabels.inline": "true",
                    "elk.edgeLabels.placement": "CENTER"
                ]
            ] as [String: Any]]
        }
        edges.append(out)
    }
    return [
        "id": "root",
        "layoutOptions": [
            "elk.algorithm": "layered",
            "elk.direction": _mapDirection(graph.direction),
            "elk.spacing.nodeNode": "28",
            "elk.spacing.edgeEdge": "12",
            "elk.layered.spacing.nodeNodeBetweenLayers": "48",
            "elk.layered.spacing.edgeEdgeBetweenLayers": "12",
            "elk.layered.spacing.edgeNodeBetweenLayers": "12",
            "elk.padding": "[top=40,left=40,bottom=40,right=40]",
            "elk.edgeRouting": "ORTHOGONAL",
            "elk.contentAlignment": "H_CENTER V_CENTER",
            "elk.layered.nodePlacement.bk.fixedAlignment": "BALANCED",
            "elk.layered.considerModelOrder.strategy": "NODES_AND_EDGES",
            "elk.layered.thoroughness": "3",
            "elk.layered.compaction.postCompaction.strategy": "LEFT_RIGHT_CONSTRAINT_LOCKING",
            "elk.layered.highDegreeNodes.treatment": "true",
            "elk.layered.highDegreeNodes.threshold": "8",
            "elk.randomSeed": "1"
        ],
        "children": children,
        "edges": edges
    ]
}

private func _layoutGraphSyncFromLayoutEngine(
    _ graph: MermaidGraph,
    _ options: RenderOptions
) throws -> PositionedGraph {
    _ = options
    guard let parsed = graph.payload as? _ParsedGraph else {
        return PositionedGraph(diagram: graph)
    }
    // One compound builder for every graph: nested subgraphs become nested compounds,
    // each laid out in its own direction, cross-border edges routed through ports.
    // Swimlanes run the lane engine over their top-level subgraphs.
    let elkGraph = _buildCompoundGraph(parsed, lanes: graph.type == .swimlane)
    do {
        let laidOut = try lunaLayoutSync(elkGraph)
        return _extractPositionedGraph(parsed, laidOut, diagramType: graph.type)
    } catch {
        // Fallback: fully flat layout
        let flatGraph = _buildFlatElkGraph(parsed)
        let laidOut = try lunaLayoutSync(flatGraph)
        return _extractPositionedGraph(parsed, laidOut, diagramType: graph.type)
    }
}

private func _layoutGraphWithDiagnosticsSyncFromLayoutEngine(
    _ graph: MermaidGraph,
    _ options: RenderOptions
) throws -> PositionedGraph {
    try _layoutGraphSyncFromLayoutEngine(graph, options)
}

private func _convertToElkFormat(
    _ graph: MermaidGraph,
    _ options: RenderOptions
) throws {
    _ = graph
    _ = options
    // Intentionally a no-op adapter until full layout-engine parity lands.
}

open class original_src_layout {
    public init() {}

    // Marker to keep transpiled outputs linked to elk-swift runtime.

    // Export inventory from TypeScript source:
    // - export { layoutGraphSync } from './layout-engine.ts'
    public static func layoutGraphSync(
        _ graph: MermaidGraph,
        _ options: RenderOptions = RenderOptions()
    ) throws -> PositionedGraph {
        try _layoutGraphSyncEntry(graph, options)
    }
}

// MARK: - Shape Clipping

/// Compute the midpoint along the edge's polyline path.
private func _edgePathMidpoint(_ points: [_PositionedPointPayload], direction: original_src_types.Direction = .TD) -> _PositionedPointPayload {
    guard points.count >= 2 else {
        return points.first ?? _PositionedPointPayload(x: 0, y: 0)
    }

    // For edges with bends, prefer the longest segment aligned with the flow direction.
    // In TD/BT graphs, labels go on vertical segments; in LR/RL, on horizontal segments.
    let isVerticalFlow = direction == .TD || direction == .TB || direction == .BT

    if points.count >= 3 {
        var bestIdx = -1
        var bestLen: Double = 0
        for i in 1..<points.count {
            let dx = points[i].x - points[i-1].x
            let dy = points[i].y - points[i-1].y
            let segLen = sqrt(dx * dx + dy * dy)
            let isFlowAligned = isVerticalFlow ? (abs(dy) > abs(dx)) : (abs(dx) > abs(dy))
            if isFlowAligned && segLen > bestLen {
                bestLen = segLen
                bestIdx = i
            }
        }
        if bestIdx > 0 {
            return _PositionedPointPayload(
                x: (points[bestIdx - 1].x + points[bestIdx].x) / 2,
                y: (points[bestIdx - 1].y + points[bestIdx].y) / 2
            )
        }
    }

    // Fallback: total path distance midpoint
    var totalLen: Double = 0
    for i in 1..<points.count {
        let dx = points[i].x - points[i-1].x
        let dy = points[i].y - points[i-1].y
        totalLen += sqrt(dx * dx + dy * dy)
    }
    let halfLen = totalLen / 2
    var accumulated: Double = 0
    for i in 1..<points.count {
        let dx = points[i].x - points[i-1].x
        let dy = points[i].y - points[i-1].y
        let segLen = sqrt(dx * dx + dy * dy)
        if accumulated + segLen >= halfLen {
            let remaining = halfLen - accumulated
            let t = segLen > 0 ? remaining / segLen : 0.5
            return _PositionedPointPayload(
                x: points[i-1].x + dx * t,
                y: points[i-1].y + dy * t
            )
        }
        accumulated += segLen
    }
    return _PositionedPointPayload(
        x: (points[0].x + points[points.count - 1].x) / 2,
        y: (points[0].y + points[points.count - 1].y) / 2
    )
}

/// Clip edge endpoints to actual shape boundaries instead of bounding boxes.
/// Handles diamond, circle, hexagon, stadium, rounded rect, etc.
private func _clipEdgeToShape(
    points: [_PositionedPointPayload],
    node: _PositionedNodePayload,
    isStart: Bool
) -> [_PositionedPointPayload] {
    guard points.count >= 2 else { return points }

    let shape = node.shape
    // Rectangular shapes: bounding box is already correct
    if shape == "rectangle" || shape == "rounded" || shape == "stadium" ||
       shape == "subroutine" || shape == "stateStart" || shape == "stateEnd" ||
       shape == "stateFork" {
        return points
    }

    var result = points
    let cx = node.x + node.width / 2
    let cy = node.y + node.height / 2
    let halfW = node.width / 2
    let halfH = node.height / 2

    if isStart {
        let endpoint = points[0]
        let adjacent = points[1]
        if let clipped = _clipPoint(endpoint: endpoint, adjacent: adjacent, shape: shape, cx: cx, cy: cy, halfW: halfW, halfH: halfH) {
            result[0] = clipped
        }
    } else {
        let lastIdx = points.count - 1
        let endpoint = points[lastIdx]
        let adjacent = points[lastIdx - 1]
        if let clipped = _clipPoint(endpoint: endpoint, adjacent: adjacent, shape: shape, cx: cx, cy: cy, halfW: halfW, halfH: halfH) {
            result[lastIdx] = clipped
        }
    }

    return result
}

private func _clipPoint(
    endpoint: _PositionedPointPayload,
    adjacent: _PositionedPointPayload,
    shape: String,
    cx: Double, cy: Double,
    halfW: Double, halfH: Double
) -> _PositionedPointPayload? {
    switch shape {
    case "diamond", "rhombus", "stateChoice":
        return _clipToDiamond(endpoint: endpoint, adjacent: adjacent, cx: cx, cy: cy, halfW: halfW, halfH: halfH)
    case "circle", "doublecircle":
        return _clipToCircle(endpoint: endpoint, adjacent: adjacent, cx: cx, cy: cy, halfW: halfW, halfH: halfH)
    case "hexagon":
        return _clipToHexagon(endpoint: endpoint, adjacent: adjacent, cx: cx, cy: cy, halfW: halfW, halfH: halfH)
    default:
        // For other non-rect shapes, use general center→external intersection
        return _clipToEllipseApprox(endpoint: endpoint, adjacent: adjacent, cx: cx, cy: cy, halfW: halfW, halfH: halfH)
    }
}

// MARK: - Diamond

private func _clipToDiamond(
    endpoint: _PositionedPointPayload,
    adjacent: _PositionedPointPayload,
    cx: Double, cy: Double,
    halfW: Double, halfH: Double
) -> _PositionedPointPayload? {
    // Diamond vertices
    let top    = (x: cx,        y: cy - halfH)
    let right  = (x: cx + halfW, y: cy)
    let bottom = (x: cx,        y: cy + halfH)
    let left   = (x: cx - halfW, y: cy)

    let dx = endpoint.x - adjacent.x
    let dy = endpoint.y - adjacent.y
    let isVertical = abs(dx) < abs(dy)

    if isVertical {
        let rayX = endpoint.x
        if dy > 0 {
            // Moving down → top half
            if rayX <= cx {
                return _intersectVerticalRay(rayX: rayX, p1x: left.x, p1y: left.y, p2x: top.x, p2y: top.y)
            } else {
                return _intersectVerticalRay(rayX: rayX, p1x: top.x, p1y: top.y, p2x: right.x, p2y: right.y)
            }
        } else {
            // Moving up → bottom half
            if rayX <= cx {
                return _intersectVerticalRay(rayX: rayX, p1x: bottom.x, p1y: bottom.y, p2x: left.x, p2y: left.y)
            } else {
                return _intersectVerticalRay(rayX: rayX, p1x: right.x, p1y: right.y, p2x: bottom.x, p2y: bottom.y)
            }
        }
    } else {
        let rayY = endpoint.y
        if dx > 0 {
            // Moving right → left half
            if rayY <= cy {
                return _intersectHorizontalRay(rayY: rayY, p1x: top.x, p1y: top.y, p2x: left.x, p2y: left.y)
            } else {
                return _intersectHorizontalRay(rayY: rayY, p1x: left.x, p1y: left.y, p2x: bottom.x, p2y: bottom.y)
            }
        } else {
            // Moving left → right half
            if rayY <= cy {
                return _intersectHorizontalRay(rayY: rayY, p1x: top.x, p1y: top.y, p2x: right.x, p2y: right.y)
            } else {
                return _intersectHorizontalRay(rayY: rayY, p1x: right.x, p1y: right.y, p2x: bottom.x, p2y: bottom.y)
            }
        }
    }
}

// MARK: - Circle

private func _clipToCircle(
    endpoint: _PositionedPointPayload,
    adjacent: _PositionedPointPayload,
    cx: Double, cy: Double,
    halfW: Double, halfH: Double
) -> _PositionedPointPayload? {
    let radius = min(halfW, halfH)
    let dx = endpoint.x - cx
    let dy = endpoint.y - cy
    let dist = sqrt(dx * dx + dy * dy)
    guard dist > 0.001 else { return nil }
    let scale = radius / dist
    return _PositionedPointPayload(x: cx + dx * scale, y: cy + dy * scale)
}

// MARK: - Hexagon

private func _clipToHexagon(
    endpoint: _PositionedPointPayload,
    adjacent: _PositionedPointPayload,
    cx: Double, cy: Double,
    halfW: Double, halfH: Double
) -> _PositionedPointPayload? {
    // Hexagon has 6 vertices: left/right points and 4 angled corners
    let inset = halfW * 0.25
    let vertices: [(x: Double, y: Double)] = [
        (cx - halfW, cy),                    // left point
        (cx - halfW + inset, cy - halfH),    // top-left
        (cx + halfW - inset, cy - halfH),    // top-right
        (cx + halfW, cy),                    // right point
        (cx + halfW - inset, cy + halfH),    // bottom-right
        (cx - halfW + inset, cy + halfH),    // bottom-left
    ]
    // Find intersection of ray from adjacent→endpoint with polygon edges
    return _clipToPolygon(endpoint: endpoint, adjacent: adjacent, vertices: vertices)
}

// MARK: - Ellipse approximation for other shapes

private func _clipToEllipseApprox(
    endpoint: _PositionedPointPayload,
    adjacent: _PositionedPointPayload,
    cx: Double, cy: Double,
    halfW: Double, halfH: Double
) -> _PositionedPointPayload? {
    let dx = endpoint.x - cx
    let dy = endpoint.y - cy
    guard abs(dx) > 0.001 || abs(dy) > 0.001 else { return nil }
    // Ellipse boundary: (dx/halfW)^2 + (dy/halfH)^2 = 1
    let normX = dx / halfW
    let normY = dy / halfH
    let dist = sqrt(normX * normX + normY * normY)
    guard dist > 0.001 else { return nil }
    let scale = 1.0 / dist
    return _PositionedPointPayload(x: cx + dx * scale, y: cy + dy * scale)
}

// MARK: - Polygon intersection

private func _clipToPolygon(
    endpoint: _PositionedPointPayload,
    adjacent: _PositionedPointPayload,
    vertices: [(x: Double, y: Double)]
) -> _PositionedPointPayload? {
    let n = vertices.count
    guard n >= 3 else { return nil }

    // Ray from adjacent to endpoint, find closest intersection with polygon edges
    let ox = adjacent.x, oy = adjacent.y
    let dx = endpoint.x - adjacent.x, dy = endpoint.y - adjacent.y

    var bestT = Double.infinity
    var bestPoint: _PositionedPointPayload?

    for i in 0..<n {
        let j = (i + 1) % n
        let ex = vertices[j].x - vertices[i].x
        let ey = vertices[j].y - vertices[i].y

        let denom = dx * ey - dy * ex
        guard abs(denom) > 0.0001 else { continue }

        let t = ((vertices[i].x - ox) * ey - (vertices[i].y - oy) * ex) / denom
        let u = ((vertices[i].x - ox) * dy - (vertices[i].y - oy) * dx) / denom

        if t > 0 && u >= 0 && u <= 1 && t < bestT {
            bestT = t
            bestPoint = _PositionedPointPayload(x: ox + dx * t, y: oy + dy * t)
        }
    }

    return bestPoint
}

// MARK: - Ray-edge intersection helpers

private func _intersectVerticalRay(
    rayX: Double, p1x: Double, p1y: Double, p2x: Double, p2y: Double
) -> _PositionedPointPayload? {
    let dx = p2x - p1x
    guard abs(dx) > 0.001 else { return nil }
    let t = (rayX - p1x) / dx
    guard t >= 0 && t <= 1 else { return nil }
    return _PositionedPointPayload(x: rayX, y: p1y + t * (p2y - p1y))
}

private func _intersectHorizontalRay(
    rayY: Double, p1x: Double, p1y: Double, p2x: Double, p2y: Double
) -> _PositionedPointPayload? {
    let dy = p2y - p1y
    guard abs(dy) > 0.001 else { return nil }
    let t = (rayY - p1y) / dy
    guard t >= 0 && t <= 1 else { return nil }
    return _PositionedPointPayload(x: p1x + t * (p2x - p1x), y: rayY)
}
