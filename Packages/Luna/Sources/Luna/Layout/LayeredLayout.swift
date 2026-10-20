// Ported from Pele src/layout/layered.ts @ 8603bf3 (MIT, Copyright (c) 2026 kepano). See Packages/Luna/NOTICE.
// Layered (Sugiyama-style) layout of one flat graph. Ranks run down the y axis; callers
// rotate the result for other directions.
//
// What the layout of edges aims for, most important first. Where two aims pull apart, the one
// higher up decides, and each names where it is carried out.
//
// 1. Lines can be told apart. No two touch or run along each other, and none runs through a
//    node or a label. Ends on one side of a node have places of their own (`spread`), and
//    curves that would pass within a few pixels turn at levels of their own (`assignTracks`).
// 2. Lines cross as little as the order of the nodes allows (`reduceCrossings`, and the order
//    of the levels in `assignTracks`).
// 3. An edge takes the shortest and simplest way: straight if it can, else one curve, else a
//    curve with a level run. One that passes several ranks runs in line with one of its ends
//    and turns once, at the other (`alignLabels`, `straighten`). Ends slide along their sides,
//    and nodes move a little, where that makes an edge straight (`settle`, `snap`).
// 4. An edge meets the middle of a side. An end with a side to itself stays there, and ends
//    that share a side sit around the middle in the order of where they lead. An end moves off
//    the middle only for the aims above (`settle`).
// 5. The drawing is balanced, and what is alike is drawn alike. A label sits midway along the
//    line that shows, the curves either side of it have much the same room to turn in, and a gap
//    whose curves mostly cross has them all as the same plain curve rather than each on a
//    level of its own (`headRoom` in `layered`, the crossed gaps in `assignTracks`).
// 6. An edge leaves and reaches a node square to it, and an arrowhead points straight at the
//    node (`routePath` in svg/edges.ts, which draws the routes).
// 7. Nodes keep the order they were written in, where nothing above says otherwise.
// 8. The drawing stays compact. A gap between ranks grows only to hold the levels in it, or
//    to let curves that cross do so at a clear angle.
//
// Luna note: Luna draws orthogonal polylines, so Luna always routes with
// `tracks: true`. The curve-mode branches are ported for fidelity but unused.
import Foundation

/// Node kind in the layered graph.
public enum LayeredKind: Int, Sendable {
    case node = 0
    case dummy = 1
    case label = 2
    case startPort = 3
    case endPort = 4
}

/// A node of the flat layered graph.
public struct LayeredNode: Sendable {
    public var w: Double
    public var h: Double
    public var kind: LayeredKind
    public var pin: Int32
    /// How much of the side that edges meet may be shared out between them; 0 keeps them all at its middle.
    public var span: Double
    public var x: Double
    public var y: Double
    public var rank: Int32

    public init(w: Double, h: Double, kind: LayeredKind = .node) {
        self.w = w; self.h = h; self.kind = kind
        self.pin = 0; self.span = 0; self.x = 0; self.y = 0; self.rank = 0
    }
}

/// An edge of the flat layered graph.
public struct LayeredEdge: Sendable {
    public var tail: Int32
    public var head: Int32
    public var minlen: Int32
    public var labelW: Double
    public var labelH: Double
    public var tailDx: Double
    public var headDx: Double
    /// An end that is held where its offset puts it, and takes no part in sharing out a node's side.
    public var tailFixed: Bool
    public var headFixed: Bool
    public var reversed: Bool
    public var points: [Double]
    public var labelX: Double
    public var labelY: Double

    public init(tail: Int32, head: Int32, minlen: Int32 = 1, labelW: Double = 0, labelH: Double = 0) {
        self.tail = tail; self.head = head; self.minlen = minlen
        self.labelW = labelW; self.labelH = labelH
        self.tailDx = 0; self.headDx = 0
        self.tailFixed = false; self.headFixed = false; self.reversed = false
        self.points = []; self.labelX = 0; self.labelY = 0
    }
}

/// Options for the layered layout.
public struct LayeredOptions: Sendable {
    public var nodeSep: Double
    public var edgeSep: Double
    public var rankSep: Double
    public var portSep: Double
    /// Route edges at right angles, each on a track of its own across the gap between two ranks.
    public var tracks: Bool
    /// Draw every edge straight from point to point: none is given a level to turn onto.
    public var straight: Bool
    /// The caller sets the ends of the edges on one side of a node apart itself, so two edges
    /// between the same two nodes need no bend to keep them from being drawn as one.
    public var apart: Bool
    /// The room that the marker at the head of an edge takes. A rank of labels whose edges all
    /// head the same way sits half of this nearer their tails, so that each label is midway along
    /// the line that shows, and the curves either side of it have the same room to turn in.
    public var headRoom: Double

    public init(nodeSep: Double, edgeSep: Double, rankSep: Double, portSep: Double,
                tracks: Bool = false, straight: Bool = false, apart: Bool = false, headRoom: Double = 0) {
        self.nodeSep = nodeSep; self.edgeSep = edgeSep; self.rankSep = rankSep; self.portSep = portSep
        self.tracks = tracks; self.straight = straight; self.apart = apart; self.headRoom = headRoom
    }
}

/// The size of a layered result. Node positions land on the nodes, edge routes on the edges.
public struct LayeredResult: Sendable {
    public var width: Double
    public var height: Double
}

public func makeLayeredNode(w: Double, h: Double, kind: LayeredKind = .node) -> LayeredNode {
    LayeredNode(w: w, h: h, kind: kind)
}

public func makeLayeredEdge(tail: Int32, head: Int32, minlen: Int32 = 1, labelW: Double = 0, labelH: Double = 0) -> LayeredEdge {
    LayeredEdge(tail: tail, head: head, minlen: minlen, labelW: labelW, labelH: labelH)
}

private let maxSweeps = 24

// An edge gets a bend point in every rank it skips. Past this many, the longest edges are
// drawn as one direct curve instead, which keeps huge graphs from exhausting time and memory.
private let maxDummies = 20000

// The room between two edges that meet one side of a node, and the least that keeps their arrowheads apart.
private let portPitch = 16.0
private let minPitch = 8.0

// Where edges are not given levels, a gap between ranks grows to keep the edges that cross it at
// least this steep, up to this many times its usual height. Shallower than that, the edges of a
// wide rank are hard to tell apart.
private let minSlope = 0.125
private let maxGap = 3.0

// Tracks: the room kept clear between a rank and the nearest track, the room between two tracks
// when the gap has to grow to hold them, and the most they spread to when it has room to spare.
private let trackMargin = 18.0
private let trackPitch = 10.0
private let trackSpread = 14.0
// A curve is one plain S unless it runs more than this many times as far across as the gap is
// high, and so does another that it would run along. Then each turns onto a level of its own
// to run across on. The levels of a gap keep this far from its ranks, to leave room to turn
// in, and from each other.
private let levelWide = 2.0
private let levelMargin = 28.0
private let levelPitch = 12.0
// Two plain curves that would pass too near each other turn at levels of their own as well:
// nearer than LEVEL_CLEAR where one of them runs far across, since it stays near the other for
// a long way, and otherwise nearer than LEVEL_TOUCH. LEVEL_LEAD is the room a plain curve is
// taken to keep straight at each end of its gap.
private let levelLead = 12.0
private let levelClear = 8.0
private let levelTouch = 4.0
// Levels tell apart curves that run alongside each other. Where the curves of a gap cross each
// other more often than that, runs along levels only make the crossings long and shallow, so
// each curve is one plain S instead, and the gap is made this many times as tall as its widest
// curve runs across (and no taller than MAX_GAP allows), for them to cross at a clear angle.
private let crossedSlope = 0.5
// How far out of line two points may be and still count as in line.
private let inLine = 0.5
// A node, with whatever it is already in line with, moves this far at most to bring one more of
// its edges into line.
private let snapDistance = 12.0
// An end that cannot be brought into line leans towards where its edge goes, but keeps this far
// from the ends of the part of its side that edges spread along. On a narrow node that leaves
// it in the middle.
private let leanClear = 40.0
// Past this many edges across one gap, tracks are given out in a plain order: weighing every
// pair of edges against each other would take too long.
private let maxWeighed = 400

private enum LayeredEnd: UInt8 {
    case held = 0
    case leaves = 1
    case arrives = 2
}

private func isDummyKind(_ kind: LayeredKind) -> Bool {
    kind == .dummy || kind == .label
}

// Insertion sort of list[from..<to] by key, ties broken by item index (deterministic).
private func sortRange(_ list: inout [Int32], from: Int, to: Int, key: [Int32]) {
    var i = from + 1
    while i < to {
        let item = list[i]
        let k = key[Int(item)]
        var j = i - 1
        while j >= from && (key[Int(list[j])] > k || (key[Int(list[j])] == k && list[j] > item)) {
            list[j + 1] = list[j]
            j -= 1
        }
        list[j + 1] = item
        i += 1
    }
}

private func sortRangeDouble(_ list: inout [Int32], from: Int, to: Int, key: [Double]) {
    var i = from + 1
    while i < to {
        let item = list[i]
        let k = key[Int(item)]
        var j = i - 1
        while j >= from && (key[Int(list[j])] > k || (key[Int(list[j])] == k && list[j] > item)) {
            list[j + 1] = list[j]
            j -= 1
        }
        list[j + 1] = item
        i += 1
    }
}

// Sorts the slice arr[range] in place (ArraySlice.sort() would sort a copy).
private func sortSlice(_ arr: inout [Int32], _ range: Range<Int>) {
    let sorted = arr[range].sorted()
    for (i, v) in zip(range, sorted) { arr[i] = v }
}

// Internal working graph: flat arrays the way the TS uses typed arrays.
private struct LayeredGraph {
    var n: Int
    var real: Int
    var maxRank: Int
    var W: [Double]
    var KIND: [LayeredKind]
    var RANK: [Int32]
    // Segment endpoints, and where each segment attaches on them.
    var EF: [Int32]
    var ET: [Int32]
    var EFD: [Double]
    var ETD: [Double]
    var succStart: [Int32]
    var succE: [Int32]
    var predStart: [Int32]
    var predE: [Int32]
    var layerStart: [Int32]
    var order: [Int32]
    var pos: [Int32]
    var offsets: Bool
}

public func layered(nodes: inout [LayeredNode], edges: inout [LayeredEdge], opt: LayeredOptions) -> LayeredResult {
    let real = nodes.count
    if real == 0 { return LayeredResult(width: 0, height: 0) }
    let m = edges.count

    // Every edge gets a middle rank of its own when labels or parallel edges need the room.
    var step: Int32 = 1
    if m > 0 {
        var seen = Set<Int>()
        for e in edges {
            let a = min(Int(e.tail), Int(e.head))
            let b = max(Int(e.tail), Int(e.head))
            let key = a * real + b
            if e.labelW > 0 || seen.contains(key) {
                step = 2
                break
            }
            seen.insert(key)
        }
    }

    layeredOrient(nodes: &nodes, edges: &edges)
    layeredRank(nodes: &nodes, edges: &edges, step: step)

    var span = [Int32](repeating: 0, count: m)
    var dummies = 0
    for ei in 0..<m {
        let e = edges[ei]
        span[ei] = abs(nodes[Int(e.head)].rank - nodes[Int(e.tail)].rank)
        if span[ei] > 1 { dummies += Int(span[ei]) - 1 }
    }
    var direct = [UInt8](repeating: 0, count: m)
    if dummies > maxDummies {
        var longest: [Int] = []
        for ei in 0..<m where span[ei] > 1 { longest.append(ei) }
        longest.sort { span[$0] != span[$1] ? span[$0] > span[$1] : $0 < $1 }
        for ei in longest {
            if dummies <= maxDummies { break }
            direct[ei] = 1
            dummies -= Int(span[ei]) - 1
        }
    }

    let n = real + dummies
    var W = [Double](repeating: 0, count: n)
    var H = [Double](repeating: 0, count: n)
    var KIND = [LayeredKind](repeating: .dummy, count: n)
    var RANK = [Int32](repeating: 0, count: n)
    var maxRank: Int32 = 0
    for i in 0..<real {
        W[i] = nodes[i].w
        H[i] = nodes[i].h
        KIND[i] = nodes[i].kind
        RANK[i] = nodes[i].rank
        if nodes[i].rank > maxRank { maxRank = nodes[i].rank }
    }

    // The graph that gets ordered and positioned: every edge cut into rank-to-rank segments.
    var segments = 0
    for ei in 0..<m where direct[ei] == 0 { segments += Int(span[ei]) }
    var EF = [Int32](repeating: 0, count: segments)
    var ET = [Int32](repeating: 0, count: segments)
    var EFD = [Double](repeating: 0, count: segments)
    var ETD = [Double](repeating: 0, count: segments)
    var firstDummy = [Int32](repeating: -1, count: m)
    // Which way the edges with a label in each rank head: 1 down, 2 up, 3 both.
    var heads = [UInt8](repeating: 0, count: Int(maxRank) + 1)
    var labelNode = [Int32](repeating: -1, count: m)
    var spans = false
    for i in 0..<real where nodes[i].span > 0 && nodes[i].kind == .node { spans = true }
    // What each segment's end is to the node it meets, for the ends that may move along the node's side.
    var efkArr: [UInt8]? = spans ? [UInt8](repeating: 0, count: segments) : nil
    var etkArr: [UInt8]? = spans ? [UInt8](repeating: 0, count: segments) : nil
    var firstSeg = [Int32](repeating: -1, count: m)
    var lastSeg = [Int32](repeating: -1, count: m)
    var offsets = false
    do {
        var next = real
        var ce = 0
        for ei in 0..<m {
            if direct[ei] != 0 { continue }
            let e = edges[ei]
            let a = e.reversed ? e.head : e.tail
            let b = e.reversed ? e.tail : e.head
            let aDx = e.reversed ? e.headDx : e.tailDx
            let bDx = e.reversed ? e.tailDx : e.headDx
            if aDx != 0 || bDx != 0 { offsets = true }
            let ra = RANK[Int(a)]
            let rb = RANK[Int(b)]
            var labelRank: Int32 = -1
            if e.labelW > 0 {
                // The label goes halfway along. An edge that passes ranks of nodes on its way has its
                // label in one of those, beside the nodes, where it takes no height of its own: the one
                // halfway, or of the two either side of halfway, the one nearer the node the edge starts
                // from, which is the lower when the edge runs against the flow. An edge between two
                // neighbouring ranks has its label in the rank between them.
                labelRank = ra + ((rb - ra) >> 1)
                if step == 2 && rb - ra >= 4 {
                    if (labelRank & 1) == 1 { labelRank += e.reversed ? 1 : -1 }
                } else if step == 2 && (labelRank & 1) == 0 {
                    labelRank += e.reversed ? 1 : -1
                }
            }
            var prev = a
            if rb - ra > 1 { firstDummy[ei] = Int32(next) }
            firstSeg[ei] = Int32(ce)
            if !(e.reversed ? e.headFixed : e.tailFixed) {
                efkArr?[ce] = (e.reversed ? LayeredEnd.arrives : LayeredEnd.leaves).rawValue
            }
            var r = ra + 1
            while r < rb {
                let d = next; next += 1
                RANK[d] = r
                if r == labelRank {
                    W[d] = e.labelW
                    H[d] = e.labelH
                    KIND[d] = .label
                    labelNode[ei] = Int32(d)
                    heads[Int(r)] |= e.reversed ? 2 : 1
                } else {
                    KIND[d] = .dummy
                }
                EF[ce] = prev
                ET[ce] = Int32(d)
                EFD[ce] = prev == a ? aDx : 0
                ce += 1
                prev = Int32(d)
                r += 1
            }
            EF[ce] = prev
            ET[ce] = b
            EFD[ce] = prev == a ? aDx : 0
            ETD[ce] = bDx
            if !(e.reversed ? e.tailFixed : e.headFixed) {
                etkArr?[ce] = (e.reversed ? LayeredEnd.leaves : LayeredEnd.arrives).rawValue
            }
            lastSeg[ei] = Int32(ce)
            ce += 1
        }
    }

    var succStart = [Int32](repeating: 0, count: n + 1)
    var predStart = [Int32](repeating: 0, count: n + 1)
    for e in 0..<segments {
        succStart[Int(EF[e]) + 1] += 1
        predStart[Int(ET[e]) + 1] += 1
    }
    for i in 0..<n {
        succStart[i + 1] += succStart[i]
        predStart[i + 1] += predStart[i]
    }
    var succE = [Int32](repeating: 0, count: segments)
    var predE = [Int32](repeating: 0, count: segments)
    do {
        var sf = Array(succStart[0..<n])
        var pf = Array(predStart[0..<n])
        for e in 0..<segments {
            succE[Int(sf[Int(EF[e])])] = Int32(e); sf[Int(EF[e])] += 1
            predE[Int(pf[Int(ET[e])])] = Int32(e); pf[Int(ET[e])] += 1
        }
    }

    var layerStart = [Int32](repeating: 0, count: Int(maxRank) + 2)
    for i in 0..<n { layerStart[Int(RANK[i]) + 1] += 1 }
    for r in 0...Int(maxRank) { layerStart[r + 1] += layerStart[r] }
    var order = [Int32](repeating: 0, count: n)
    var pos = [Int32](repeating: 0, count: n)

    // Initial order: depth-first from the top so that subtrees start out contiguous.
    do {
        var byRank = [Int32](repeating: 0, count: n)
        var fill = Array(layerStart[0...Int(maxRank)])
        for i in 0..<n { byRank[Int(fill[Int(RANK[i])])] = Int32(i); fill[Int(RANK[i])] += 1 }
        fill = Array(layerStart[0...Int(maxRank)])
        var visited = [UInt8](repeating: 0, count: n)
        var stack: [Int32] = []
        for k in 0..<n {
            if visited[Int(byRank[k])] != 0 { continue }
            stack.append(byRank[k])
            while !stack.isEmpty {
                let v = stack.removeLast()
                if visited[Int(v)] != 0 { continue }
                visited[Int(v)] = 1
                order[Int(fill[Int(RANK[Int(v)])])] = v; fill[Int(RANK[Int(v)])] += 1
                var j = Int(succStart[Int(v) + 1]) - 1
                while j >= Int(succStart[Int(v)]) {
                    let w = ET[Int(succE[j])]
                    if visited[Int(w)] == 0 { stack.append(w) }
                    j -= 1
                }
            }
        }
    }

    var pinned = false
    for i in 0..<real where nodes[i].pin != 0 { pinned = true; break }
    let pinVals = nodes.map { $0.pin }
    if pinned {
        for r in 0...Int(maxRank) {
            var layer = Array(order[Int(layerStart[r])..<Int(layerStart[r + 1])])
            var index: [Int32: Int] = [:]
            for (i, v) in layer.enumerated() { index[v] = i }
            let pinOf = { (v: Int32) -> Int32 in v < Int32(real) ? pinVals[Int(v)] : 0 }
            layer.sort { pinOf($0) != pinOf($1) ? pinOf($0) < pinOf($1) : index[$0]! < index[$1]! }
            for (i, v) in layer.enumerated() { order[Int(layerStart[r]) + i] = v }
        }
    }
    func setPositions() {
        for r in 0...Int(maxRank) {
            let s = Int(layerStart[r])
            let e = Int(layerStart[r + 1])
            for i in s..<e { pos[Int(order[i])] = Int32(i - s) }
        }
    }
    setPositions()

    var g = LayeredGraph(n: n, real: real, maxRank: Int(maxRank), W: W, KIND: KIND, RANK: RANK,
                         EF: EF, ET: ET, EFD: EFD, ETD: ETD,
                         succStart: succStart, succE: succE, predStart: predStart, predE: predE,
                         layerStart: layerStart, order: order, pos: pos, offsets: offsets)

    if segments > 0 && maxRank > 0 {
        reduceCrossings(&g, nodes: nodes)
        order = g.order; pos = g.pos
        setPositions()
        g.order = order; g.pos = pos
    }

    var xs: [Double]
    if let efk = efkArr, let etk = etkArr {
        layeredSpread(&g, nodes: nodes, EFK: efk, ETK: etk)
        xs = layeredPosition(g, opt: opt)
    } else {
        xs = layeredPosition(g, opt: opt)
    }
    g.order = order; g.pos = pos
    EFD = g.EFD; ETD = g.ETD

    let empty = emptyRanks(g)
    if let efk = efkArr, let etk = etkArr {
        let free = freeEnds(g, EFK: efk, ETK: etk)
        alignLabels(&g, nodes: nodes, xs: &xs, free: free, opt: opt, empty: empty)
        settle(&g, nodes: nodes, xs: &xs, EFK: efk, ETK: etk, free: free, empty: empty)
        snap(&g, xs: &xs, empty: empty, opt: opt)
        EFD = g.EFD; ETD = g.ETD
        for ei in 0..<m {
            if direct[ei] != 0 { continue }
            let e = edges[ei]
            let aDx = EFD[Int(firstSeg[ei])]
            let bDx = ETD[Int(lastSeg[ei])]
            edges[ei].tailDx = e.reversed ? bDx : aDx
            edges[ei].headDx = e.reversed ? aDx : bDx
        }
    }

    // A rank that holds nothing but the bends of edges is only there because some other edge has a
    // label or a twin. Its bends move onto the straight line between the ends of their edges, and
    // one that gets there is left out of the route, so that the edge is drawn as a single curve.
    var onLine = [UInt8](repeating: 0, count: n)
    if empty != nil && !opt.tracks {
        straighten(&g, xs: &xs, empty: empty!, firstDummy: firstDummy, span: span, sep: opt.apart ? 0 : opt.edgeSep, onLine: &onLine)
    }
    if !opt.tracks {
        pastLabels(&g, xs: &xs, firstDummy: firstDummy, span: span, clear: opt.edgeSep, onLine: &onLine)
    }
    // An edge is cut where it passes a rank that holds something, and each piece crosses one gap.
    // With `tracks`, every piece that does not run straight gets a track to run across on at
    // right angles. Otherwise, where edges spread along their nodes, a piece gets one only if it
    // needs a level to turn onto. `pieceStart` gives every edge's run of pieces.
    var pieceFrom: [Double] = []
    var pieceTo: [Double] = []
    var pieceRank: [Int32] = []
    var pieceLower: [Int32] = []
    var pieceTrack: [Int32] = []
    var pieceLevels: [Int32] = []
    var pieceWide: [Int32] = []
    var pieceStart = [Int32](repeating: 0, count: m + 1)
    let hasPieces = opt.tracks || (efkArr != nil && !opt.straight)
    var trackCount = [Int32](repeating: 0, count: Int(maxRank) + 1)
    if hasPieces {
        for ei in 0..<m {
            pieceStart[ei] = Int32(pieceFrom.count)
            if direct[ei] != 0 { continue }
            let d0 = Int(firstDummy[ei])
            // An edge that keeps a bend to stay clear of its twin is drawn through the bend, as it is.
            var twin = false
            if d0 >= 0 {
                let end = d0 + Int(span[ei]) - 1
                for d in d0..<end {
                    // So is one that has a bend left out in a rank of labels: its curve crosses that rank.
                    let bare = empty != nil && empty![Int(RANK[d])] == 1
                    if !opt.tracks && bare != (onLine[d] == 1) { twin = true }
                }
            }
            if twin { continue }
            var x = xs[Int(EF[Int(firstSeg[ei])])] + EFD[Int(firstSeg[ei])]
            var rank = RANK[Int(EF[Int(firstSeg[ei])])]
            if d0 >= 0 {
                let end = d0 + Int(span[ei]) - 1
                for d in d0..<end {
                    if empty != nil && empty![Int(RANK[d])] != 0 { continue }
                    pieceFrom.append(x); pieceTo.append(xs[d])
                    pieceRank.append(rank); pieceLower.append(Int32(d))
                    x = xs[d]; rank = RANK[d]
                }
            }
            pieceFrom.append(x); pieceTo.append(xs[Int(ET[Int(lastSeg[ei])])] + ETD[Int(lastSeg[ei])])
            pieceRank.append(rank); pieceLower.append(-1)
        }
        pieceStart[m] = Int32(pieceFrom.count)
    }

    // Ranks that hold only border ports or their pass-through dummies need little room of their own.
    let portOnly: (Int, LayeredKind) -> Bool = { r, kind in
        var found = false
        for i in Int(layerStart[r])..<Int(layerStart[r + 1]) {
            let k = KIND[Int(order[i])]
            if k == kind { found = true }
            else if k != .dummy { return false }
        }
        return found
    }
    let startRanks: Int = (maxRank >= 0 && portOnly(0, .startPort)) ? Int(step) : 0
    let endRanks: Int = (maxRank >= 0 && portOnly(Int(maxRank), .endPort)) ? Int(step) : 0
    // The longest way across that any edge travels in the gap below each rank.
    var run = [Double](repeating: 0, count: Int(maxRank) + 1)
    for e in 0..<segments {
        let across = abs(xs[Int(EF[e])] + EFD[e] - xs[Int(ET[e])] - ETD[e])
        if across > run[Int(RANK[Int(EF[e])])] { run[Int(RANK[Int(EF[e])])] = across }
    }
    var bandTop = [Double](repeating: 0, count: Int(maxRank) + 1)
    var bandBottom = [Double](repeating: 0, count: Int(maxRank) + 1)
    let usual: (Int) -> Double = { r in
        (r < startRanks || r >= Int(maxRank) - endRanks ? opt.portSep : opt.rankSep) / Double(step)
    }
    // The room under each rank. Edges that are not cut into pieces need more where they run far across.
    var gapUnder = [Double](repeating: 0, count: Int(maxRank) + 1)
    for r in 0..<Int(maxRank) {
        gapUnder[r] = hasPieces ? usual(r) : max(usual(r), min((maxGap * opt.rankSep) / Double(step), run[r] * minSlope))
    }
    // A rank between two ranks of nodes, which holds labels and bends only.
    var between = [UInt8](repeating: 1, count: Int(maxRank) + 1)
    for i in 0..<real { between[Int(RANK[i])] = 0 }
    if maxRank >= 2 {
        for r in 1..<Int(maxRank) {
            if opt.tracks || between[r] == 0 || (heads[r] != 1 && heads[r] != 2) { continue }
            let shift = min(opt.headRoom / 2, gapUnder[heads[r] == 1 ? r - 1 : r] / 2)
            gapUnder[r - 1] += heads[r] == 1 ? -shift : shift
            gapUnder[r] += heads[r] == 1 ? shift : -shift
        }
    }
    // The part of its rank that an edge runs straight through at a bend or label. A bare bend
    // beside labels keeps to the middle half, which leaves the curves either side of it more room
    // and still keeps them clear of the labels' corners.
    let inset: (Int) -> Double = { d in
        (KIND[d] == .dummy && between[Int(RANK[d])] != 0 && !opt.tracks
            ? (bandBottom[Int(RANK[d])] - bandTop[Int(RANK[d])]) / 4 : 0)
    }
    // The rank that the pieces leaving each rank arrive at, past any that hold only bends, and
    // the room between the two, which grows to hold the gap's tracks or levels: these keep
    // `margin` from the ranks, and between `leastPitch` and `mostPitch` from each other.
    let margin = opt.tracks ? trackMargin : levelMargin
    let leastPitch = opt.tracks ? trackPitch : levelPitch
    let mostPitch = opt.tracks ? trackSpread : levelPitch
    var below = [Int32](repeating: 0, count: Int(maxRank) + 1)
    if hasPieces {
        var room = [Double](repeating: 0, count: Int(maxRank) + 1)
        for r in 0..<Int(maxRank) {
            if empty != nil && empty![r] != 0 { continue }
            var next = r + 1
            room[r] = gapUnder[r]
            while next < Int(maxRank) && empty != nil && empty![next] != 0 {
                room[r] += gapUnder[next]; next += 1
            }
            below[r] = Int32(next)
        }
        for k in 0..<pieceFrom.count {
            pieceWide.append(abs(pieceFrom[k] - pieceTo[k]) > levelWide * room[Int(pieceRank[k])] ? 1 : 0)
        }
        var tall = [Double](repeating: 0, count: Int(maxRank) + 1)
        assignTracks(&pieceFrom, &pieceTo, pieceRank, &pieceTrack, &pieceLevels, pieceWide,
                     trackCount: &trackCount, curved: !opt.tracks, room: room, tall: &tall)
        for r in 0..<Int(maxRank) {
            if trackCount[r] > 0 {
                gapUnder[r] += max(0, 2 * margin + Double(trackCount[r] - 1) * leastPitch - room[r])
            } else if tall[r] > 0 {
                gapUnder[r] += max(0, min(maxGap * opt.rankSep, tall[r]) - room[r])
            }
        }
    }
    var y = 0.0
    for r in 0...Int(maxRank) {
        var h = 0.0
        for i in Int(layerStart[r])..<Int(layerStart[r + 1]) {
            if H[Int(order[i])] > h { h = H[Int(order[i])] }
        }
        bandTop[r] = y; bandBottom[r] = y + h
        y += h + gapUnder[r]
    }
    let height = y
    // Where a piece runs across its gap, or would on another track of its group: its tracks sit
    // in the middle of the gap, the first at the top.
    let trackY: (Int, Int32?) -> Double = { piece, onTrack in
        let t = onTrack ?? pieceTrack[piece]
        let r = Int(pieceRank[piece])
        let top = bandBottom[r]
        let bottom = bandTop[Int(below[r])]
        let count = opt.tracks ? trackCount[r] : pieceLevels[piece]
        let pitch: Double = count > 1 ? min(mostPitch, (bottom - top - 2 * margin) / Double(count - 1)) : 0
        return (top + bottom) / 2 + (Double(t) - Double(count - 1) / 2) * pitch
    }

    var minX = Double.infinity
    var maxX = -Double.infinity
    for i in 0..<n {
        let half = W[i] / 2
        if xs[i] - half < minX { minX = xs[i] - half }
        if xs[i] + half > maxX { maxX = xs[i] + half }
    }
    // Where edges spread along their nodes, a rank whose nodes only send edges on stands on one
    // line, and a rank whose nodes only receive them hangs from one, so that the edges of nodes of
    // different heights set out from, or arrive at, the same level. In any other rank the nodes
    // are centered.
    var arrives = [UInt8](repeating: 0, count: Int(maxRank) + 1)
    var leaves = [UInt8](repeating: 0, count: Int(maxRank) + 1)
    if efkArr != nil {
        for i in 0..<real {
            if KIND[i] != .node { continue }
            if predStart[i + 1] > predStart[i] { arrives[Int(RANK[i])] = 1 }
            if succStart[i + 1] > succStart[i] { leaves[Int(RANK[i])] = 1 }
        }
    }
    for i in 0..<real {
        let r = Int(nodes[i].rank)
        nodes[i].x = xs[i] - minX
        if KIND[i] == .node && leaves[r] != 0 && arrives[r] == 0 {
            nodes[i].y = bandBottom[r] - nodes[i].h / 2
        } else if KIND[i] == .node && arrives[r] != 0 && leaves[r] == 0 {
            nodes[i].y = bandTop[r] + nodes[i].h / 2
        } else {
            nodes[i].y = (bandTop[r] + bandBottom[r]) / 2
        }
    }

    for ei in 0..<m {
        let e = edges[ei]
        let first = nodes[e.reversed ? Int(e.head) : Int(e.tail)]
        let last = nodes[e.reversed ? Int(e.tail) : Int(e.head)]
        var pts: [Double] = [first.x + (e.reversed ? e.headDx : e.tailDx), first.y + first.h / 2]
        if hasPieces && pieceStart[ei + 1] > pieceStart[ei] {
            for k in Int(pieceStart[ei])..<Int(pieceStart[ei + 1]) {
                if pieceTrack[k] >= 0 && (opt.tracks || pieceWide[k] == 1) {
                    let across = trackY(k, nil)
                    pts.append(pieceFrom[k] - minX); pts.append(across)
                    pts.append(pieceTo[k] - minX); pts.append(across)
                } else if pieceTrack[k] > 0 {
                    // A short piece among levels runs straight until it is past the level before its
                    // own, and turns in one S from there, so that it crosses none of them.
                    pts.append(pieceFrom[k] - minX); pts.append(trackY(k, pieceTrack[k] - 1))
                }
                let d = Int(pieceLower[k])
                if d < 0 { continue }
                pts.append(xs[d] - minX); pts.append(bandTop[Int(RANK[d])] + inset(d))
                if bandBottom[Int(RANK[d])] > bandTop[Int(RANK[d])] {
                    pts.append(xs[d] - minX); pts.append(bandBottom[Int(RANK[d])] - inset(d))
                }
            }
        } else if Int(firstDummy[ei]) >= 0 {
            let d0 = Int(firstDummy[ei])
            let end = d0 + Int(span[ei]) - 1
            for d in d0..<end {
                if onLine[d] != 0 { continue }
                let x = xs[d] - minX
                let top = bandTop[Int(RANK[d])]
                let bottom = bandBottom[Int(RANK[d])]
                pts.append(x); pts.append(top + inset(d))
                if bottom > top { pts.append(x); pts.append(bottom - inset(d)) }
            }
        }
        pts.append(last.x + (e.reversed ? e.tailDx : e.headDx)); pts.append(last.y - last.h / 2)
        if e.reversed {
            var i = 0, j = pts.count - 2
            while i < j {
                let tx = pts[i], ty = pts[i + 1]
                pts[i] = pts[j]; pts[i + 1] = pts[j + 1]
                pts[j] = tx; pts[j + 1] = ty
                i += 2; j -= 2
            }
        }
        edges[ei].points = pts
        let ln = Int(labelNode[ei])
        if ln >= 0 {
            edges[ei].labelX = xs[ln] - minX
            edges[ei].labelY = (bandTop[Int(RANK[ln])] + bandBottom[Int(RANK[ln])]) / 2
        } else if e.labelW > 0 {
            edges[ei].labelX = (pts[0] + pts[pts.count - 2]) / 2
            edges[ei].labelY = (pts[1] + pts[pts.count - 1]) / 2
        }
    }

    // Sync the working arrays back (nodes/edges carry the result).
    return LayeredResult(width: maxX - minX, height: height)
}

// Reverses the edges that close a cycle, found by depth-first search in declaration order.
public func layeredOrient(nodes: inout [LayeredNode], edges: inout [LayeredEdge]) {
    let n = nodes.count
    let m = edges.count
    var start = [Int32](repeating: 0, count: n + 1)
    for i in 0..<m {
        edges[i].reversed = nodes[Int(edges[i].head)].kind == .startPort
            || nodes[Int(edges[i].tail)].kind == .endPort
        if !edges[i].reversed { start[Int(edges[i].tail) + 1] += 1 }
    }
    for i in 0..<n { start[i + 1] += start[i] }
    var out = [Int32](repeating: 0, count: Int(start[n]))
    do {
        var fill = Array(start[0..<n])
        for i in 0..<m where !edges[i].reversed {
            out[Int(fill[Int(edges[i].tail)])] = Int32(i); fill[Int(edges[i].tail)] += 1
        }
    }
    var state = [UInt8](repeating: 0, count: n)
    var cursor = Array(start[0..<n])
    var stack: [Int32] = []
    for root in 0..<n {
        if state[root] != 0 { continue }
        stack.append(Int32(root))
        state[root] = 1
        while !stack.isEmpty {
            let v = Int(stack.last!)
            if cursor[v] < start[v + 1] {
                let e = out[Int(cursor[v])]; cursor[v] += 1
                let w = Int(edges[Int(e)].head)
                if state[w] == 1 { edges[Int(e)].reversed = true }
                else if state[w] == 0 {
                    state[w] = 1
                    stack.append(Int32(w))
                }
            } else {
                state[v] = 2
                stack.removeLast()
            }
        }
    }
}

public func layeredRank(nodes: inout [LayeredNode], edges: inout [LayeredEdge], step: Int32) {
    let n = nodes.count
    let m = edges.count
    var from = [Int32](repeating: 0, count: m)
    var to = [Int32](repeating: 0, count: m)
    var len = [Int32](repeating: 0, count: m)
    var outStart = [Int32](repeating: 0, count: n + 1)
    var inStart = [Int32](repeating: 0, count: n + 1)
    for i in 0..<m {
        let e = edges[i]
        let a = e.reversed ? e.head : e.tail
        let b = e.reversed ? e.tail : e.head
        from[i] = a; to[i] = b
        len[i] = max(1, e.minlen) * step
        outStart[Int(a) + 1] += 1
        inStart[Int(b) + 1] += 1
    }
    for i in 0..<n {
        outStart[i + 1] += outStart[i]
        inStart[i + 1] += inStart[i]
    }
    var outE = [Int32](repeating: 0, count: m)
    var inE = [Int32](repeating: 0, count: m)
    do {
        var of = Array(outStart[0..<n])
        var inf = Array(inStart[0..<n])
        for i in 0..<m {
            outE[Int(of[Int(from[i])])] = Int32(i); of[Int(from[i])] += 1
            inE[Int(inf[Int(to[i])])] = Int32(i); inf[Int(to[i])] += 1
        }
    }

    var r = [Int32](repeating: 0, count: n)
    var indeg = [Int32](repeating: 0, count: n)
    for i in 0..<n { indeg[i] = inStart[i + 1] - inStart[i] }
    var topo = [Int32](repeating: 0, count: n)
    var count = 0
    for i in 0..<n where indeg[i] == 0 { topo[count] = Int32(i); count += 1 }
    var q = 0
    while q < count {
        let v = Int(topo[q]); q += 1
        for k in Int(outStart[v])..<Int(outStart[v + 1]) {
            let ei = Int(outE[k])
            let w = Int(to[ei])
            if r[v] + len[ei] > r[w] { r[w] = r[v] + len[ei] }
            indeg[w] -= 1
            if indeg[w] == 0 { topo[count] = Int32(w); count += 1 }
        }
    }

    // Longest-path ranking leaves loosely attached nodes far from their neighbours.
    // Move each node toward the side that has more edges.
    for _ in 0..<8 {
        var changed = false
        var qi = count - 1
        while qi >= 0 {
            let v = Int(topo[qi]); qi -= 1
            let ins = inStart[v + 1] - inStart[v]
            let outs = outStart[v + 1] - outStart[v]
            if ins == 0 && outs == 0 { continue }
            var lo = -Int32.max
            var hi = Int32.max
            var hasLo = false, hasHi = false
            for k in Int(inStart[v])..<Int(inStart[v + 1]) {
                let ei = Int(inE[k])
                let cand = from[ei] >= 0 ? r[Int(from[ei])] + len[ei] : 0
                if !hasLo || cand > lo { lo = cand; hasLo = true }
            }
            for k in Int(outStart[v])..<Int(outStart[v + 1]) {
                let ei = Int(outE[k])
                let cand = r[Int(to[ei])] - len[ei]
                if !hasHi || cand < hi { hi = cand; hasHi = true }
            }
            var next = r[v]
            if outs > ins && hasHi { next = hi }
            else if ins > outs && hasLo { next = lo }
            if next != r[v] { r[v] = next; changed = true }
        }
        if !changed { break }
    }

    var min = Int32.max
    var max = Int32.min
    var startPorts = false
    for i in 0..<n {
        let kind = nodes[i].kind
        if kind == .startPort { startPorts = true }
        if kind == .startPort || kind == .endPort { continue }
        if r[i] < min { min = r[i] }
        if r[i] > max { max = r[i] }
    }
    if min == Int32.max { min = 0; max = 0 }
    for i in 0..<n {
        if nodes[i].kind == .startPort { r[i] = min - step }
        else if nodes[i].kind == .endPort { r[i] = max + step }
    }
    if startPorts { min -= step }
    for i in 0..<n { nodes[i].rank = r[i] - min }
}

// The ends of edges that may move along one side of a node (0 the side its edges arrive at, 1 the
// other), in the order of the nodes at their other ends, so that no two cross. `room` receives
// the least distance between each end and the one before it, and the result is their sum.
// When there is too little room for a full pitch between each pair, the edges that leave side by
// side move closer together, since they have no arrowheads to keep apart. With less room still,
// neighbours that run the same way share a place, which keeps an arrowhead apart from an edge
// that leaves beside it.
private func sideEnds(_ g: LayeredGraph, v: Int, side: Int, span: Double, kinds: [UInt8], ids: inout [Int], room: inout [Double]) -> Double {
    let start = side == 0 ? g.predStart : g.succStart
    let list = side == 0 ? g.predE : g.succE
    let other = side == 0 ? g.EF : g.ET
    let pos = g.pos
    ids.removeAll(keepingCapacity: true)
    for k in Int(start[v])..<Int(start[v + 1]) {
        if kinds[Int(list[k])] != LayeredEnd.held.rawValue { ids.append(Int(list[k])) }
    }
    if ids.count < 2 { return 0 }
    ids.sort { pos[Int(other[$0])] != pos[Int(other[$1])] ? pos[Int(other[$0])] < pos[Int(other[$1])] : $0 < $1 }
    func fill(_ share: (Bool, Bool) -> Double) -> Double {
        var total = 0.0
        room.removeAll(keepingCapacity: true)
        room.append(0)
        for k in 1..<ids.count {
            let same = kinds[ids[k]] == kinds[ids[k - 1]]
            let rk = share(same && kinds[ids[k]] == LayeredEnd.leaves.rawValue, same)
            room.append(rk)
            total += rk
        }
        return total
    }
    var total = fill({ _, _ in 1 })
    if span / total < minPitch { total = fill({ leaves, _ in leaves ? 0.5 : 1 }) }
    if span / total < minPitch { total = fill({ _, same in same ? 0 : 1 }) }
    if total == 0 { return 0 }
    let pitch = min(portPitch, span / total)
    for k in 1..<ids.count { room[k] *= pitch }
    return total * pitch
}

// Gives the edges that meet one side of a node places of their own along it, around its middle.
private func layeredSpread(_ g: inout LayeredGraph, nodes: [LayeredNode], EFK: [UInt8], ETK: [UInt8]) {
    let real = g.real
    var ids: [Int] = []
    var room: [Double] = []
    for v in 0..<real {
        let span = min(nodes[v].span, g.W[v])
        if span <= 0 || nodes[v].kind != .node { continue }
        for side in 0..<2 {
            let total = sideEnds(g, v: v, side: side, span: span,
                                 kinds: side == 0 ? ETK : EFK, ids: &ids, room: &room)
            if total == 0 { continue }
            var at = -total / 2
            for k in 0..<ids.count {
                at += room[k]
                if side == 0 { g.ETD[ids[k]] = at } else { g.EFD[ids[k]] = at }
            }
        }
    }
}

// The segment of an edge that reaches the next point held in place, on the way up from segment
// `e` (side 0) or down: past the bends in ranks that hold nothing else.
private func followSeg(_ g: LayeredGraph, empty: [UInt8]?, e: Int, side: Int) -> Int {
    guard let empty else { return e }
    var e = e
    for _ in 0..<100000 {
        let u = Int(side == 0 ? g.EF[e] : g.ET[e])
        if g.KIND[u] != .dummy || empty[Int(g.RANK[u])] == 0 { break }
        e = Int(side == 0 ? g.predE[Int(g.predStart[u])] : g.succE[Int(g.succStart[u])])
    }
    return e
}

// How many ends that may move along it each node has on the side its edges arrive at, and on
// the other. An end that has a side to itself keeps to the middle; ends that share one cannot
// all be there, so those may move.
private func freeEnds(_ g: LayeredGraph, EFK: [UInt8], ETK: [UInt8]) -> ([Int32], [Int32]) {
    var free0 = [Int32](repeating: 0, count: g.n)
    var free1 = [Int32](repeating: 0, count: g.n)
    for e in 0..<g.EF.count {
        if ETK[e] != LayeredEnd.held.rawValue { free0[Int(g.ET[e])] += 1 }
        if EFK[e] != LayeredEnd.held.rawValue { free1[Int(g.EF[e])] += 1 }
    }
    return (free0, free1)
}

// How far along the flow the handles of a plain S reach, as a share of the way it travels along
// it. Half gives an even S. One that runs more than eight times as far across as along turns
// sooner and crosses in a straighter line, down to a quarter at sixteen times. The layout uses
// this to tell how near two curves will pass, and the drawing to draw them.
public func layeredEase(across: Double, along: Double) -> Double {
    max(0.25, min(0.5, (4 * abs(along)) / (abs(across) == 0 ? 1 : abs(across))))
}

// Brings the labels and bends of each edge into line with an end of the edge, so that it runs
// straight from that end and turns once, at the other: with the end that has fewer edges beside
// it on its node, which is the one nearer the middle of its side, or else with the other, and
// as near to that as what is beside them in their ranks leaves room. The other end may then move
// along its node to meet the line. Bends in ranks that hold nothing else are left to `straighten`.
// An edge with no one line that all of its labels and bends have room on has each brought into
// line with the nearest point above or below that is held in place.
private func alignLabels(_ g: inout LayeredGraph, nodes: [LayeredNode], xs: inout [Double],
                         free: ([Int32], [Int32]), opt: LayeredOptions, empty: [UInt8]?) {
    let sep = opt.edgeSep
    let n = g.n
    let maxRank = g.maxRank
    func placed(_ v: Int) -> Bool {
        g.KIND[v] == .label || (g.KIND[v] == .dummy && !(empty != nil && empty![Int(g.RANK[v])] == 1))
    }
    // Where segment `e` ends on the way up (side 0) or down, and how many ends share that side of
    // the node there: none for a point that is not on a node.
    func end(_ e: Int, _ side: Int) -> (Double, Int32) {
        let u = Int(side == 0 ? g.EF[e] : g.ET[e])
        let x = side == 0 ? xs[u] + g.EFD[e] : xs[u] + g.ETD[e]
        let shared = side == 0 ? free.1 : free.0
        return (x, u < g.real && nodes[u].kind == .node ? shared[u] : 0)
    }
    // The room the neighbours in its rank leave a label or bend: a full gap from a node or between
    // two labels, half of one between a label and a line that passes it.
    func room(_ v: Int) -> (Double, Double) {
        let s = Int(g.layerStart[Int(g.RANK[v])])
        let i = s + Int(g.pos[v])
        func clear(_ other: Int) -> Double {
            g.W[other] / 2 + g.W[v] / 2
                + (g.KIND[other] == .node ? opt.nodeSep / 2 + sep / 2
                    : g.KIND[other] == g.KIND[v] ? sep : sep / 2)
        }
        let lo = i > s ? xs[Int(g.order[i - 1])] + clear(Int(g.order[i - 1])) : -Double.infinity
        let hi = i + 1 < Int(g.layerStart[Int(g.RANK[v]) + 1])
            ? xs[Int(g.order[i + 1])] - clear(Int(g.order[i + 1])) : Double.infinity
        return (lo, hi)
    }
    // The place between `lo` and `hi` that is in line with one of two ends, or else nearest the first choice.
    func choose(_ x: Double, _ up: (Double, Int32), _ down: (Double, Int32), _ lo: Double, _ hi: Double) -> Double {
        let upFirst = up.1 != down.1 ? up.1 < down.1 : abs(up.0 - x) <= abs(down.0 - x)
        let choices = upFirst ? [up.0, down.0] : [down.0, up.0]
        for c in choices where c >= lo && c <= hi { return c }
        return max(lo, min(hi, choices[0]))
    }
    var done = [UInt8](repeating: 0, count: n)
    var chain: [Int] = []
    if maxRank >= 2 {
        for r in 1..<maxRank {
            for i in Int(g.layerStart[r])..<Int(g.layerStart[r + 1]) {
                if !placed(Int(g.order[i])) || done[Int(g.order[i])] != 0 { continue }
                // The edge's labels and bends from its first node to its last, and the room they share.
                var top = Int(g.order[i])
                while g.KIND[Int(g.EF[Int(g.predE[Int(g.predStart[top])])])] == .dummy
                    || g.KIND[Int(g.EF[Int(g.predE[Int(g.predStart[top])])])] == .label {
                    top = Int(g.EF[Int(g.predE[Int(g.predStart[top])])])
                }
                var bottom = top
                var lo = -Double.infinity
                var hi = Double.infinity
                chain.removeAll(keepingCapacity: true)
                var d = top
                while g.KIND[d] == .dummy || g.KIND[d] == .label {
                    bottom = d
                    if placed(d) {
                        done[d] = 1
                        chain.append(d)
                        let (least, most) = room(d)
                        if least > lo { lo = least }
                        if most < hi { hi = most }
                    }
                    d = Int(g.ET[Int(g.succE[Int(g.succStart[d])])])
                }
                if lo <= hi {
                    let x = choose(xs[chain[0]],
                                   end(Int(g.predE[Int(g.predStart[top])]), 0),
                                   end(Int(g.succE[Int(g.succStart[bottom])]), 1), lo, hi)
                    for dd in chain { xs[dd] = x }
                    continue
                }
                for dd in chain {
                    let (least, most) = room(dd)
                    if least > most { continue }
                    xs[dd] = choose(xs[dd],
                                    end(followSeg(g, empty: empty, e: Int(g.predE[Int(g.predStart[dd])]), side: 0), 0),
                                    end(followSeg(g, empty: empty, e: Int(g.succE[Int(g.succStart[dd])]), side: 1), 1),
                                    least, most)
                }
            }
        }
    }
}

// Once the nodes have their places, moves an end along its side when that lets its edge run
// straight: when the point the edge runs to, or some part of the side it runs to, is in line
// with the end's own side. Any other end leans towards the point its edge runs to, where its
// side is long enough, and an end with a side to itself stays in the middle. On a group, the
// ends keep clear of the points where other edges pass through its border.
private func settle(_ g: inout LayeredGraph, nodes: [LayeredNode], xs: inout [Double],
                    EFK: [UInt8], ETK: [UInt8], free: ([Int32], [Int32]), empty: [UInt8]?) {
    let real = g.real
    var ids: [Int] = []
    var room: [Double] = []
    var all: [Int] = []
    var sum: [Double] = []
    var count: [Int] = []
    // Where the end of segment `e` on node `v` should be, from the middle of its side. The edge is
    // followed up from the segment (side 0) or down, past the bends in ranks that hold nothing
    // else, to where it next comes to a point that is held in place or to another node's side.
    func wanted(_ e: Int, _ side: Int, _ v: Int, _ span: Double, _ again: Bool) -> Double {
        if (side == 0 ? free.0 : free.1)[v] < 2 { return 0 }
        let f = followSeg(g, empty: empty, e: e, side: side)
        let u = Int(side == 0 ? g.EF[f] : g.ET[f])
        let point = side == 0 ? xs[u] + g.EFD[f] : xs[u] + g.ETD[f]
        // Once the other end has its place, this one comes into line with it if it can.
        if again && abs(point - xs[v]) <= span / 2 + inLine {
            return max(-span / 2, min(span / 2, point - xs[v]))
        }
        // The part of the other side that its end may move along, if it may move.
        var middle = point
        var width = 0.0
        if u < real && nodes[u].kind == .node
            && (side == 0 ? EFK : ETK)[f] != LayeredEnd.held.rawValue && (side == 0 ? free.1 : free.0)[u] >= 2 {
            width = max(0, min(nodes[u].span, g.W[u]))
            if width > 0 { middle = xs[u] }
        }
        let lo = max(xs[v] - span / 2, middle - width / 2)
        let hi = min(xs[v] + span / 2, middle + width / 2)
        // Two sides with no part in line: the end leans towards the other, if its side is long enough.
        if lo > hi + inLine {
            let lean = max(0, span / 2 - leanClear)
            return max(-lean, min(lean, point - xs[v]))
        }
        // Both ends settle on one place in the part the two sides share: nearer the middle of the narrower.
        let place = (xs[v] * width + middle * span) / (width + span)
        return max(lo, min(hi, place)) - xs[v]
    }
    // The ends of an edge follow each other, so the nodes are gone over until none moves: a few
    // times at most, in practice.
    var pass = 0
    var moved = true
    while moved && pass < 6 {
        moved = false
        pass += 1
        for v in 0..<real {
            let span = min(nodes[v].span, g.W[v])
            if span <= 0 || nodes[v].kind != .node { continue }
            for side in 0..<2 {
                let kinds = side == 0 ? ETK : EFK
                let other = side == 0 ? g.EF : g.ET
                let start = side == 0 ? g.predStart : g.succStart
                let list = side == 0 ? g.predE : g.succE
                _ = sideEnds(g, v: v, side: side, span: span, kinds: kinds, ids: &ids, room: &room)
                if ids.isEmpty { continue }
                // JS grows the shared array on assignment; only room[0] is read below.
                if ids.count == 1 { room = [0] }
                // Every end on the side in order, the held ones among them, which divide the rest into runs.
                all.removeAll(keepingCapacity: true)
                for k in Int(start[v])..<Int(start[v + 1]) { all.append(Int(list[k])) }
                all.sort {
                    g.pos[Int(other[$0])] != g.pos[Int(other[$1])]
                        ? g.pos[Int(other[$0])] < g.pos[Int(other[$1])] : $0 < $1
                }
                var k = 0
                var lo = -span / 2
                var i = 0
                while i <= all.count {
                    let held = i < all.count && kinds[all[i]] == LayeredEnd.held.rawValue
                    if i < all.count && !held { i += 1; continue }
                    // The run of free ends before this point is ids[k..], as many as were passed since the last held end.
                    var size = 0
                    var j = i - 1
                    while j >= 0 && kinds[all[j]] != LayeredEnd.held.rawValue { size += 1; j -= 1 }
                    let dxVal: Double = held
                        ? (side == 0 ? g.ETD[all[i]] : g.EFD[all[i]]) - portPitch : span / 2
                    if size > 0 {
                        // The places nearest the wanted ones that keep the order and the room between
                        // neighbours: an isotonic fit, by pooling neighbours that would otherwise be too close.
                        sum.removeAll(keepingCapacity: true)
                        count.removeAll(keepingCapacity: true)
                        var before = 0.0
                        for jj in 0..<size {
                            if jj > 0 { before += room[k + jj] }
                            sum.append(wanted(ids[k + jj], side, v, span, pass > 1) - before)
                            count.append(1)
                            // Ends that share a place for want of room stay together.
                            var together = jj > 0 && room[k + jj] == 0
                            while sum.count > 1 && (together || sum[sum.count - 2] / Double(count[count.count - 2]) > sum[sum.count - 1] / Double(count[count.count - 1])) {
                                together = false
                                let top = sum.removeLast()
                                let pooled = count.removeLast()
                                sum[sum.count - 1] += top
                                count[count.count - 1] += pooled
                            }
                        }
                        let total = before
                        var jj = 0
                        before = 0
                        for b in 0..<sum.count {
                            // With too little room between two held ends, the run sits in the middle of what there is.
                            let level = hi2(total: total, lo: lo, hi: dxVal)
                                ? (lo + dxVal - total) / 2
                                : max(lo, min(dxVal - total, sum[b] / Double(count[b])))
                            for _ in 0..<count[b] {
                                if jj > 0 { before += room[k + jj] }
                                if side == 0 {
                                    if abs(g.ETD[ids[k + jj]] - level - before) > 0.01 { moved = true }
                                    g.ETD[ids[k + jj]] = level + before
                                } else {
                                    if abs(g.EFD[ids[k + jj]] - level - before) > 0.01 { moved = true }
                                    g.EFD[ids[k + jj]] = level + before
                                }
                                jj += 1
                            }
                        }
                        k += size
                    }
                    if held {
                        lo = (side == 0 ? g.ETD[all[i]] : g.EFD[all[i]]) + portPitch
                    }
                    i += 1
                }
            }
        }
    }
}

// Helper: whether hi - total < lo.
private func hi2(total: Double, lo: Double, hi: Double) -> Bool {
    hi - total < lo
}

// Brings edges that are nearly straight into line, by moving a node a little across the flow
// along with everything it is in line with already, where the nodes beside them leave room.
// What is in line stays in line, so each move leaves one more edge straight.
private func snap(_ g: inout LayeredGraph, xs: inout [Double], empty: [UInt8]?, opt: LayeredOptions) {
    let n = g.n
    func passed(_ u: Int) -> Bool {
        empty != nil && g.KIND[u] == .dummy && empty![Int(g.RANK[u])] == 1
    }
    // Each edge from one point that is held in place to the next, past the bends in ranks that hold nothing else.
    var avec: [Int] = []
    var bvec: [Int] = []
    var davec: [Double] = []
    var dbvec: [Double] = []
    for e in 0..<g.EF.count {
        if passed(Int(g.EF[e])) { continue }
        let f = followSeg(g, empty: empty, e: e, side: 1)
        avec.append(Int(g.EF[e])); bvec.append(Int(g.ET[f]))
        davec.append(g.EFD[e]); dbvec.append(g.ETD[f])
    }
    func off(_ k: Int) -> Double { xs[bvec[k]] + dbvec[k] - xs[avec[k]] - davec[k] }
    // The nodes in line with each other move as one.
    var block = [Int](0..<n)
    var members: [[Int]] = (0..<n).map { [$0] }
    let join: (Int, Int) -> Void = { x, y in
        var keep = block[x]
        var drop = block[y]
        if keep == drop { return }
        if members[keep].count < members[drop].count { swap(&keep, &drop) }
        for v in members[drop] {
            block[v] = keep
            members[keep].append(v)
        }
        members[drop] = []
    }
    var near: [Int] = []
    for k in 0..<avec.count {
        let d = abs(off(k))
        if d < 0.01 { join(avec[k], bvec[k]) }
        else if d <= snapDistance { near.append(k) }
    }
    if near.isEmpty { return }
    near.sort { abs(off($0)) != abs(off($1)) ? abs(off($0)) < abs(off($1)) : $0 < $1 }
    func gap(_ v: Int) -> Double { halfRoom(g, opt: opt, v: v) }
    // Whether every node of a block can move by `shift` and keep its room from those beside it.
    func free(_ id: Int, _ shift: Double) -> Bool {
        for v in members[id] {
            let s = Int(g.layerStart[Int(g.RANK[v])])
            let end = Int(g.layerStart[Int(g.RANK[v]) + 1])
            let i = s + Int(g.pos[v])
            if i > s && block[Int(g.order[i - 1])] != id
                && xs[v] + shift - xs[Int(g.order[i - 1])] < gap(v) + gap(Int(g.order[i - 1])) - 0.01 {
                return false
            }
            if i + 1 < end && block[Int(g.order[i + 1])] != id
                && xs[Int(g.order[i + 1])] - xs[v] - shift < gap(v) + gap(Int(g.order[i + 1])) - 0.01 {
                return false
            }
        }
        return true
    }
    for k in near {
        let d = off(k)
        if abs(d) < 0.01 {
            join(avec[k], bvec[k])
            continue
        }
        if abs(d) > snapDistance || block[avec[k]] == block[bvec[k]] { continue }
        // The smaller of the two blocks moves, if it can; else the other.
        let upper = block[avec[k]]
        let lower = block[bvec[k]]
        let first = members[upper].count <= members[lower].count ? upper : lower
        let ids = [first, first == upper ? lower : upper]
        for id in ids {
            let shift = id == upper ? d : -d
            if !free(id, shift) { continue }
            for v in members[id] { xs[v] += shift }
            join(avec[k], bvec[k])
            break
        }
    }
}

// Marks the ranks that hold nothing but the bends of edges, if there are any.
private func emptyRanks(_ g: LayeredGraph) -> [UInt8]? {
    let maxRank = g.maxRank
    var empty = [UInt8](repeating: 0, count: maxRank + 1)
    var any = false
    if maxRank >= 2 {
        for r in 1..<maxRank {
            var only = Int(g.layerStart[r + 1]) > Int(g.layerStart[r])
            var i = Int(g.layerStart[r])
            while only && i < Int(g.layerStart[r + 1]) {
                if g.KIND[Int(g.order[i])] != .dummy { only = false }
                i += 1
            }
            if only { empty[r] = 1; any = true }
        }
    }
    return any ? empty : nil
}

// Gives every piece that does not run straight down a track across its gap, and counts the
// tracks of each gap. Two pieces in one gap share a track only where they cannot be mistaken
// for each other: where they do not overlap, or where they leave from or arrive at the same
// point, as the branches of a tree do. Which of two goes above the other is whichever makes
// them cross less. With `curved`, the tracks are levels for curves to turn onto, and only the
// pieces that would run along or too near another get one: each group of those counts its
// tracks from its own first. `room` is the height of the gap under each rank, and `tall`
// receives the height that a gap whose curves mostly cross each other should have instead of levels.
private func assignTracks(_ from: inout [Double], _ to: inout [Double], _ rank: [Int32],
                          _ track: inout [Int32], _ levels: inout [Int32], _ wide: [Int32],
                          trackCount: inout [Int32], curved: Bool, room: [Double], tall: inout [Double]) {
    let total = from.count
    var byRank: [Int: [Int]] = [:]
    for k in 0..<total {
        track.append(-1)
        levels.append(0)
        if abs(from[k] - to[k]) < inLine { continue }
        byRank[Int(rank[k]), default: []].append(k)
    }
    // The pieces are compared pair by pair, so where each begins and ends across the flow is worked out once.
    var LO = [Double](repeating: 0, count: total)
    var HI = [Double](repeating: 0, count: total)
    for k in 0..<total {
        LO[k] = min(from[k], to[k])
        HI[k] = max(from[k], to[k])
    }
    func within(_ x: Double, _ k: Int) -> Double {
        (x >= LO[k] - inLine && x <= HI[k] + inLine) ? 1 : 0
    }
    func mates(_ a: Int, _ b: Int) -> Bool {
        abs(from[a] - from[b]) < inLine || abs(to[a] - to[b]) < inLine
    }
    func overlap(_ a: Int, _ b: Int) -> Bool {
        LO[a] < HI[b] - inLine && LO[b] < HI[a] - inLine
    }
    // Whether a and b need tracks of their own.
    func clash(_ a: Int, _ b: Int) -> Bool { overlap(a, b) && !mates(a, b) }
    // Whether one of a and b could cross the other, depending on which is above.
    func meet(_ a: Int, _ b: Int) -> Bool {
        overlap(a, b) || within(to[a], b) + within(from[b], a) + within(to[b], a) + within(from[a], b) > 0
    }
    // How often a and b cross with a on the higher track: a's way down through b, and b's way down to itself through a.
    func crossings(_ a: Int, _ b: Int) -> Double { within(to[a], b) + within(from[b], a) }

    // Gives the pieces of one gap in `list` their tracks, and each the number of tracks that the
    // pieces it has to do with take between them, counting its own from the first of those.
    // Returns the number of tracks. The pieces come without tracks.
    func lay(_ list: [Int]) -> Int {
        // A plain order to start from, and to keep where nothing says otherwise: the pieces that
        // reach furthest go first, so that those of one fan nest.
        let sorted = list.sorted {
            (HI[$1] - LO[$1]) != (HI[$0] - LO[$0]) ? (HI[$1] - LO[$1]) > (HI[$0] - LO[$0])
                : LO[$0] != LO[$1] ? LO[$0] < LO[$1] : $0 < $1
        }
        let count = list.count
        var above: [[Int]] = Array(repeating: [], count: count)
        var group = list.indices.map { $0 }
        func find(_ i: Int) -> Int {
            var i = i
            while group[i] != i { group[i] = group[group[i]]; i = group[i] }
            return i
        }
        var sequence = sorted
        if count <= maxWeighed {
            // above[j] lists the pieces that should be above list[j]. The order follows as many of
            // these as it can: a piece is placed once all that should be above it are, and when
            // none is free, the one with the fewest still waiting.
            var waiting = [Int](repeating: 0, count: count)
            var after: [[Int]] = Array(repeating: [], count: count)
            for i in 0..<count {
                for j in (i + 1)..<count {
                    let a = sorted[i]
                    let b = sorted[j]
                    if !meet(a, b) { continue }
                    group[find(i)] = find(j)
                    let ab = crossings(a, b)
                    let ba = crossings(b, a)
                    if ab == ba { continue }
                    let first = ab < ba ? i : j
                    let second = ab < ba ? j : i
                    above[second].append(first)
                    after[first].append(second)
                    waiting[second] += 1
                }
            }
            var placed = [Bool](repeating: false, count: count)
            var result: [Int] = []
            for _ in 0..<count {
                var pick = -1
                for i in 0..<count {
                    if placed[i] { continue }
                    if pick < 0 || waiting[i] < waiting[pick] { pick = i }
                    if waiting[i] == 0 { break }
                }
                placed[pick] = true
                result.append(pick)
                for j in after[pick] { waiting[j] -= 1 }
            }
            sequence = result.map { sorted[$0] }
        }
        // Each piece takes the first track below those it should be under that has room for it.
        var place: [Int: Int] = [:]
        for (i, k) in sorted.enumerated() { place[k] = i }
        var rows: [[Int]] = []
        for k in sequence {
            var t = 0
            for i in above[place[k] ?? 0] {
                let tk = Int(track[sorted[i]])
                if tk >= t { t = tk + 1 }
            }
            while true {
                if t >= rows.count { rows.append([]) }
                var isFree = true
                for other in rows[t] where clash(k, other) { isFree = false }
                if isFree {
                    rows[t].append(k)
                    break
                }
                t += 1
            }
            track[k] = Int32(t)
        }
        var first: [Int: Int] = [:]
        var lastOf: [Int: Int] = [:]
        for (i, k) in sorted.enumerated() {
            let root = find(i)
            first[root] = min(first[root] ?? Int.max, Int(track[k]))
            lastOf[root] = max(lastOf[root] ?? Int.min, Int(track[k]))
        }
        for (i, k) in sorted.enumerated() {
            let root = find(i)
            levels[k] = Int32(lastOf[root]! - first[root]! + 1)
            if curved { track[k] -= Int32(first[root]!) }
        }
        return rows.count
    }

    // The least distance between a and b as plain curves across a gap that leaves them `height`
    // to turn in: between points along each and the other drawn as a run of short lines.
    let samples = 16
    func sample(_ k: Int, h: Double, out: inout [Double]) {
        let c = layeredEase(across: to[k] - from[k], along: h)
        for i in 0...samples {
            let t = Double(i) / Double(samples)
            let u = 1 - t
            out[2 * i] = from[k] + (to[k] - from[k]) * t * t * (3 - 2 * t)
            out[2 * i + 1] = h * (3 * c * t * u * u + 3 * (1 - c) * t * t * u + t * t * t)
        }
    }
    var lineA = [Double](repeating: 0, count: 2 * samples + 2)
    var lineB = [Double](repeating: 0, count: 2 * samples + 2)
    func reach(_ points: [Double], _ line: [Double]) -> Double {
        var least = Double.infinity
        for i in 0...samples {
            let px = points[2 * i]
            let py = points[2 * i + 1]
            for j in 0..<samples {
                let dx = line[2 * j + 2] - line[2 * j]
                let dy = line[2 * j + 3] - line[2 * j + 1]
                let denom = dx * dx + dy * dy
                let t = max(0, min(1, ((px - line[2 * j]) * dx + (py - line[2 * j + 1]) * dy) / (denom == 0 ? 1 : denom)))
                let d = hypot(px - line[2 * j] - t * dx, py - line[2 * j + 1] - t * dy)
                if d < least { least = d }
            }
        }
        return least
    }
    func nearest(_ a: Int, _ b: Int, height: Double) -> Double {
        let h = max(height / 2, height - 2 * levelLead)
        sample(a, h: h, out: &lineA)
        sample(b, h: h, out: &lineB)
        return min(reach(lineA, lineB), reach(lineB, lineA))
    }

    for (r, all) in byRank {
        if !curved {
            trackCount[r] = Int32(lay(all))
            continue
        }
        if all.count > maxWeighed { continue }
        // The pieces that turn onto levels: first those that run far across and have another such
        // piece to be told apart from, then any two that would pass too near each other as plain
        // curves.
        let far = all.filter { wide[$0] == 1 }
        _ = lay(far)
        var level = Set(far.filter { levels[$0] > 1 })
        for i in 0..<all.count {
            for j in (i + 1)..<all.count {
                let a = all[i]
                let b = all[j]
                if (level.contains(a) && level.contains(b)) || !clash(a, b) { continue }
                if (from[a] < to[a]) != (from[b] < to[b]) { continue }
                if nearest(a, b, height: room[r]) < (wide[a] == 1 || wide[b] == 1 ? levelClear : levelTouch) {
                    level.insert(a); level.insert(b)
                }
            }
        }
        for k in far { track[k] = -1; levels[k] = 0 }
        if level.isEmpty { continue }
        var crossing = 0
        var alongside = 0
        let turning = Array(level)
        for i in 0..<turning.count {
            for j in (i + 1)..<turning.count {
                let a = turning[i]
                let b = turning[j]
                if !overlap(a, b) { continue }
                if (from[a] < to[a]) != (from[b] < to[b]) { crossing += 1 }
                else if !mates(a, b) { alongside += 1 }
            }
        }
        if crossing > alongside {
            for k in all {
                let cand = (HI[k] - LO[k]) * crossedSlope
                if cand > tall[r] { tall[r] = cand }
            }
            continue
        }
        // With them go the short pieces that could cross one of them, so that each has its place
        // among the levels and crosses none.
        func beside(_ k: Int) -> Bool {
            for j in level where meet(k, j) { return true }
            return false
        }
        let members = all.filter { level.contains($0) || (wide[$0] != 1 && beside($0)) }
        _ = lay(members)
        var most: Int32 = 0
        for k in members where levels[k] > most { most = levels[k] }
        trackCount[r] = most
    }
}

// Moves the bends in ranks that hold only bends onto the straight line between the nearest points
// of their edges that are held in place, and marks the ones that can be left out of the route.
// `firstDummy` and `span` give each edge's run of bends, one in every rank. `sep` is the room
// kept between the bends of twin edges, or 0 to leave those out as well.
private func straighten(_ g: inout LayeredGraph, xs: inout [Double], empty: [UInt8],
                        firstDummy: [Int32], span: [Int32], sep: Double, onLine: inout [UInt8]) {
    let maxRank = g.maxRank
    var want = [Double](repeating: 0, count: xs.count)
    // The points that each bend's edge runs between, across the ranks that hold only bends.
    var fromPts = [Double](repeating: 0, count: xs.count)
    var toPts = [Double](repeating: 0, count: xs.count)
    for ei in 0..<firstDummy.count {
        let d0 = Int(firstDummy[ei])
        if d0 < 0 { continue }
        let end = d0 + Int(span[ei]) - 1
        // A bend's rank is its place in the run, counted from the rank after the edge's first node.
        let base = Int(g.RANK[d0])
        var d = d0
        while d < end {
            if empty[base + d - d0] == 0 { d += 1; continue }
            var last = d
            while last + 1 < end && empty[base + last + 1 - d0] != 0 { last += 1 }
            let above = Int(g.predE[Int(g.predStart[d])])
            let below = Int(g.succE[Int(g.succStart[last])])
            let x0 = xs[Int(g.EF[above])] + g.EFD[above]
            let x1 = xs[Int(g.ET[below])] + g.ETD[below]
            let steps = last - d + 2
            for k in d...last {
                want[k] = x0 + ((x1 - x0) * Double(k - d + 1)) / Double(steps)
                fromPts[k] = x0
                toPts[k] = x1
            }
            d = last + 1
        }
    }

    // Nothing in such a rank is in a bend's way, so each one goes onto its line and out of the
    // route. Only twins stay: bends of edges that run between the same two points, which would
    // otherwise be drawn as one. They take places a little apart, around the line.
    var twins: [Int] = []
    if maxRank >= 2 {
        for r in 1..<maxRank {
            if empty[r] == 0 { continue }
            let s = Int(g.layerStart[r])
            let end = Int(g.layerStart[r + 1])
            let members = (s..<end).map { Int(g.order[$0]) }
            let row = members.sorted { (a: Int, b: Int) -> Bool in
                if fromPts[a] != fromPts[b] { return fromPts[a] < fromPts[b] }
                if toPts[a] != toPts[b] { return toPts[a] < toPts[b] }
                return a < b
            }
            var i = 0
            while i < row.count {
                twins.removeAll(keepingCapacity: true)
                var j = i
                while j < row.count && abs(fromPts[row[j]] - fromPts[row[i]]) < 1
                    && abs(toPts[row[j]] - toPts[row[i]]) < 1 {
                    twins.append(row[j]); j += 1
                }
                // The twins keep the order the rank gave them, so that two edges do not swap sides on the way.
                twins.sort { g.pos[$0] < g.pos[$1] }
                for k in 0..<twins.count {
                    let d = twins[k]
                    xs[d] = want[d] + (Double(k) - Double(twins.count - 1) / 2) * sep
                    if twins.count == 1 || sep == 0 { onLine[d] = 1 }
                }
                i = j
            }
        }
    }
}

// In a rank that holds labels and bends but no nodes, a bend is there to take its edge straight
// through between the labels. Where the edge would pass clear of every label anyway, the bend
// is left out, and the edge turns in the whole height between the ranks on either side.
private func pastLabels(_ g: inout LayeredGraph, xs: inout [Double], firstDummy: [Int32],
                        span: [Int32], clear: Double, onLine: inout [UInt8]) {
    let maxRank = g.maxRank
    var labelled = [UInt8](repeating: 0, count: maxRank + 1)
    var any = false
    if maxRank >= 2 {
        for r in 1..<maxRank {
            var labels = false
            var others = false
            for i in Int(g.layerStart[r])..<Int(g.layerStart[r + 1]) {
                let kind = g.KIND[Int(g.order[i])]
                if kind == .label { labels = true }
                else if kind != .dummy { others = true }
            }
            if labels && !others { labelled[r] = 1; any = true }
        }
    }
    if !any { return }
    for ei in 0..<firstDummy.count {
        let d0 = Int(firstDummy[ei])
        if d0 < 0 { continue }
        let end = d0 + Int(span[ei]) - 1
        for d in d0..<end {
            if g.KIND[d] != .dummy || labelled[Int(g.RANK[d])] == 0 { continue }
            // The points on either side that the edge is held at, past any bends already left out.
            var first = d
            var last = d
            while first > d0 && onLine[first - 1] != 0 { first -= 1 }
            while last + 1 < end && onLine[last + 1] != 0 { last += 1 }
            let above = Int(g.predE[Int(g.predStart[first])])
            let below = Int(g.succE[Int(g.succStart[last])])
            let from = xs[Int(g.EF[above])] + g.EFD[above]
            let to = xs[Int(g.ET[below])] + g.ETD[below]
            let lo = min(from, to) - clear
            let hi = max(from, to) + clear
            var isFree = true
            let r = Int(g.RANK[d])
            var i = Int(g.layerStart[r])
            while isFree && i < Int(g.layerStart[r + 1]) {
                let label = Int(g.order[i])
                if g.KIND[label] == .label && xs[label] + g.W[label] / 2 > lo
                    && xs[label] - g.W[label] / 2 < hi { isFree = false }
                i += 1
            }
            if !isFree { continue }
            onLine[d] = 1
            // The bends left out between the two points lie on the line between them.
            let steps = last - first + 2
            for k in first...last {
                xs[k] = from + ((to - from) * Double(k - first + 1)) / Double(steps)
            }
        }
    }
}

private func reduceCrossings(_ g: inout LayeredGraph, nodes: [LayeredNode]) {
    let n = g.n
    let real = g.real
    let maxRank = g.maxRank
    var widest = 0
    for r in 0...maxRank {
        widest = max(widest, Int(g.layerStart[r + 1]) - Int(g.layerStart[r]))
    }
    // With offsets, edges that reach one node at different offsets take separate places along it.
    let hasPlace = g.offsets
    var place = hasPlace ? [Int32](repeating: 0, count: g.EF.count) : []
    var size = 1
    while size < (hasPlace ? widest + g.EF.count : widest) { size <<= 1 }
    var tree = [Int32](repeating: 0, count: 2 * size)
    var targets = [Int32](repeating: 0, count: g.EF.count)

    func count() -> Int {
        var total = 0
        for r in 0..<maxRank {
            var southLen = Int(g.layerStart[r + 2]) - Int(g.layerStart[r + 1])
            if hasPlace {
                var places = 0
                for i in Int(g.layerStart[r + 1])..<Int(g.layerStart[r + 2]) {
                    let from = Int(g.predStart[Int(g.order[i])])
                    let to = Int(g.predStart[Int(g.order[i]) + 1])
                    var mixed = false
                    for k in (from + 1)..<to {
                        if g.ETD[Int(g.predE[k])] != g.ETD[Int(g.predE[from])] { mixed = true }
                    }
                    if mixed {
                        let ids = (from..<to).map { Int(g.predE[$0]) }.sorted { g.ETD[$0] < g.ETD[$1] }
                        for k in 0..<ids.count {
                            if k > 0 && g.ETD[ids[k]] != g.ETD[ids[k - 1]] { places += 1 }
                            place[ids[k]] = Int32(places)
                        }
                    } else {
                        for k in from..<to { place[Int(g.predE[k])] = Int32(places) }
                    }
                    places += 1
                }
                southLen = places
            }
            if southLen < 2 { continue }
            var t = 0
            for i in Int(g.layerStart[r])..<Int(g.layerStart[r + 1]) {
                let v = Int(g.order[i])
                let from = Int(g.succStart[v])
                let to = Int(g.succStart[v + 1])
                let t0 = t
                for k in from..<to {
                    targets[t] = hasPlace ? place[Int(g.succE[k])] : g.pos[Int(g.ET[Int(g.succE[k])])]
                    t += 1
                }
                let d = t - t0
                if d < 2 { continue }
                var mixed = false
                if hasPlace {
                    for k in (from + 1)..<to {
                        if g.EFD[Int(g.succE[k])] != g.EFD[Int(g.succE[from])] { mixed = true }
                    }
                }
                if hasPlace && mixed {
                    let ids = (from..<to).map { Int(g.succE[$0]) }.sorted {
                        g.EFD[$0] != g.EFD[$1] ? g.EFD[$0] < g.EFD[$1] : place[$0] < place[$1]
                    }
                    for k in 0..<d { targets[t0 + k] = place[ids[k]] }
                } else if d <= 12 {
                    for a in (t0 + 1)..<t {
                        let item = targets[a]
                        var b = a - 1
                        while b >= t0 && targets[b] > item {
                            targets[b + 1] = targets[b]
                            b -= 1
                        }
                        targets[b + 1] = item
                    }
                } else {
                    sortSlice(&targets, t0..<t)
                }
            }
            if t < 2 { continue }
            var leaves = 1
            while leaves < southLen { leaves <<= 1 }
            for i in 0..<(2 * leaves) { tree[i] = 0 }
            for k in 0..<t {
                var i = Int(targets[k]) + leaves
                tree[i] += 1
                while i > 1 {
                    if (i & 1) == 0 { total += Int(tree[i + 1]) }
                    i >>= 1
                    tree[i] += 1
                }
            }
        }
        return total
    }

    var best = count()
    if best == 0 { return }
    let bestOrder = g.order
    var bary = [Double](repeating: 0, count: n)
    var moving = [Int32](repeating: 0, count: max(widest, 1))
    func leftBias(_ a: Int, _ b: Int) -> Bool { bary[a] != bary[b] ? bary[a] < bary[b] : g.pos[a] < g.pos[b] }
    func rightBias(_ a: Int, _ b: Int) -> Bool { bary[a] != bary[b] ? bary[a] < bary[b] : g.pos[a] > g.pos[b] }

    func sweep(down: Bool, biasRight: Bool) {
        let start = down ? g.predStart : g.succStart
        let list = down ? g.predE : g.succE
        let other = down ? g.EF : g.ET
        let otherDx = down ? g.EFD : g.ETD
        var step = 1
        while step <= maxRank {
            let r = down ? step : maxRank - step
            let s = Int(g.layerStart[r])
            let e = Int(g.layerStart[r + 1])
            var movable = 0
            for i in s..<e {
                let v = Int(g.order[i])
                let pin: Int32 = v < real ? nodes[v].pin : 0
                if pin != 0 {
                    bary[v] = Double(pin) * 1e9
                    moving[movable] = Int32(v); movable += 1
                    continue
                }
                let from = Int(start[v])
                let to = Int(start[v + 1])
                if from == to {
                    bary[v] = -1
                    continue
                }
                var sum = 0.0
                for k in from..<to {
                    let u = Int(other[Int(list[k])])
                    sum += Double(g.pos[u])
                    if g.offsets && g.W[u] > 0 { sum += otherDx[Int(list[k])] / g.W[u] }
                }
                bary[v] = sum / Double(to - from)
                moving[movable] = Int32(v); movable += 1
            }
            if movable >= 2 {
                let sorted = (0..<movable).map { Int(moving[$0]) }.sorted(by: biasRight ? rightBias : leftBias)
                var k = 0
                for i in s..<e {
                    if bary[Int(g.order[i])] != -1 {
                        g.order[i] = Int32(sorted[k]); k += 1
                    }
                }
                for i in s..<e { g.pos[Int(g.order[i])] = Int32(i - s) }
            }
            step += 1
        }
    }

    // How many pairs of nodes in one rank are not in the order they were given.
    func outOfOrder() -> Int {
        var total = 0
        for r in 0...maxRank {
            for i in Int(g.layerStart[r])..<Int(g.layerStart[r + 1]) {
                if Int(g.order[i]) >= real { continue }
                for j in (i + 1)..<Int(g.layerStart[r + 1]) {
                    if Int(g.order[j]) < Int(g.order[i]) { total += 1 }
                }
            }
        }
        return total
    }
    func settlePositions() {
        for r in 0...maxRank {
            for i in Int(g.layerStart[r])..<Int(g.layerStart[r + 1]) {
                g.pos[Int(g.order[i])] = Int32(i - Int(g.layerStart[r]))
            }
        }
    }

    // The sweeps are run twice from the same start, going down first and going up first. They
    // often end with as few crossings either way but a different order, and then the one that
    // keeps more of the nodes in the order they were given is the less surprising.
    // Only for graphs small enough to be read node by node: a second run costs as much as the first.
    let initial = g.order
    let start = best
    let small = n <= 600
    var chosen = bestOrder
    var chosenOut = Int.max
    for attempt in 0..<(small ? 2 : 1) {
        if attempt > 0 {
            g.order = initial
            settlePositions()
        }
        var found = start
        var foundOrder = initial
        var i = 0
        var stale = 0
        while stale < 4 && i < maxSweeps {
            sweep(down: (i + attempt) % 2 == 0, biasRight: i % 4 >= 2)
            let c = count()
            if c < found {
                found = c
                foundOrder = g.order
                stale = 0
                if c == 0 { break }
            }
            i += 1
            stale += 1
        }
        g.order = foundOrder
        let out = small ? outOfOrder() : 0
        if attempt == 0 || found < best || (found == best && out < chosenOut) {
            best = found
            chosen = foundOrder
            chosenOut = out
        }
    }
    g.order = chosen
    settlePositions()

    // A drawing and its mirror image cross as often too. Of those two, likewise.
    if !small { return }
    for i in 0..<real {
        if nodes[i].pin != 0 { return }
    }
    if chosenOut == 0 { return }
    for r in 0...maxRank {
        let s = Int(g.layerStart[r])
        let e = Int(g.layerStart[r + 1])
        var lo = s, hi = e - 1
        while lo < hi {
            g.order.swapAt(lo, hi)
            lo += 1; hi -= 1
        }
    }
    settlePositions()
    if count() > best || outOfOrder() >= chosenOut { g.order = chosen }
}

// Half the room a node, bend or port takes across the flow, with its share of the gap beside it.
// A port on a group's border is a point that an edge passes through, and needs no more than a bend.
private func halfRoom(_ g: LayeredGraph, opt: LayeredOptions, v: Int) -> Double {
    g.W[v] / 2 + (g.KIND[v] == .node ? opt.nodeSep : opt.edgeSep) / 2
}

// Brandes-Köpf horizontal coordinate assignment: four aligned layouts, balanced.
private func layeredPosition(_ g: LayeredGraph, opt: LayeredOptions) -> [Double] {
    let n = g.n
    let maxRank = g.maxRank
    let segments = g.EF.count
    var gap = [Double](repeating: 0, count: n)
    for i in 0..<n { gap[i] = halfRoom(g, opt: opt, v: i) }

    // Neighbours in left-to-right order, so the medians can be read off directly.
    var key = [Int32](repeating: 0, count: segments)
    for e in 0..<segments { key[e] = g.pos[Int(g.ET[e])] }
    var succE = g.succE
    for v in 0..<n {
        if Int(g.succStart[v + 1]) - Int(g.succStart[v]) > 1 {
            sortRange(&succE, from: Int(g.succStart[v]), to: Int(g.succStart[v + 1]), key: key)
        }
    }
    for e in 0..<segments { key[e] = g.pos[Int(g.EF[e])] }
    var predE = g.predE
    for v in 0..<n {
        if Int(g.predStart[v + 1]) - Int(g.predStart[v]) > 1 {
            sortRange(&predE, from: Int(g.predStart[v]), to: Int(g.predStart[v + 1]), key: key)
        }
    }

    // An edge between two real nodes may not cross a dummy-to-dummy segment; mark those that would.
    var conflict = [UInt8](repeating: 0, count: segments)
    if maxRank >= 1 {
        for r in 1...maxRank {
            let prevLen = Int(g.layerStart[r]) - Int(g.layerStart[r - 1])
            let s = Int(g.layerStart[r])
            let end = Int(g.layerStart[r + 1])
            var k0 = 0
            var scan = s
            for i in s..<end {
                let v = Int(g.order[i])
                var inner = -1
                if g.KIND[v] == .dummy || g.KIND[v] == .label {
                    let u = Int(g.EF[Int(predE[Int(g.predStart[v])])])
                    if g.KIND[u] == .dummy || g.KIND[u] == .label { inner = u }
                }
                let k1 = inner >= 0 ? Int(g.pos[inner]) : prevLen
                if inner >= 0 || i == end - 1 {
                    for j in scan...i {
                        let w = Int(g.order[j])
                        let wDummy = g.KIND[w] == .dummy || g.KIND[w] == .label
                        for k in Int(g.predStart[w])..<Int(g.predStart[w + 1]) {
                            let e = Int(predE[k])
                            let up = Int(g.pos[Int(g.EF[e])])
                            if (up < k0 || k1 < up) && !(wDummy && (g.KIND[Int(g.EF[e])] == .dummy || g.KIND[Int(g.EF[e])] == .label)) {
                                conflict[e] = 1
                            }
                        }
                    }
                    scan = i + 1
                    k0 = k1
                }
            }
        }
    }

    var results: [[Double]] = []
    var root = [Int](repeating: 0, count: n)
    var align = [Int](repeating: 0, count: n)
    // Offset of each node from its block's root, so that aligned edges meet at their attachment points.
    var shift = [Double](repeating: 0, count: n)
    var eFrom = [Int](repeating: 0, count: n)
    var eTo = [Int](repeating: 0, count: n)
    var eW = [Double](repeating: 0, count: n)
    var indeg = [Int](repeating: 0, count: n)
    var outStart = [Int](repeating: 0, count: n + 1)
    var outE = [Int](repeating: 0, count: n)
    var fill = [Int](repeating: 0, count: n)
    var topo = [Int](repeating: 0, count: n)

    for variant in 0..<4 {
        let up = variant < 2
        let right = (variant & 1) == 1
        let start = up ? g.predStart : g.succStart
        let list = up ? predE : succE
        let other = up ? g.EF : g.ET
        let ownDx = up ? g.ETD : g.EFD
        let otherDx = up ? g.EFD : g.ETD
        for i in 0..<n { root[i] = i; align[i] = i; shift[i] = 0 }

        var step = 0
        while step <= maxRank {
            let r = up ? step : maxRank - step
            let s = Int(g.layerStart[r])
            let end = Int(g.layerStart[r + 1])
            let adjacent = up ? r - 1 : r + 1
            let adjacentLast = (adjacent >= 0 && adjacent <= maxRank)
                ? Int(g.layerStart[adjacent + 1]) - Int(g.layerStart[adjacent]) - 1 : 0
            var prevIdx = -1
            var i = right ? end - 1 : s
            while right ? i >= s : i < end {
                let v = Int(g.order[i])
                let from = Int(start[v])
                let d = Int(start[v + 1]) - from
                if d != 0 {
                    let lo = from + ((d - 1) >> 1)
                    let hi = from + (d >> 1)
                    for pass in 0..<2 {
                        if pass == 1 && lo == hi { break }
                        let e = Int(list[(pass == 0) != right ? lo : hi])
                        let w = Int(other[e])
                        let idx = right ? adjacentLast - Int(g.pos[w]) : Int(g.pos[w])
                        if align[v] == v && prevIdx < idx && conflict[e] == 0 {
                            align[w] = v
                            root[v] = root[w]
                            align[v] = root[v]
                            shift[v] = shift[w] + otherDx[e] - ownDx[e]
                            prevIdx = idx
                        }
                    }
                }
                i += right ? -1 : 1
            }
            step += 1
        }

        var blockEdges = 0
        for i in 0..<n { indeg[i] = 0 }
        for i in 0...n { outStart[i] = 0 }
        for r in 0...maxRank {
            let s = Int(g.layerStart[r])
            let end = Int(g.layerStart[r + 1])
            var i = s + 1
            while i < end {
                let a = right ? Int(g.order[i]) : Int(g.order[i - 1])
                let b = right ? Int(g.order[i - 1]) : Int(g.order[i])
                let sep = gap[a] + gap[b]
                eFrom[blockEdges] = root[a]
                eTo[blockEdges] = root[b]
                eW[blockEdges] = right ? sep - shift[a] + shift[b] : sep + shift[a] - shift[b]
                indeg[root[b]] += 1
                outStart[root[a] + 1] += 1
                blockEdges += 1
                i += 1
            }
        }
        for i in 0..<n { outStart[i + 1] += outStart[i] }
        for i in 0..<n { fill[i] = outStart[i] }
        for e in 0..<blockEdges {
            outE[fill[eFrom[e]]] = e
            fill[eFrom[e]] += 1
        }

        var x = [Double](repeating: 0, count: n)
        var count = 0
        for i in 0..<n {
            if root[i] == i && indeg[i] == 0 { topo[count] = i; count += 1 }
        }
        var q = 0
        while q < count {
            let v = topo[q]; q += 1
            for k in outStart[v]..<outStart[v + 1] {
                let e = outE[k]
                let w = eTo[e]
                if x[v] + eW[e] > x[w] { x[w] = x[v] + eW[e] }
                indeg[w] -= 1
                if indeg[w] == 0 { topo[count] = w; count += 1 }
            }
        }
        q = count - 1
        while q >= 0 {
            let v = topo[q]; q -= 1
            var min = Double.infinity
            for k in outStart[v]..<outStart[v + 1] {
                let e = outE[k]
                let cand = x[eTo[e]] - eW[e]
                if cand < min { min = cand }
            }
            if min != Double.infinity && min > x[v] { x[v] = min }
        }
        var xsn = [Double](repeating: 0, count: n)
        for i in 0..<n { xsn[i] = (right ? -x[root[i]] : x[root[i]]) + shift[i] }
        results.append(xsn)
    }

    var narrowest = 0
    var bestWidth = Double.infinity
    var mins: [Double] = []
    var maxs: [Double] = []
    for k in 0..<4 {
        var lo = Double.infinity
        var hi = -Double.infinity
        let xsn = results[k]
        for i in 0..<n {
            let half = g.W[i] / 2
            if xsn[i] - half < lo { lo = xsn[i] - half }
            if xsn[i] + half > hi { hi = xsn[i] + half }
        }
        mins.append(lo); maxs.append(hi)
        if hi - lo < bestWidth { bestWidth = hi - lo; narrowest = k }
    }
    for k in 0..<4 {
        let delta = (k & 1) == 0 ? mins[narrowest] - mins[k] : maxs[narrowest] - maxs[k]
        if delta != 0 {
            for i in 0..<n { results[k][i] += delta }
        }
    }

    var out = [Double](repeating: 0, count: n)
    for i in 0..<n {
        var a = results[0][i], b = results[1][i], c = results[2][i], d = results[3][i]
        if a > b { swap(&a, &b) }
        if c > d { swap(&c, &d) }
        if a > c { swap(&a, &c) }
        if b > d { swap(&b, &d) }
        if b > c { swap(&b, &c) }
        out[i] = (b + c) / 2
    }
    return out
}
