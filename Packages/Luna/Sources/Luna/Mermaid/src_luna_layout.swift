// Luna layout adapter: ELK-shaped dictionaries in, Pele port engine, ELK-shaped dictionaries out.
//
// Luna-owned adapter (Apache-2.0) over the ported engine in Sources/Luna/Layout/
// (Pele MIT; see Packages/Luna/NOTICE). It consumes and produces the same
// ELK-compatible dictionary interchange (`ElkNode`, `children` with x/y/width/height,
// `edges` with `sources`/`targets` and routed `sections`), so the graph builders and
// the positioned-graph extractors are unchanged.
//
// Every leaf and compound becomes a `CompoundNode`. Compounds take `dir` from
// `elk.direction` and their padding from `elk.padding` (padX = max(left, right)).
// `seq` is the child order. New optional keys: `luna.span` on nodes,
// `luna.minWidth` on groups, `luna.lanes` on the root. Edges from any level become
// one global edge list, ends resolved by id, labels from `labels[0]`. Spacing comes
// from `elk.spacing.nodeNode`, `elk.layered.spacing.nodeNodeBetweenLayers` and
// `elk.spacing.edgeEdge`. `portSep` is 20 and `headRoom` is the arrow size.
// Luna draws orthogonal polylines, so the engine always runs with `tracks: true`.
//
// This is the single choke point between Luna's graph builders and the layout engine.
import Foundation

/// ELK-compatible dictionary interchange: a graph/node/point dictionary.
/// (The name describes the interchange format, not the engine behind it.)
public typealias ElkNode = [String: Any]

private enum _LunaLayoutError: Error, LocalizedError {
    case invalidGraphShape

    var errorDescription: String? {
        switch self {
        case .invalidGraphShape:
            return "Layout graph must contain a string 'id' field."
        }
    }
}

private func _toDouble(_ value: Any?, default fallback: Double = 0) -> Double {
    if let d = value as? Double { return d }
    if let i = value as? Int { return Double(i) }
    if let f = value as? Float { return Double(f) }
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String, let d = Double(s) { return d }
    return fallback
}

private func _parseElkDirection(_ graph: ElkNode) -> CompoundDir {
    let raw = (graph["layoutOptions"] as? [String: Any])?["elk.direction"] as? String
    switch raw?.uppercased() {
    case "UP": return .bt
    case "RIGHT": return .lr
    case "LEFT": return .rl
    default: return .tb
    }
}

private func _parseElkPadding(_ graph: ElkNode, defaults: (top: Double, left: Double, bottom: Double, right: Double)) -> (top: Double, left: Double, bottom: Double, right: Double) {
    guard let paddingRaw = (graph["layoutOptions"] as? [String: Any])?["elk.padding"] as? String,
          let regex = try? NSRegularExpression(pattern: #"(top|left|bottom|right)\s*=\s*([-+]?[0-9]*\.?[0-9]+)"#)
    else {
        return defaults
    }
    var out = defaults
    let ns = paddingRaw as NSString
    for m in regex.matches(in: paddingRaw, range: NSRange(location: 0, length: ns.length)) {
        if m.numberOfRanges < 3 { continue }
        let key = ns.substring(with: m.range(at: 1)).lowercased()
        let value = Double(ns.substring(with: m.range(at: 2))) ?? defaults.top
        switch key {
        case "top": out.top = value
        case "left": out.left = value
        case "bottom": out.bottom = value
        case "right": out.right = value
        default: break
        }
    }
    return out
}

private struct _FlatEdge {
    /// Path of compound ids from the root to the dict holding this edge dict; [] is the root.
    var holderPath: [String]
    var indexInHolder: Int
    var srcId: String
    var dstId: String
    var labelW: Double
    var labelH: Double
}

private func _asDictArray(_ value: Any?) -> [[String: Any]] {
    if let direct = value as? [[String: Any]] { return direct }
    if let anyArray = value as? [Any] { return anyArray.compactMap { $0 as? [String: Any] } }
    return []
}

/// Reads the dictionary into flat compound nodes plus one global edge list.
private func _readCompoundGraph(_ dict: ElkNode, parent: Int, seqBase: Int,
                                nodes: inout [CompoundNode], idToIndex: inout [String: Int],
                                flatEdges: inout [_FlatEdge], path: [String]) {
    let children = _asDictArray(dict["children"])
    for (order, child) in children.enumerated() {
        guard let id = child["id"] as? String, !id.isEmpty else { continue }
        let isGroup = !(_asDictArray(child["children"]).isEmpty)
        let index = nodes.count
        idToIndex[id] = index
        var node = CompoundNode(w: max(1, _toDouble(child["width"], default: 60)),
                                h: max(1, _toDouble(child["height"], default: 36)),
                                parent: parent)
        if isGroup {
            node.isGroup = true
            if ((child["layoutOptions"] as? [String: Any])?["elk.direction"] as? String) != nil {
                node.dir = _parseElkDirection(child)
            }
            let pad = _parseElkPadding(child, defaults: (top: 44, left: 16, bottom: 16, right: 16))
            node.padX = max(pad.left, pad.right)
            node.padTop = pad.top
            node.padBottom = pad.bottom
            node.minW = _toDouble(child["luna.minWidth"], default: 0)
            // Groups spread their edges along the whole side unless told otherwise.
            node.span = child["luna.span"] == nil ? Double.infinity : _toDouble(child["luna.span"], default: 0)
            node.w = 0
            node.h = 0
        } else {
            node.span = _toDouble(child["luna.span"], default: 0)
        }
        node.seq = seqBase + order
        nodes.append(node)
        if isGroup {
            _readCompoundGraph(child, parent: index, seqBase: 0,
                               nodes: &nodes, idToIndex: &idToIndex,
                               flatEdges: &flatEdges, path: path + [id])
        }
    }
    let edges = _asDictArray(dict["edges"])
    for (i, edge) in edges.enumerated() {
        guard let sources = edge["sources"] as? [String], let src = sources.first,
              let targets = edge["targets"] as? [String], let dst = targets.first
        else { continue }
        var labelW = 0.0
        var labelH = 0.0
        if let first = _asDictArray(edge["labels"]).first {
            labelW = _toDouble(first["width"], default: 0)
            labelH = _toDouble(first["height"], default: 0)
        }
        flatEdges.append(_FlatEdge(holderPath: path, indexInHolder: i,
                                   srcId: src, dstId: dst, labelW: labelW, labelH: labelH))
    }
}

private func _pointDict(_ x: Double, _ y: Double) -> ElkNode {
    ["x": x, "y": y]
}

/// Luna layered layout over an ELK-compatible dictionary graph.
///
/// Validates the graph, lays out nested compounds (each in its own direction, cross-border
/// edges routed through ports), and returns the same graph with `x`/`y` filled on children,
/// routed `sections` on edges, first labels, and `width`/`height` on every compound.
/// This is the single choke point between Luna's graph builders and the layout engine.
public func lunaLayoutSync(_ graph: ElkNode) throws -> ElkNode {
    guard let id = graph["id"] as? String, !id.isEmpty else {
        throw _LunaLayoutError.invalidGraphShape
    }
    _ = id
    var out = graph

    var nodes: [CompoundNode] = []
    var idToIndex: [String: Int] = [:]
    var flatEdges: [_FlatEdge] = []
    _readCompoundGraph(out, parent: -1, seqBase: 0,
                       nodes: &nodes, idToIndex: &idToIndex,
                       flatEdges: &flatEdges, path: [])

    let layoutOptions = out["layoutOptions"] as? [String: Any]
    let nodeSep = _toDouble(layoutOptions?["elk.spacing.nodeNode"], default: 28)
    let rankSep = _toDouble(layoutOptions?["elk.layered.spacing.nodeNodeBetweenLayers"], default: 48)
    let edgeSep = _toDouble(layoutOptions?["elk.spacing.edgeEdge"], default: 12)
    let opt = LayeredOptions(nodeSep: nodeSep, edgeSep: edgeSep, rankSep: rankSep,
                             portSep: 20, tracks: true, headRoom: 8)

    var compoundEdges: [CompoundEdge] = []
    // flatIdx -> compound edge index (-1 when an end is unknown and the edge is skipped).
    var flatToCompound = [Int](repeating: -1, count: flatEdges.count)
    for (fi, fe) in flatEdges.enumerated() {
        guard let s = idToIndex[fe.srcId], let d = idToIndex[fe.dstId] else { continue }
        flatToCompound[fi] = compoundEdges.count
        compoundEdges.append(CompoundEdge(src: s, dst: d, minlen: 1,
                                          labelW: fe.labelW, labelH: fe.labelH))
    }

    let rootDir = _parseElkDirection(out)
    let rootPad = _parseElkPadding(out, defaults: (top: 40, left: 40, bottom: 40, right: 40))
    let total: CompoundResult
    if (out["luna.lanes"] as? Bool) == true {
        total = laneLayout(nodes: &nodes, edges: &compoundEdges, dir: rootDir, opt: opt)
    } else {
        total = compoundLayout(nodes: &nodes, edges: &compoundEdges, rootDir: rootDir, opt: opt)
    }
    // Root padding becomes an offset.
    if rootPad.left != 0 || rootPad.top != 0 {
        shiftLayout(nodes: &nodes, edges: &compoundEdges, ox: rootPad.left, oy: rootPad.top)
    }

    // Copy routes back against the flat edge list.
    var routes = [CompoundEdge](repeating: CompoundEdge(src: 0, dst: 0), count: flatEdges.count)
    var srcIds = [String?](repeating: nil, count: flatEdges.count)
    for (fi, ci) in flatToCompound.enumerated() {
        srcIds[fi] = flatEdges[fi].srcId
        if ci >= 0 {
            routes[fi].route = compoundEdges[ci].route
            routes[fi].labelX = compoundEdges[ci].labelX
            routes[fi].labelY = compoundEdges[ci].labelY
        }
    }

    // Holder path key -> (index in holder -> flat edge index).
    var flatIndexByHolder: [String: [Int: Int]] = [:]
    for (fi, fe) in flatEdges.enumerated() {
        let key = fe.holderPath.joined(separator: "\u{1F}")
        flatIndexByHolder[key, default: [:]][fe.indexInHolder] = fi
    }

    _writeCompoundGraphFull(&out, nodes: nodes, idToIndex: idToIndex,
                            routes: routes, srcIds: srcIds,
                            flatIndexByHolder: flatIndexByHolder,
                            path: [], parentTopLeft: (0, 0))
    out["width"] = total.width + rootPad.left + rootPad.right
    out["height"] = total.height + rootPad.top + rootPad.bottom
    return out
}

private func _writeCompoundGraphFull(_ dict: inout ElkNode,
                                      nodes: [CompoundNode], idToIndex: [String: Int],
                                      routes: [CompoundEdge], srcIds: [String?],
                                      flatIndexByHolder: [String: [Int: Int]],
                                      path: [String], parentTopLeft: (x: Double, y: Double)) {
    let key = path.joined(separator: "\u{1F}")
    if let rawChildren = dict["children"] as? [Any] {
        var rewritten: [[String: Any]] = []
        for rawChild in rawChildren {
            guard var child = rawChild as? [String: Any],
                  let id = child["id"] as? String,
                  let index = idToIndex[id]
            else {
                if let c = rawChild as? [String: Any] { rewritten.append(c) }
                continue
            }
            let node = nodes[index]
            child["x"] = node.x - node.w / 2 - parentTopLeft.x
            child["y"] = node.y - node.h / 2 - parentTopLeft.y
            if node.isGroup {
                child["width"] = node.w
                child["height"] = node.h
                _writeCompoundGraphFull(&child, nodes: nodes, idToIndex: idToIndex,
                                        routes: routes, srcIds: srcIds,
                                        flatIndexByHolder: flatIndexByHolder,
                                        path: path + [id],
                                        parentTopLeft: (node.x - node.w / 2, node.y - node.h / 2))
            }
            rewritten.append(child)
        }
        dict["children"] = rewritten
    }
    if let rawEdges = dict["edges"] as? [Any] {
        var edgeDicts: [[String: Any]] = []
        for (i, rawEdge) in rawEdges.enumerated() {
            guard var edgeDict = rawEdge as? [String: Any] else { continue }
            if let flatIdx = flatIndexByHolder[key]?[i] {
                let e = routes[flatIdx]
                let holder = parentTopLeft
                if e.route.isEmpty {
                    // Self-loop the engine leaves unrouted: draw a loop out of the right side.
                    if let srcId = srcIds[flatIdx], let srcIdx = idToIndex[srcId] {
                        let n = nodes[srcIdx]
                        let nx = n.x - n.w / 2 - holder.x
                        let ny = n.y - n.h / 2 - holder.y
                        let pts = [_pointDict(nx + n.w, ny + n.h / 2),
                                   _pointDict(nx + n.w + 20, ny + n.h / 2),
                                   _pointDict(nx + n.w + 20, ny - 14),
                                   _pointDict(nx + n.w / 2, ny - 14),
                                   _pointDict(nx + n.w / 2, ny)]
                        edgeDict["sections"] = [[
                            "id": "s\(flatIdx)",
                            "startPoint": pts[0],
                            "bendPoints": Array(pts[1..<(pts.count - 1)]),
                            "endPoint": pts[pts.count - 1],
                        ]]
                    }
                } else {
                    var pts: [ElkNode] = []
                    var k = 0
                    while k + 1 < e.route.count {
                        pts.append(_pointDict(e.route[k] - holder.x, e.route[k + 1] - holder.y))
                        k += 3
                    }
                    if pts.count >= 2 {
                        edgeDict["sections"] = [[
                            "id": "s\(flatIdx)",
                            "startPoint": pts[0],
                            "bendPoints": Array(pts[1..<(pts.count - 1)]),
                            "endPoint": pts[pts.count - 1],
                        ]]
                    }
                    if var labels = edgeDict["labels"] as? [Any], !labels.isEmpty,
                       var first = labels[0] as? [String: Any] {
                        let lw = _toDouble(first["width"], default: 0)
                        let lh = _toDouble(first["height"], default: 0)
                        first["x"] = e.labelX - lw / 2 - holder.x
                        first["y"] = e.labelY - lh / 2 - holder.y
                        labels[0] = first
                        edgeDict["labels"] = labels
                    }
                }
            }
            edgeDicts.append(edgeDict)
        }
        dict["edges"] = edgeDicts
    }
}
