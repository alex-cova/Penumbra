// Ported from Pele src/layout/compound.ts @ 8603bf3 (MIT, Copyright (c) 2026 kepano). See Packages/Luna/NOTICE.
import Foundation

/// A compound-layout direction.
public enum CompoundDir: Sendable {
    case tb, bt, lr, rl
}

/// The direction a diagram names, or top to bottom for anything else.
public func compoundDirection(_ dir: String?) -> CompoundDir {
    switch dir {
    case "BT": return .bt
    case "LR": return .lr
    case "RL": return .rl
    default: return .tb
    }
}

/// A node of the compound graph: a leaf or a group.
public struct CompoundNode: Sendable {
    public var w: Double
    public var h: Double
    public var parent: Int
    public var isGroup: Bool
    public var dir: CompoundDir?
    public var padX: Double
    public var padTop: Double
    public var padBottom: Double
    public var minW: Double
    /// Declaration order; a group takes the smallest value among its members.
    public var seq: Int
    /// How much of a side its edges may spread along, measured across the flow; 0 keeps them at its middle.
    public var span: Double
    public var x: Double
    public var y: Double

    public init(w: Double, h: Double, parent: Int = -1) {
        self.w = w; self.h = h; self.parent = parent
        self.isGroup = false; self.dir = nil
        self.padX = 0; self.padTop = 0; self.padBottom = 0; self.minW = 0
        self.seq = 0; self.span = 0; self.x = 0; self.y = 0
    }
}

/// An edge of the compound graph.
public struct CompoundEdge: Sendable {
    public var src: Int
    public var dst: Int
    public var minlen: Int32
    public var labelW: Double
    public var labelH: Double
    /// x, y, axis triples; axis is 0 where the edge runs vertically into the point, 1 horizontally.
    public var route: [Double]
    public var labelX: Double
    public var labelY: Double

    public init(src: Int, dst: Int, minlen: Int32 = 1, labelW: Double = 0, labelH: Double = 0) {
        self.src = src; self.dst = dst; self.minlen = minlen
        self.labelW = labelW; self.labelH = labelH
        self.route = []; self.labelX = 0; self.labelY = 0
    }
}

/// The size of a compound result. Node positions land on the nodes, routes on the edges.
public struct CompoundResult: Sendable {
    public var width: Double
    public var height: Double
}

private enum CompoundSide: Int {
    case top = 0, right = 1, bottom = 2, left = 3
}

private struct PortEdge {
    var e: Int
    var inner: Int
    var out: Bool
    var side: CompoundSide
    var px: Double
    var py: Double
    var route: [Double]
}

private struct LevelEdge {
    var e: Int
    var a: Int
    var b: Int
}

private struct Level {
    var id: Int
    var dir: CompoundDir
    var items: [Int]
    var edges: [LevelEdge]
    var ports: [PortEdge]
    var portOf: [Int: Int]
    var routes: [Int: [Double]]
    var x: Double
    var y: Double
}

private let maxPorts = 40000

public func shiftLayout(nodes: inout [CompoundNode], edges: inout [CompoundEdge], ox: Double, oy: Double) {
    for i in 0..<nodes.count {
        nodes[i].x += ox
        nodes[i].y += oy
    }
    for i in 0..<edges.count {
        var k = 0
        while k < edges[i].route.count {
            edges[i].route[k] += ox
            edges[i].route[k + 1] += oy
            k += 3
        }
        edges[i].labelX += ox
        edges[i].labelY += oy
    }
}

public func makeCompoundNode(w: Double, h: Double, parent: Int = -1) -> CompoundNode {
    CompoundNode(w: w, h: h, parent: parent)
}

private func startSide(_ dir: CompoundDir) -> CompoundSide {
    switch dir {
    case .tb: return .top
    case .bt: return .bottom
    case .lr: return .left
    case .rl: return .right
    }
}

private func opposite(_ side: CompoundSide) -> CompoundSide {
    CompoundSide(rawValue: (side.rawValue + 2) & 3)!
}

// Lays out a graph whose nodes may be nested in groups. Each group is laid out on its own,
// in its own direction, and then placed in its parent as a single box. An edge that crosses
// a group's border passes through a port on the side facing its other end.
public func compoundLayout(nodes: inout [CompoundNode], edges: inout [CompoundEdge],
                           rootDir: CompoundDir, opt: LayeredOptions) -> CompoundResult {
    let n = nodes.count
    var levelOf: [Int: Int] = [:]
    var order: [Level] = []
    func makeLevel(id: Int, dir: CompoundDir) -> Int {
        let idx = order.count
        order.append(Level(id: id, dir: dir, items: [], edges: [], ports: [],
                           portOf: [:], routes: [:], x: 0, y: 0))
        levelOf[id] = idx
        return idx
    }
    _ = makeLevel(id: -1, dir: rootDir)

    var children = [[Int]](repeating: [], count: n)
    var rootItems: [Int] = []
    for i in 0..<n {
        let p = nodes[i].parent
        if p >= 0 && p < n && p != i && nodes[p].isGroup {
            children[p].append(i)
        } else {
            nodes[i].parent = -1
            rootItems.append(i)
        }
    }
    order[0].items = rootItems
    var depth = [Int](repeating: 0, count: n)
    var placed = [Bool](repeating: false, count: n)
    func descend(from: Int) {
        var q = from
        while q < order.count {
            for item in order[q].items {
                placed[item] = true
                depth[item] = order[q].id < 0 ? 0 : depth[order[q].id] + 1
                if nodes[item].isGroup {
                    let idx = makeLevel(id: item, dir: nodes[item].dir ?? order[q].dir)
                    order[idx].items = children[item]
                }
            }
            q += 1
        }
    }
    descend(from: 0)
    // Groups that contain each other are unreachable from the root; lift them out.
    for i in 0..<n {
        if placed[i] { continue }
        let former = nodes[i].parent
        if former >= 0 && former < n {
            children[former].removeAll { $0 == i }
        }
        nodes[i].parent = -1
        order[0].items.append(i)
        placed[i] = true
        depth[i] = 0
        if nodes[i].isGroup {
            let from = order.count
            let idx = makeLevel(id: i, dir: nodes[i].dir ?? rootDir)
            order[idx].items = children[i]
            descend(from: from)
        }
    }

    for q in 1..<order.count {
        var seq = Int.max
        for item in order[q].items {
            if nodes[item].seq < seq { seq = nodes[item].seq }
        }
        if seq != Int.max { nodes[order[q].id].seq = seq }
    }
    for q in 0..<order.count {
        order[q].items.sort { nodes[$0].seq != nodes[$1].seq ? nodes[$0].seq < nodes[$1].seq : $0 < $1 }
    }

    // Every group border an edge crosses costs a port. Past the budget, an edge is drawn between
    // the groups that hold its ends, at the level they share.
    var ports = 0
    for i in 0..<edges.count {
        var a = edges[i].src
        var b = edges[i].dst
        var crossed = 0
        while depth[a] > depth[b] { a = nodes[a].parent; crossed += 1 }
        while depth[b] > depth[a] { b = nodes[b].parent; crossed += 1 }
        while a != b && nodes[a].parent != nodes[b].parent {
            a = nodes[a].parent
            b = nodes[b].parent
            crossed += 2
        }
        if a == b { continue }
        if ports + crossed > maxPorts {
            edges[i].src = a
            edges[i].dst = b
        } else {
            ports += crossed
        }
    }

    var loops: [Int] = []
    var stray: [Int] = []
    for ei in 0..<edges.count {
        edges[ei].route = []
        if edges[ei].src == edges[ei].dst {
            loops.append(ei)
            continue
        }
        var a = edges[ei].src
        var b = edges[ei].dst
        var aPath: [Int] = []
        var bPath: [Int] = []
        while depth[a] > depth[b] {
            aPath.append(a)
            a = nodes[a].parent
        }
        while depth[b] > depth[a] {
            bPath.append(b)
            b = nodes[b].parent
        }
        if a == b {
            stray.append(ei)
            continue
        }
        while nodes[a].parent != nodes[b].parent {
            aPath.append(a)
            bPath.append(b)
            a = nodes[a].parent
            b = nodes[b].parent
        }
        let lvl = levelOf[nodes[a].parent]!
        order[lvl].edges.append(LevelEdge(e: ei, a: a, b: b))
        for (path, out) in [(aPath, true), (bPath, false)] {
            for inner in path {
                let li = levelOf[nodes[inner].parent]!
                let port = PortEdge(e: ei, inner: inner, out: out, side: .top, px: 0, py: 0, route: [])
                order[li].ports.append(port)
                order[li].portOf[ei * 2 + (out ? 0 : 1)] = order[li].ports.count - 1
            }
        }
    }
    return compoundLayoutLevels(nodes: &nodes, edges: &edges, order: &order, levelOf: levelOf,
                                children: children, depth: depth, loops: loops, stray: stray,
                                rootDir: rootDir, opt: opt)
}

private func compoundLayoutLevels(nodes: inout [CompoundNode], edges: inout [CompoundEdge],
                                  order: inout [Level], levelOf: [Int: Int],
                                  children: [[Int]], depth: [Int],
                                  loops: [Int], stray: [Int],
                                  rootDir: CompoundDir, opt: LayeredOptions) -> CompoundResult {
    var local = [Int](repeating: 0, count: nodes.count)
    let endpointBelow: (Int, CompoundEdge, Bool) -> Bool = { item, e, out in
        (out ? e.src : e.dst) != item
    }

    struct Built {
        var lnodes: [LayeredNode]
        var ledges: [LayeredEdge]
        var dummies: [Int32]
    }
    func build(level: Level, sized: Bool) -> Built {
        let vertical = level.dir == .tb || level.dir == .bt
        let start = startSide(level.dir)
        var lnodes: [LayeredNode] = []
        var ledges: [LayeredEdge] = []
        for (i, item) in level.items.enumerated() {
            local[item] = i
            let node = nodes[item]
            var ln = sized
                ? LayeredNode(w: vertical ? node.w : node.h, h: vertical ? node.h : node.w)
                : LayeredNode(w: 0, h: 0)
            ln.span = node.isGroup ? min(node.span, ln.w - 2 * node.padX) : node.span
            lnodes.append(ln)
        }
        func held(_ item: Int, _ ei: Int, _ out: Bool) -> Bool {
            nodes[item].isGroup && endpointBelow(item, edges[ei], out)
        }
        func offset(_ item: Int, _ ei: Int, _ out: Bool) -> Double {
            if !sized || !nodes[item].isGroup || !endpointBelow(item, edges[ei], out) { return 0 }
            let port = order[levelOf[item]!].ports[order[levelOf[item]!].portOf[ei * 2 + (out ? 0 : 1)]!]
            return vertical ? port.px - nodes[item].w / 2 : port.py - nodes[item].h / 2
        }
        for le in level.edges {
            let e = edges[le.e]
            var edge = LayeredEdge(tail: Int32(local[le.a]), head: Int32(local[le.b]), minlen: e.minlen)
            if sized {
                edge.labelW = vertical ? e.labelW : e.labelH
                edge.labelH = vertical ? e.labelH : e.labelW
                edge.tailDx = offset(le.a, le.e, true)
                edge.headDx = offset(le.b, le.e, false)
                edge.tailFixed = held(le.a, le.e, true)
                edge.headFixed = held(le.b, le.e, false)
            }
            ledges.append(edge)
        }
        var dummies = [Int32](repeating: -1, count: level.ports.count)
        for (i, port) in level.ports.enumerated() {
            if port.side == start || port.side == opposite(start) {
                let d = lnodes.count
                lnodes.append(LayeredNode(w: 0, h: 0,
                                          kind: port.side == start ? .startPort : .endPort))
                dummies[i] = Int32(d)
                var edge = port.out
                    ? LayeredEdge(tail: Int32(local[port.inner]), head: Int32(d))
                    : LayeredEdge(tail: Int32(d), head: Int32(local[port.inner]))
                if port.out {
                    edge.tailDx = offset(port.inner, port.e, true)
                    edge.tailFixed = held(port.inner, port.e, true)
                } else {
                    edge.headDx = offset(port.inner, port.e, false)
                    edge.headFixed = held(port.inner, port.e, false)
                }
                ledges.append(edge)
            } else {
                lnodes[local[port.inner]].pin = (port.side == .top || port.side == .left) ? -1 : 1
            }
        }
        return Built(lnodes: lnodes, ledges: ledges, dummies: dummies)
    }

    // Top-down: rank each level to learn which side of a group every crossing edge leaves from.
    for li in 0..<order.count {
        for port in order[li].ports {
            if nodes[port.inner].isGroup && endpointBelow(port.inner, edges[port.e], port.out) {
                let inner = levelOf[port.inner]!
                let key = port.e * 2 + (port.out ? 0 : 1)
                if let pi = order[inner].portOf[key] {
                    order[inner].ports[pi].side = port.side
                }
            }
        }
        if order[li].edges.isEmpty { continue }
        var needed = false
        for le in order[li].edges {
            let e = edges[le.e]
            if (nodes[le.a].isGroup && e.src != le.a) || (nodes[le.b].isGroup && e.dst != le.b) {
                needed = true
            }
        }
        if !needed { continue }
        var built = build(level: order[li], sized: false)
        layeredOrient(nodes: &built.lnodes, edges: &built.ledges)
        layeredRank(nodes: &built.lnodes, edges: &built.ledges, step: 1)
        let start = startSide(order[li].dir)
        for (i, le) in order[li].edges.enumerated() {
            let e = edges[le.e]
            let aAbove = !built.ledges[i].reversed
            if nodes[le.a].isGroup && e.src != le.a {
                let inner = levelOf[le.a]!
                if let pi = order[inner].portOf[le.e * 2] {
                    order[inner].ports[pi].side = aAbove ? opposite(start) : start
                }
            }
            if nodes[le.b].isGroup && e.dst != le.b {
                let inner = levelOf[le.b]!
                if let pi = order[inner].portOf[le.e * 2 + 1] {
                    order[inner].ports[pi].side = aAbove ? start : opposite(start)
                }
            }
        }
    }

    // Bottom-up: lay out each level now that the sizes of its groups are known.
    var total = CompoundResult(width: 0, height: 0)
    for qi in stride(from: order.count - 1, through: 0, by: -1) {
        let level = order[qi]
        let groupId = level.id >= 0 ? level.id : nil
        let vertical = level.dir == .tb || level.dir == .bt
        let flip = level.dir == .bt || level.dir == .rl
        var built = build(level: level, sized: true)
        let size = layered(nodes: &built.lnodes, edges: &built.ledges, opt: opt)
        let contentW = vertical ? size.width : size.height
        let contentH = vertical ? size.height : size.width
        let padX = groupId.map { nodes[$0].padX } ?? 0
        let padTop = groupId.map { nodes[$0].padTop } ?? 0
        let boxW = max(contentW + 2 * padX, groupId.map { nodes[$0].minW } ?? 0)
        let boxH = contentH + padTop + (groupId.map { nodes[$0].padBottom } ?? 0)
        let offX = (boxW - contentW) / 2
        let offY = padTop
        let tx: (Double, Double) -> Double = { lx, ly in
            offX + (vertical ? lx : flip ? size.height - ly : ly)
        }
        let ty: (Double, Double) -> Double = { lx, ly in
            offY + (vertical ? (flip ? size.height - ly : ly) : lx)
        }
        let axis: Double = vertical ? 0 : 1
        func convert(_ points: [Double]) -> [Double] {
            var out: [Double] = []
            var i = 0
            while i < points.count {
                out.append(tx(points[i], points[i + 1]))
                out.append(ty(points[i], points[i + 1]))
                out.append(axis)
                i += 2
            }
            return out
        }

        for (i, item) in level.items.enumerated() {
            nodes[item].x = tx(built.lnodes[i].x, built.lnodes[i].y)
            nodes[item].y = ty(built.lnodes[i].x, built.lnodes[i].y)
        }
        for (i, le) in level.edges.enumerated() {
            let edge = built.ledges[i]
            order[qi].routes[le.e] = convert(edge.points)
            if edges[le.e].labelW > 0 {
                edges[le.e].labelX = tx(edge.labelX, edge.labelY)
                edges[le.e].labelY = ty(edge.labelX, edge.labelY)
            }
        }
        var k = level.edges.count
        for (i, port) in level.ports.enumerated() {
            let item = nodes[port.inner]
            if built.dummies[i] >= 0 {
                var route = convert(built.ledges[k].points)
                k += 1
                let at = port.out ? route.count - 3 : 0
                var bx = route[at]
                var by = route[at + 1]
                if port.side == .top { by = 0 }
                else if port.side == .bottom { by = boxH }
                else if port.side == .left { bx = 0 }
                else { bx = boxW }
                if port.out { route.append(contentsOf: [bx, by, axis]) }
                else { route.insert(contentsOf: [bx, by, axis], at: 0) }
                order[qi].ports[i].px = bx
                order[qi].ports[i].py = by
                order[qi].ports[i].route = route
                continue
            }
            var ix = item.x
            var iy = item.y
            if item.isGroup && endpointBelow(port.inner, edges[port.e], port.out) {
                let inner = levelOf[port.inner]!
                let key = port.e * 2 + (port.out ? 0 : 1)
                let innerPort = order[inner].ports[order[inner].portOf[key]!]
                ix += innerPort.px - item.w / 2
                iy += innerPort.py - item.h / 2
            } else if port.side == .top { iy -= item.h / 2 }
            else if port.side == .bottom { iy += item.h / 2 }
            else if port.side == .left { ix -= item.w / 2 }
            else { ix += item.w / 2 }
            var bx = ix
            var by = iy
            if port.side == .top { by = 0 }
            else if port.side == .bottom { by = boxH }
            else if port.side == .left { bx = 0 }
            else { bx = boxW }
            let a: Double = (port.side == .top || port.side == .bottom) ? 0 : 1
            order[qi].ports[i].px = bx
            order[qi].ports[i].py = by
            order[qi].ports[i].route = port.out ? [ix, iy, a, bx, by, a] : [bx, by, a, ix, iy, a]
        }

        if let gid = groupId {
            nodes[gid].w = boxW
            nodes[gid].h = boxH
        } else {
            total = CompoundResult(width: boxW, height: boxH)
        }
    }

    // Top-down again: turn positions inside each box into diagram coordinates.
    for li in 0..<order.count {
        let ox = order[li].x
        let oy = order[li].y
        for item in order[li].items {
            nodes[item].x += ox
            nodes[item].y += oy
            if nodes[item].isGroup {
                let child = levelOf[item]!
                order[child].x = nodes[item].x - nodes[item].w / 2
                order[child].y = nodes[item].y - nodes[item].h / 2
            }
        }
    }

    func appendRoute(_ route: inout [Double], part: [Double], ox: Double, oy: Double) {
        var i = 0
        while i < part.count {
            let x = part[i] + ox
            let y = part[i + 1] + oy
            let len = route.count
            if !(len >= 3 && abs(route[len - 3] - x) < 0.01 && abs(route[len - 2] - y) < 0.01) {
                route.append(x); route.append(y); route.append(part[i + 2])
            }
            i += 3
        }
    }

    for li in 0..<order.count {
        for le in order[li].edges {
            var route: [Double] = []
            var outward: [Int] = []
            var item = edges[le.e].src
            while nodes[item].parent != order[li].id {
                outward.append(levelOf[nodes[item].parent]!)
                item = nodes[item].parent
            }
            for lv in outward {
                let key = le.e * 2
                appendRoute(&route, part: order[lv].ports[order[lv].portOf[key]!].route,
                            ox: order[lv].x, oy: order[lv].y)
            }
            appendRoute(&route, part: order[li].routes[le.e]!, ox: order[li].x, oy: order[li].y)
            var inward: [Int] = []
            item = edges[le.e].dst
            while nodes[item].parent != order[li].id {
                inward.append(levelOf[nodes[item].parent]!)
                item = nodes[item].parent
            }
            for lv in inward.reversed() {
                let key = le.e * 2 + 1
                appendRoute(&route, part: order[lv].ports[order[lv].portOf[key]!].route,
                            ox: order[lv].x, oy: order[lv].y)
            }
            edges[le.e].route = route
            if edges[le.e].labelW > 0 {
                edges[le.e].labelX += order[li].x
                edges[le.e].labelY += order[li].y
            }
        }
    }

    for ei in stray {
        let a = nodes[edges[ei].src]
        let b = nodes[edges[ei].dst]
        edges[ei].route = [a.x, a.y, 0, b.x, b.y, 0]
        edges[ei].labelX = (a.x + b.x) / 2
        edges[ei].labelY = (a.y + b.y) / 2
    }
    for ei in loops {
        let node = nodes[edges[ei].src]
        edges[ei].labelX = node.x + node.w / 2 + 28 + edges[ei].labelW / 2
        edges[ei].labelY = node.y
    }

    return total
}
