// Ported from Pele src/layout/lanes.ts @ 8603bf3 (MIT, Copyright (c) 2026 kepano). See Packages/Luna/NOTICE.
import Foundation

// Layout for swimlanes. Every top-level group is a lane: a band that runs the length of the
// diagram along the flow. Ranks are shared by all lanes, so a step sits level with the steps
// that happen at the same time in other lanes, and each node stays inside its own lane.

private let laneHead = 34.0
private let lanePadDefault = 24.0
private let laneSweeps = 8
private let laneMaxDummies = 20000
private let laneMaxHops = 10000
private let routeBudget = 2000000
// Parallel lines closer than this are drawn as one.
private let laneNear = 4.0
private let laneRounds = 3
private let laneRelay = 8
private let laneTurn = 20.0
// The room a lane keeps beside a handoff along its margin, and how much of it is between the
// handoff and the lane's items.
private let laneMargin = 20.0
private let laneLeg = 14.0
private let laneClose = 3.0

public func laneLayout(nodes: inout [CompoundNode], edges: inout [CompoundEdge],
                       dir: CompoundDir, opt: LayeredOptions,
                       lanePad: Double = 24) -> CompoundResult {
    let n = nodes.count
    if n == 0 { return CompoundResult(width: 0, height: 0) }
    let sideways = dir == .lr || dir == .rl
    let flipped = dir == .bt || dir == .rl

    // Lanes in the order they were written. The graph lists groups last-declared first.
    var lanes: [Int] = []
    for i in stride(from: n - 1, through: 0, by: -1) {
        if nodes[i].parent < 0 && nodes[i].isGroup { lanes.append(i) }
    }
    let laneCount = max(1, lanes.count)
    var laneSlot = [Int](repeating: -1, count: n)
    for (k, id) in lanes.enumerated() { laneSlot[id] = k }
    var hasChild = [Bool](repeating: false, count: n)
    for i in 0..<n {
        if nodes[i].parent >= 0 { hasChild[nodes[i].parent] = true }
    }
    // Room a lane keeps around its items, so that the groups drawn around them stay inside it.
    var lanePads = [Double](repeating: lanePad, count: laneCount)
    var endPad = lanePad
    func laneOf(_ i: Int) -> Int {
        var t = i
        var room = lanePad
        for _ in 0..<laneMaxHops {
            if nodes[t].parent < 0 { break }
            t = nodes[t].parent
            if laneSlot[t] < 0 {
                room += max(nodes[t].padX, nodes[t].padTop, nodes[t].padBottom)
            }
        }
        let lane = max(0, laneSlot[t])
        if room > lanePads[lane] { lanePads[lane] = room }
        if room > endPad { endPad = room }
        return lane
    }

    // What gets ranked and placed: nodes, and groups that are empty and so act as nodes.
    var itemOf = [Int](repeating: -1, count: n)
    var real: [Int] = []
    for i in 0..<n {
        if laneSlot[i] >= 0 { continue }
        if !nodes[i].isGroup || !hasChild[i] {
            itemOf[i] = real.count
            real.append(i)
        }
    }
    let along: (CompoundNode) -> Double = { sideways ? $0.w : $0.h }
    let cross: (CompoundNode) -> Double = { sideways ? $0.h : $0.w }

    var lnodes: [LayeredNode] = real.map { LayeredNode(w: cross(nodes[$0]), h: along(nodes[$0])) }
    var ledges: [LayeredEdge] = []
    var edgeOf: [Int] = []
    var step: Int32 = 1
    do {
        var seen = Set<Int>()
        for ei in 0..<edges.count {
            let e = edges[ei]
            let a = itemOf[e.src]
            let b = itemOf[e.dst]
            if a < 0 || b < 0 || a == b { continue }
            let key = min(a, b) * real.count + max(a, b)
            if e.labelW > 0 || seen.contains(key) { step = 2 }
            seen.insert(key)
            ledges.append(LayeredEdge(tail: Int32(a), head: Int32(b), minlen: e.minlen,
                                     labelW: sideways ? e.labelH : e.labelW,
                                     labelH: sideways ? e.labelW : e.labelH))
            edgeOf.append(ei)
        }
    }
    layeredOrient(nodes: &lnodes, edges: &ledges)
    layeredRank(nodes: &lnodes, edges: &ledges, step: step)

    let m = ledges.count
    let itemLane: [Int] = real.map { laneOf($0) }
    // Lays the ranked items out and routes the relations. A plain relation is a handoff that takes
    // a simple route of its own, and so keeps no room through the ranks it passes.
    var plain = [UInt8](repeating: 0, count: m)
    var margins = [UInt8](repeating: 0, count: laneCount)
    var placed = lanePlace(nodes: &nodes, edges: &edges, lanes: lanes, real: real,
                           lnodes: lnodes, ledges: ledges, edgeOf: edgeOf, step: step,
                           itemLane: itemLane, lanePads: lanePads, endPad: endPad,
                           dir: dir, opt: opt, sideways: sideways, flipped: flipped,
                           plain: plain, margins: margins)
    // A handoff that was given a simple route needs no room kept for it through the ranks it
    // passes, so the lanes are laid out again without it. A handoff that then loses its route
    // goes back to the ranked one. Routing is most of the work, so a large graph is laid out once.
    for round in 0..<laneRounds {
        if placed.work > routeBudget / laneRelay { break }
        let next: [UInt8] = round == 0 ? placed.routed
            : plain.indices.map { plain[$0] & placed.routed[$0] }
        if next == plain && placed.margins == margins { break }
        plain = next
        margins = placed.margins
        placed = lanePlace(nodes: &nodes, edges: &edges, lanes: lanes, real: real,
                           lnodes: lnodes, ledges: ledges, edgeOf: edgeOf, step: step,
                           itemLane: itemLane, lanePads: lanePads, endPad: endPad,
                           dir: dir, opt: opt, sideways: sideways, flipped: flipped,
                           plain: plain, margins: margins)
    }
    if plain.indices.contains(where: { plain[$0] != 0 && placed.routed[$0] == 0 }) {
        placed = lanePlace(nodes: &nodes, edges: &edges, lanes: lanes, real: real,
                           lnodes: lnodes, ledges: ledges, edgeOf: edgeOf, step: step,
                           itemLane: itemLane, lanePads: lanePads, endPad: endPad,
                           dir: dir, opt: opt, sideways: sideways, flipped: flipped,
                           plain: [UInt8](repeating: 0, count: m),
                           margins: [UInt8](repeating: 0, count: laneCount))
    }
    return CompoundResult(width: placed.width, height: placed.height)
}

private struct LanePlaced {
    var width: Double
    var height: Double
    var routed: [UInt8]
    var margins: [UInt8]
    var work: Int
}

// The point where the line from one box's center to another's leaves the first box. When the
// other center is inside the box, the point is on the nearest side instead.
private func laneBorder(from: CompoundNode, to: CompoundNode) -> (Double, Double) {
    let dx = to.x - from.x
    let dy = to.y - from.y
    let hw = max(from.w / 2, 0.5)
    let hh = max(from.h / 2, 0.5)
    if abs(dx) < hw && abs(dy) < hh {
        let toSide = hw - abs(dx)
        let toEnd = hh - abs(dy)
        return toSide < toEnd ? (from.x + (dx < 0 ? -hw : hw), to.y) : (to.x, from.y + (dy < 0 ? -hh : hh))
    }
    let scale = min(dx != 0 ? hw / abs(dx) : Double.infinity,
                    dy != 0 ? hh / abs(dy) : Double.infinity)
    return (from.x + dx * scale, from.y + dy * scale)
}

private func lanePlace(nodes: inout [CompoundNode], edges: inout [CompoundEdge],
                       lanes: [Int], real: [Int],
                       lnodes: [LayeredNode], ledges: [LayeredEdge], edgeOf: [Int], step: Int32,
                       itemLane: [Int], lanePads: [Double], endPad: Double,
                       dir: CompoundDir, opt: LayeredOptions,
                       sideways: Bool, flipped: Bool,
                       plain: [UInt8], margins: [UInt8]) -> LanePlaced {
    let laneCount = max(1, lanes.count)
    let m = ledges.count
    var pad = lanePads
    for lane in 0..<laneCount {
        if lane < margins.count && margins[lane] != 0 { pad[lane] = max(pad[lane], laneMargin) }
    }
    // Items: the real ones, then a dummy for every rank an edge passes through.
    var dummies = 0
    var span = [Int](repeating: 0, count: m)
    for k in 0..<m {
        span[k] = abs(Int(lnodes[Int(ledges[k].head)].rank) - Int(lnodes[Int(ledges[k].tail)].rank))
        if plain[k] == 0 { dummies += span[k] - 1 }
    }
    let direct = dummies > laneMaxDummies
    let total = real.count + (direct ? 0 : dummies)
    var RANK = [Int](repeating: 0, count: total)
    var LANE = [Int](repeating: 0, count: total)
    var SIZE = [Double](repeating: 0, count: total)
    var DEPTH = [Double](repeating: 0, count: total)
    var DUMMY = [UInt8](repeating: 0, count: total)
    var maxRank = 0
    for k in 0..<real.count {
        RANK[k] = Int(lnodes[k].rank)
        LANE[k] = itemLane[k]
        SIZE[k] = lnodes[k].w
        DEPTH[k] = lnodes[k].h
        if RANK[k] > maxRank { maxRank = RANK[k] }
    }
    var firstDummy = [Int](repeating: -1, count: m)
    var labelItem = [Int](repeating: -1, count: m)
    var links: [Int] = []
    do {
        var next = real.count
        for k in 0..<m {
            let e = ledges[k]
            let a = e.reversed ? Int(e.head) : Int(e.tail)
            let b = e.reversed ? Int(e.tail) : Int(e.head)
            if direct || span[k] < 2 || plain[k] != 0 {
                links.append(a); links.append(b)
                continue
            }
            let ra = RANK[a]
            let rb = RANK[b]
            var labelRank = -1
            if e.labelW > 0 {
                labelRank = ra + ((rb - ra) >> 1)
                if step == 2 && (labelRank & 1) == 0 { labelRank -= 1 }
            }
            firstDummy[k] = next
            var prev = a
            for r in (ra + 1)..<rb {
                let d = next; next += 1
                RANK[d] = r
                // The edge crosses from its first lane to its last one evenly along the way.
                LANE[d] = LANE[a] + Int(round(Double(LANE[b] - LANE[a]) * Double(r - ra) / Double(rb - ra)))
                DUMMY[d] = 1
                if r == labelRank {
                    SIZE[d] = e.labelW
                    DEPTH[d] = e.labelH
                    labelItem[k] = d
                }
                links.append(prev); links.append(d)
                prev = d
            }
            links.append(prev); links.append(b)
        }
    }

    var upStart = [Int](repeating: 0, count: total + 1)
    var downStart = [Int](repeating: 0, count: total + 1)
    for k in stride(from: 0, to: links.count, by: 2) {
        downStart[links[k] + 1] += 1
        upStart[links[k + 1] + 1] += 1
    }
    for i in 0..<total {
        upStart[i + 1] += upStart[i]
        downStart[i + 1] += downStart[i]
    }
    var up = [Int](repeating: 0, count: links.count / 2)
    var down = [Int](repeating: 0, count: links.count / 2)
    do {
        var uf = Array(upStart[0..<total])
        var df = Array(downStart[0..<total])
        for k in stride(from: 0, to: links.count, by: 2) {
            down[df[links[k]]] = links[k + 1]; df[links[k]] += 1
            up[uf[links[k + 1]]] = links[k]; uf[links[k + 1]] += 1
        }
    }

    // Order within each rank: by lane first, then by where the item's neighbours sit.
    var rows = [[Int]](repeating: [], count: maxRank + 1)
    for i in 0..<total { rows[RANK[i]].append(i) }
    var pos = [Double](repeating: 0, count: total)
    var key = [Double](repeating: 0, count: total)
    func settleRank(_ r: Int) {
        let sorted = rows[r].sorted { (a: Int, b: Int) -> Bool in
            if LANE[a] != LANE[b] { return LANE[a] < LANE[b] }
            if key[a] != key[b] { return key[a] < key[b] }
            return a < b
        }
        for (k, v) in sorted.enumerated() { pos[v] = Double(k) }
        rows[r] = sorted
    }
    for r in 0...maxRank {
        for v in rows[r] { key[v] = pos[v] }
        settleRank(r)
    }
    if maxRank > 0 {
        for sweep in 0..<laneSweeps {
            let downward = (sweep & 1) == 0
            for s in 1...maxRank {
                let r = downward ? s : maxRank - s
                let start = downward ? upStart : downStart
                let list = downward ? up : down
                for i in rows[r] {
                    var sum = 0.0
                    let count = start[i + 1] - start[i]
                    for k in start[i]..<start[i + 1] { sum += pos[list[k]] }
                    key[i] = count > 0 ? sum / Double(count) : pos[i]
                }
                settleRank(r)
            }
        }
    }

    // The items of one rank that share a lane sit side by side as a run.
    let gap: (Int, Int) -> Double = { a, b in
        (DUMMY[a] != 0 || DUMMY[b] != 0) ? opt.edgeSep : opt.nodeSep
    }
    // Lane breadth: enough for its fullest rank, and for its title.
    var breadth = [Double](repeating: 0, count: laneCount)
    var head = lanes.isEmpty ? 0 : laneHead
    for k in 0..<lanes.count {
        let lane = nodes[lanes[k]]
        breadth[k] = max(0, lane.minW - 2 * pad[k])
        if lane.padTop > head { head = lane.padTop }
    }
    for row in rows {
        var from = 0
        while from < row.count {
            var to = from
            while to + 1 < row.count && LANE[row[to + 1]] == LANE[row[from]] { to += 1 }
            var size = SIZE[row[from]]
            for k in from..<to { size += gap(row[k], row[k + 1]) + SIZE[row[k + 1]] }
            if size > breadth[LANE[row[from]]] { breadth[LANE[row[from]]] = size }
            from = to + 1
        }
    }
    var laneStart = [Double](repeating: 0, count: laneCount + 1)
    for k in 0..<laneCount {
        laneStart[k + 1] = laneStart[k] + breadth[k] + 2 * pad[k]
    }

    // Across the flow: each lane's items start centered, then line up with their neighbours in
    // the same lane as far as the lane and the items beside them allow.
    var C = [Double](repeating: 0, count: total)
    var want = [Double](repeating: 0, count: total)
    func center(row: [Int], from: Int, to: Int) {
        let lane = LANE[row[from]]
        var at = (laneStart[lane] + pad[lane] + (laneStart[lane + 1] - pad[lane])
            - runSize(row: row, from: from, to: to)) / 2
        for k in from...to {
            C[row[k]] = at + SIZE[row[k]] / 2
            if k < to { at += SIZE[row[k]] + gap(row[k], row[k + 1]) }
        }
    }
    func runSize(row: [Int], from: Int, to: Int) -> Double {
        var size = SIZE[row[from]]
        for k in from..<to { size += gap(row[k], row[k + 1]) + SIZE[row[k + 1]] }
        return size
    }
    func align(row: [Int], from: Int, to: Int) {
        let lane = LANE[row[from]]
        var floor = laneStart[lane] + pad[lane]
        for k in from...to {
            let i = row[k]
            C[i] = max(want[i], floor + SIZE[i] / 2)
            if k < to { floor = C[i] + SIZE[i] / 2 + gap(i, row[k + 1]) }
        }
        var ceil = laneStart[lane + 1] - pad[lane]
        for k in stride(from: to, through: from, by: -1) {
            let i = row[k]
            C[i] = min(C[i], ceil - SIZE[i] / 2)
            if k > from { ceil = C[i] - SIZE[i] / 2 - gap(row[k - 1], i) }
        }
    }
    func eachRun(row: [Int], visit: ([Int], Int, Int) -> Void) {
        var from = 0
        while from < row.count {
            var to = from
            while to + 1 < row.count && LANE[row[to + 1]] == LANE[row[from]] { to += 1 }
            visit(row, from, to)
            from = to + 1
        }
    }
    for row in rows { eachRun(row: row, visit: center) }
    if maxRank > 0 {
        for pass in 0..<4 {
            let downward = (pass & 1) == 0
            for s in 1...maxRank {
                let row = rows[downward ? s : maxRank - s]
                let start = downward ? upStart : downStart
                let list = downward ? up : down
                for i in row {
                    var sum = 0.0
                    var count = 0
                    for k in start[i]..<start[i + 1] {
                        if LANE[list[k]] != LANE[i] { continue }
                        sum += C[list[k]]
                        count += 1
                    }
                    want[i] = count > 0 ? sum / Double(count) : C[i]
                }
                eachRun(row: row, visit: align)
            }
        }
    }

    // Along the flow: one band per rank, after the lane titles.
    let bandStart = [Double](repeating: 0, count: maxRank + 1)
    let bandEnd = [Double](repeating: 0, count: maxRank + 1)
    // The room after a rank is for the relations that turn there or are only as long as they
    // were asked to be. Where just plain handoffs and straight lines pass, the ranks close up,
    // as far as the label of a handoff between them leaves it a line to sit on.
    var sep = [Double](repeating: opt.rankSep / Double(step), count: maxRank + 1)
    if plain.contains(1) {
        let full = opt.rankSep / Double(step)
        sep = [Double](repeating: full / laneClose, count: maxRank + 1)
        for k in 0..<m {
            let e = ledges[k]
            let a = e.reversed ? Int(e.head) : Int(e.tail)
            let b = e.reversed ? Int(e.tail) : Int(e.head)
            if plain[k] != 0 {
                if e.labelH <= 0 || span[k] > Int(step) { continue }
                let room = min(full, (e.labelH + 2 * laneTurn - min(DEPTH[a], DEPTH[b]) / 2) / Double(span[k]))
                for r in RANK[a]..<RANK[b] {
                    if room > sep[r] { sep[r] = room }
                }
                continue
            }
            let d0 = firstDummy[k]
            if d0 < 0 || span[k] <= Int(step) * Int(e.minlen) {
                for r in RANK[a]..<RANK[b] { sep[r] = full }
                continue
            }
            for d in (d0 - 1)..<(d0 + span[k] - 1) {
                let u = d < d0 ? a : d
                let v = d + 1 < d0 + span[k] - 1 ? d + 1 : b
                if LANE[u] != LANE[v] || abs(C[u] - C[v]) >= 0.5 { sep[RANK[u]] = full }
            }
        }
    }
    return lanePlaceBands(nodes: &nodes, edges: &edges, lanes: lanes, real: real,
                          lnodes: lnodes, ledges: ledges, edgeOf: edgeOf,
                          RANK: RANK, LANE: LANE, SIZE: SIZE, DEPTH: DEPTH, DUMMY: DUMMY,
                          span: span, firstDummy: firstDummy, labelItem: labelItem,
                          C: C, breadth: breadth, laneStart: laneStart, pad: pad,
                          sep: sep, bandStart: bandStart, bandEnd: bandEnd,
                          head: head, endPad: endPad, maxRank: maxRank,
                          dir: dir, opt: opt, sideways: sideways, flipped: flipped,
                          plain: plain, laneCount: laneCount, total: total)
}

private func lanePlaceBands(nodes: inout [CompoundNode], edges: inout [CompoundEdge],
                            lanes: [Int], real: [Int],
                            lnodes: [LayeredNode], ledges: [LayeredEdge], edgeOf: [Int],
                            RANK: [Int], LANE: [Int], SIZE: [Double], DEPTH: [Double], DUMMY: [UInt8],
                            span: [Int], firstDummy: [Int], labelItem: [Int],
                            C: [Double], breadth: [Double], laneStart: [Double], pad: [Double],
                            sep: [Double], bandStart: [Double], bandEnd: [Double],
                            head: Double, endPad: Double, maxRank: Int,
                            dir: CompoundDir, opt: LayeredOptions,
                            sideways: Bool, flipped: Bool,
                            plain: [UInt8], laneCount: Int, total: Int) -> LanePlaced {
    let m = ledges.count
    var used = [UInt8](repeating: 0, count: laneCount)
    var bandStart = bandStart
    var bandEnd = bandEnd
    var at = head + endPad
    for r in 0...maxRank {
        var depth = 0.0
        for i in 0..<total {
            if RANK[i] == r && DEPTH[i] > depth { depth = DEPTH[i] }
        }
        bandStart[r] = at
        bandEnd[r] = at + depth
        at += depth + (r == maxRank ? 0 : sep[r])
    }
    let length = at + endPad
    let breadthTotal = laneStart[laneCount]
    let flip: (Double) -> Double = { a in flipped ? head + length - a : a }
    let px: (Double, Double) -> Double = { c, a in sideways ? flip(a) : c }
    let py: (Double, Double) -> Double = { c, a in sideways ? c : flip(a) }
    let axis: Double = sideways ? 1 : 0

    for k in 0..<real.count {
        let a = (bandStart[RANK[k]] + bandEnd[RANK[k]]) / 2
        nodes[real[k]].x = px(C[k], a)
        nodes[real[k]].y = py(C[k], a)
    }
    for k in 0..<lanes.count {
        let c = (laneStart[k] + laneStart[k + 1]) / 2
        let size = laneStart[k + 1] - laneStart[k]
        nodes[lanes[k]].x = sideways ? length / 2 : c
        nodes[lanes[k]].y = sideways ? c : length / 2
        nodes[lanes[k]].w = sideways ? length : size
        nodes[lanes[k]].h = sideways ? size : length
        nodes[lanes[k]].padTop = head
    }

    // Groups inside a lane are drawn around their members, deepest first.
    var laneSlot = [Int](repeating: -1, count: nodes.count)
    for (k, id) in lanes.enumerated() { laneSlot[id] = k }
    var itemOf = [Int](repeating: -1, count: nodes.count)
    for (k, v) in real.enumerated() { itemOf[v] = k }
    var depthOf = [Int](repeating: 0, count: nodes.count)
    var inner: [Int] = []
    for i in 0..<nodes.count {
        if !nodes[i].isGroup || laneSlot[i] >= 0 || itemOf[i] >= 0 { continue }
        var d = 0
        var p = nodes[i].parent
        var hops = 0
        while p >= 0 && hops < laneMaxHops { d += 1; p = nodes[p].parent; hops += 1 }
        depthOf[i] = d
        inner.append(i)
    }
    inner.sort { depthOf[$0] != depthOf[$1] ? depthOf[$0] > depthOf[$1] : $0 < $1 }
    var box = [Double](repeating: 0, count: nodes.count * 4)
    for i in 0..<nodes.count {
        box[i * 4] = Double.infinity; box[i * 4 + 1] = Double.infinity
        box[i * 4 + 2] = -Double.infinity; box[i * 4 + 3] = -Double.infinity
    }
    func grow(_ g: Int, _ c: CompoundNode) {
        if c.x - c.w / 2 < box[g * 4] { box[g * 4] = c.x - c.w / 2 }
        if c.y - c.h / 2 < box[g * 4 + 1] { box[g * 4 + 1] = c.y - c.h / 2 }
        if c.x + c.w / 2 > box[g * 4 + 2] { box[g * 4 + 2] = c.x + c.w / 2 }
        if c.y + c.h / 2 > box[g * 4 + 3] { box[g * 4 + 3] = c.y + c.h / 2 }
    }
    for i in real {
        if nodes[i].parent >= 0 && laneSlot[nodes[i].parent] < 0 { grow(nodes[i].parent, nodes[i]) }
    }
    for g in inner {
        if box[g * 4] == Double.infinity { continue }
        let w = max(box[g * 4 + 2] - box[g * 4] + 2 * nodes[g].padX, nodes[g].minW)
        nodes[g].x = (box[g * 4] + box[g * 4 + 2]) / 2
        nodes[g].w = w
        nodes[g].y = (box[g * 4 + 1] - nodes[g].padTop + box[g * 4 + 3] + nodes[g].padBottom) / 2
        nodes[g].h = box[g * 4 + 3] - box[g * 4 + 1] + nodes[g].padTop + nodes[g].padBottom
        if nodes[g].parent >= 0 && laneSlot[nodes[g].parent] < 0 { grow(nodes[g].parent, nodes[g]) }
    }

    for i in 0..<edges.count { edges[i].route = [] }
    for k in 0..<m {
        let e = ledges[k]
        let out = edgeOf[k]
        let a = e.reversed ? Int(e.head) : Int(e.tail)
        let b = e.reversed ? Int(e.tail) : Int(e.head)
        var pts: [Double] = [C[a], bandEnd[RANK[a]] - (bandEnd[RANK[a]] - bandStart[RANK[a]] - DEPTH[a]) / 2]
        let d0 = firstDummy[k]
        if d0 >= 0 {
            for d in d0..<(d0 + span[k] - 1) {
                pts.append(C[d]); pts.append(bandStart[RANK[d]])
                if bandEnd[RANK[d]] > bandStart[RANK[d]] {
                    pts.append(C[d]); pts.append(bandEnd[RANK[d]])
                }
            }
        }
        pts.append(C[b]); pts.append(bandStart[RANK[b]] + (bandEnd[RANK[b]] - bandStart[RANK[b]] - DEPTH[b]) / 2)
        var route: [Double] = []
        for p in stride(from: 0, to: pts.count, by: 2) {
            route.append(px(pts[p], pts[p + 1])); route.append(py(pts[p], pts[p + 1])); route.append(axis)
        }
        if e.reversed {
            var i = 0, j = route.count - 3
            while i < j {
                for t in 0..<2 {
                    let keep = route[i + t]
                    route[i + t] = route[j + t]
                    route[j + t] = keep
                }
                i += 3; j -= 3
            }
        }
        edges[out].route = route
        let label = labelItem[k]
        if label >= 0 {
            let mid = (bandStart[RANK[label]] + bandEnd[RANK[label]]) / 2
            edges[out].labelX = px(C[label], mid)
            edges[out].labelY = py(C[label], mid)
        } else {
            edges[out].labelX = (route[0] + route[route.count - 3]) / 2
            edges[out].labelY = (route[1] + route[route.count - 2]) / 2
        }
    }

    // An edge that starts or ends at a lane or a group runs straight to its border.
    for i in 0..<edges.count {
        if !edges[i].route.isEmpty || edges[i].src == edges[i].dst { continue }
        let (ax, ay) = laneBorder(from: nodes[edges[i].src], to: nodes[edges[i].dst])
        let (bx, by) = laneBorder(from: nodes[edges[i].dst], to: nodes[edges[i].src])
        let flat: Double = abs(bx - ax) > abs(by - ay) ? 1 : 0
        edges[i].route = [ax, ay, flat, bx, by, flat]
        edges[i].labelX = (ax + bx) / 2
        edges[i].labelY = (ay + by) / 2
    }

    // A handoff can leave towards the other lane, then arrive along the flow (or vice versa).
    // In particular, a decision's return branch must not leave through its incoming side and
    // retrace the path past the preceding step. Try the two single-corner routes, keeping the
    // ranked route when a node or another label blocks them.
    var routed = [UInt8](repeating: 0, count: m)
    let routePoints = edges.reduce(0) { $0 + $1.route.count / 3 }
    let work = m * (real.count + edges.count + routePoints)
    if work <= routeBudget {
        var amid = [Double](repeating: 0, count: total)
        for i in 0..<total { amid[i] = (bandStart[RANK[i]] + bandEnd[RANK[i]]) / 2 }
        var labels = edges.map { (sideways ? $0.labelY : $0.labelX, flip(sideways ? $0.labelX : $0.labelY)) }
        let overlaps: (Double, Double, Double, Double, Double, Double, Double, Double) -> Bool =
        { c0, a0, c1, a1, lc, la, cw, ah in
            c1 > lc - cw / 2 && c0 < lc + cw / 2 && a1 > la - ah / 2 && a0 < la + ah / 2
        }
        func clear(_ c0: Double, _ a0: Double, _ c1: Double, _ a1: Double,
                   src: Int, dst: Int, ei: Int) -> Bool {
            for i in 0..<real.count {
                if i != src && i != dst
                    && overlaps(c0, a0, c1, a1, C[i], amid[i], SIZE[i] + 8, DEPTH[i] + 8) {
                    return false
                }
            }
            for i in 0..<edges.count {
                let e = edges[i]
                // A step's own loop keeps its label inside the step's box, and has no place here.
                if i != ei && e.labelW > 0 && e.src != e.dst
                    && overlaps(c0, a0, c1, a1, labels[i].0, labels[i].1,
                                sideways ? e.labelH : e.labelW, sideways ? e.labelW : e.labelH) {
                    return false
                }
            }
            return true
        }
        // How many other relations have a stretch inside a box. A stretch's whole box counts,
        // including its curve.
        func crossings(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, ei: Int) -> Int {
            var count = 0
            for i in 0..<edges.count {
                if i == ei { continue }
                let route = edges[i].route
                var j = 3
                while j < route.count {
                    if max(route[j - 3], route[j]) > x0 && min(route[j - 3], route[j]) < x1
                        && max(route[j - 2], route[j + 1]) > y0
                        && min(route[j - 2], route[j + 1]) < y1 {
                        count += 1
                        break
                    }
                    j += 3
                }
            }
            return count
        }
        func meets(_ x: Double, _ y: Double, ei: Int) -> Int {
            var count = 0
            for i in 0..<edges.count {
                let route = edges[i].route
                if i == ei || route.isEmpty { continue }
                let last = route.count - 3
                if (abs(route[0] - x) < 1 && abs(route[1] - y) < 1)
                    || (abs(route[last] - x) < 1 && abs(route[last + 1] - y) < 1) {
                    count += 1
                }
            }
            return count
        }
        // Two relations drawn along one line read as a single path. Those that leave the same step
        // or arrive at the same step may share a trunk; any other pair must not.
        func retraces(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, ei: Int) -> Bool {
            let upright = abs(x1 - x0) < 0.5
            let lo = upright ? min(y0, y1) : min(x0, x1)
            let hi = upright ? max(y0, y1) : max(x0, x1)
            let line = upright ? x0 : y0
            for i in 0..<edges.count {
                let other = edges[i]
                if i == ei || other.src == edges[ei].src || other.dst == edges[ei].dst { continue }
                let route = other.route
                var j = 3
                while j < route.count {
                    let u0 = route[j - 3 + (upright ? 0 : 1)], u1 = route[j + (upright ? 0 : 1)]
                    if abs(u0 - line) >= laneNear || abs(u1 - line) >= laneNear { j += 3; continue }
                    let v0 = route[j - 3 + (upright ? 1 : 0)], v1 = route[j + (upright ? 1 : 0)]
                    if min(hi, max(v0, v1)) - max(lo, min(v0, v1)) > 1 { return true }
                    j += 3
                }
            }
            return false
        }
        for k in 0..<m {
            let e = ledges[k]
            let ei = edgeOf[k]
            let a = Int(e.tail), b = Int(e.head)
            if LANE[a] == LANE[b] || abs(C[b] - C[a]) < 1 { continue }
            let ac = C[a], bc = C[b], aa = amid[a], ba = amid[b]
            let dc: Double = bc == ac ? 0 : (bc > ac ? 1 : -1)
            let da: Double = ba == aa ? 0 : (ba > aa ? 1 : -1)
            func attempt(_ pts: [Double], margin: Double) -> Bool {
                var p = 2
                while p < pts.count {
                    if !clear(min(pts[p - 2], pts[p]) - margin, min(pts[p - 1], pts[p + 1]) - margin,
                               max(pts[p - 2], pts[p]) + margin, max(pts[p - 1], pts[p + 1]) + margin,
                               src: a, dst: b, ei: ei) { return false }
                    if retraces(px(pts[p - 2], pts[p - 1]), py(pts[p - 2], pts[p - 1]),
                                px(pts[p], pts[p + 1]), py(pts[p], pts[p + 1]), ei: ei) { return false }
                    p += 2
                }
                var lc = 0.0, la = 0.0
                var longest = -1.0
                let out = edges[ei]
                if out.labelW > 0 {
                    let cw = e.labelW, ah = e.labelH
                    var q = 2
                    while q < pts.count {
                        let cc = (pts[q - 2] + pts[q]) / 2, ca = (pts[q - 1] + pts[q + 1]) / 2
                        let across = abs(pts[q] - pts[q - 2]), along = abs(pts[q + 1] - pts[q - 1])
                        let run = across + along
                        if run > longest && !(across > 0 ? across < cw + 8 : along < ah + 8)
                            && cc - cw / 2 >= 0 && cc + cw / 2 <= breadthTotal
                            && ca - ah / 2 >= 0 && ca + ah / 2 <= length
                            && clear(cc - cw / 2, ca - ah / 2, cc + cw / 2, ca + ah / 2,
                                     src: -1, dst: -1, ei: ei) {
                            // A label moved onto a handoff must not cover a return path that keeps its
                            // ranked route. A segment's whole box is kept clear, including its curve.
                            let lx = px(cc, ca), ly = py(cc, ca)
                            if crossings(lx - out.labelW / 2, ly - out.labelH / 2,
                                         lx + out.labelW / 2, ly + out.labelH / 2, ei: ei) == 0 {
                                lc = cc; la = ca; longest = run
                            }
                        }
                        q += 2
                    }
                    if longest < 0 { return false }
                }
                // A point short of each corner and one past it keep the turn close to the corner, so
                // that the line stays under its label and the handoff takes little room.
                var way = [pts[0], pts[1]]
                var q = 2
                while q < pts.count {
                    let dx = pts[q] - pts[q - 2], dy = pts[q + 1] - pts[q - 1]
                    let run = abs(dx) + abs(dy)
                    let first = q > 2 ? laneTurn : 0, last = q + 2 < pts.count ? laneTurn : 0
                    if run > first + last + 1 {
                        if first != 0 {
                            way.append(pts[q - 2] + (dx / run) * first)
                            way.append(pts[q - 1] + (dy / run) * first)
                        }
                        if last != 0 {
                            way.append(pts[q] - (dx / run) * last)
                            way.append(pts[q + 1] - (dy / run) * last)
                        }
                    }
                    way.append(pts[q]); way.append(pts[q + 1])
                    q += 2
                }
                edges[ei].route = []
                var w = 0
                while w < way.count {
                    let crosswise = w == 0 ? way[0] != way[2] : way[w] != way[w - 2]
                    edges[ei].route.append(px(way[w], way[w + 1]))
                    edges[ei].route.append(py(way[w], way[w + 1]))
                    edges[ei].route.append(crosswise ? 1 - axis : axis)
                    w += 2
                }
                if out.labelW > 0 {
                    edges[ei].labelX = px(lc, la)
                    edges[ei].labelY = py(lc, la)
                    labels[ei] = (lc, la)
                }
                routed[k] = 1
                return true
            }
            if attempt([ac + dc * SIZE[a] / 2, aa, bc, aa, bc, ba - da * DEPTH[b] / 2], margin: 2) { continue }
            if attempt([ac, aa + da * DEPTH[a] / 2, ac, ba, bc - dc * SIZE[b] / 2, ba], margin: 2) { continue }
            // With both corners blocked, as for a return past the steps between, the handoff goes
            // around: out to the margin of a lane, along it, and back in level with its end. It
            // takes the margin that crosses the fewest other relations and shares the fewest ends
            // with them, then the shortest way.
            if work > routeBudget / laneRelay { continue }
            var around: [(pts: [Double], cost: Double, lane: Int)] = []
            for lane in (LANE[a] < LANE[b] ? [LANE[b], LANE[a]] : [LANE[a], LANE[b]]) {
                // A lane that keeps no margin yet has less room there, and the handoff stays inside it.
                let inVal = max(pad[lane] - laneLeg, min(pad[lane] / 2, laneMargin - laneLeg))
                for ch in [laneStart[lane] + inVal, laneStart[lane + 1] - inVal] {
                    if abs(ch - ac) < SIZE[a] / 2 + 4 || abs(ch - bc) < SIZE[b] / 2 + 4 { continue }
                    let pts = [ac + (ch - ac > 0 ? 1 : -1) * SIZE[a] / 2, aa, ch, aa, ch, ba,
                               bc + (ch - bc > 0 ? 1 : -1) * SIZE[b] / 2, ba]
                    var cost = Double(meets(px(pts[0], pts[1]), py(pts[0], pts[1]), ei: ei)
                        + meets(px(pts[6], pts[7]), py(pts[6], pts[7]), ei: ei)) * 1e6
                    var q = 2
                    while q < pts.count {
                        let x0 = px(pts[q - 2], pts[q - 1]), y0 = py(pts[q - 2], pts[q - 1])
                        let x1 = px(pts[q], pts[q + 1]), y1 = py(pts[q], pts[q + 1])
                        cost += Double(crossings(min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1), ei: ei)) * 1e6
                            + abs(x1 - x0) + abs(y1 - y0)
                        q += 2
                    }
                    around.append((pts, cost, lane))
                }
            }
            around.sort { $0.cost < $1.cost }
            for cand in around {
                if !attempt(cand.pts, margin: 1) { continue }
                used[cand.lane] = 1
                break
            }
        }
    }

    return LanePlaced(width: sideways ? length : breadthTotal,
                      height: sideways ? breadthTotal : length,
                      routed: routed, margins: used, work: work)
}
