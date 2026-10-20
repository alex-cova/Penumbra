import Foundation
import CoreGraphics

func layoutExtraParsed(_ parsed: ExtraParsed) -> ExtraScene {
    switch parsed {
    case .pie(let chart): return layoutPie(chart)
    case .gantt(let chart): return layoutGantt(chart)
    case .gitGraph(let chart): return layoutGitGraph(chart)
    case .journey(let chart): return layoutJourney(chart)
    case .mindmap(let chart): return layoutMindmap(chart)
    case .timeline(let chart): return layoutTimeline(chart)
    case .quadrant(let chart): return layoutQuadrant(chart)
    case .sankey(let chart): return layoutSankey(chart)
    case .radar(let chart): return layoutRadar(chart)
    case .treemap(let chart): return layoutTreemap(chart)
    case .venn(let chart): return layoutVenn(chart)
    case .packet(let chart): return layoutPacket(chart)
    case .block(let chart): return layoutBlock(chart)
    case .requirement(let chart): return layoutBoxes(chart.boxes, edges: chart.edges, title: "Requirements")
    case .architecture(let chart): return layoutArchitecture(chart)
    case .c4(let chart): return layoutC4(chart)
    case .kanban(let chart): return layoutKanban(chart)
    case .usecase(let chart): return layoutUseCase(chart)
    case .treeView(let chart): return layoutTreeView(chart)
    case .ishikawa(let chart): return layoutIshikawa(chart)
    case .cynefin(let chart): return layoutCynefin(chart)
    case .wardley(let chart): return layoutWardley(chart)
    case .eventmodeling(let chart): return layoutEventModel(chart)
    case .railroad(let chart): return layoutRailroad(chart)
    case .info(let chart): return layoutInfo(chart)
    }
}

private func titleItems(_ title: String?, width: Double) -> (items: [ExtraItem], top: Double) {
    guard let title, !title.isEmpty else { return ([], 24) }
    return ([
        .text(title, x: width / 2, y: 22, size: 18, fill: .foreground, anchor: .middle, weight: 600)
    ], 48)
}

func layoutPie(_ chart: PieChart) -> ExtraScene {
    let width = 560.0
    let height = 360.0
    var items: [ExtraItem] = []
    let header = titleItems(chart.title, width: width)
    items.append(contentsOf: header.items)
    let total = max(chart.slices.map(\.value).reduce(0, +), 0.0001)
    let cx = 210.0
    let cy = header.top + 140
    let radius = 120.0
    var angle = -Double.pi / 2
    for (index, slice) in chart.slices.enumerated() {
        let sweep = 2 * Double.pi * (slice.value / total)
        items.append(.wedge(
            cx: cx, cy: cy, radius: radius,
            start: angle, end: angle + sweep,
            fill: .series(index), stroke: .background, innerRadius: 0
        ))
        angle += sweep
    }
    var legendY = header.top + 40
    for (index, slice) in chart.slices.enumerated() {
        items.append(.rect(x: 360, y: legendY - 8, width: 14, height: 14, fill: .series(index), stroke: .border, corner: 3, dashed: false))
        let label = chart.showData ? "\(slice.label) (\(Int(slice.value)))" : slice.label
        items.append(.text(label, x: 382, y: legendY, size: 13, fill: .foreground, anchor: .start, weight: 400))
        legendY += 26
    }
    return ExtraScene(width: width, height: max(height, legendY + 24), items: items)
}

func layoutGantt(_ chart: GanttChart) -> ExtraScene {
    let tasks = chart.tasks
    let maxDay = max(tasks.map { $0.startDay + $0.durationDays }.max() ?? 10, 10)
    let minDay = tasks.map(\.startDay).min() ?? 0
    let span = max(maxDay - minDay, 1)
    let rowH = 28.0
    let left = 150.0
    let plotW = 520.0
    let header = titleItems(chart.title, width: left + plotW + 40)
    var items = header.items
    var y = header.top
    var lastSection = ""
    for task in tasks {
        if task.section != lastSection {
            lastSection = task.section
            items.append(.text(task.section, x: 16, y: y + 8, size: 12, fill: .muted, anchor: .start, weight: 600))
            y += 18
        }
        items.append(.text(task.name, x: 16, y: y + rowH / 2, size: 12, fill: .foreground, anchor: .start, weight: 400))
        let x = left + ((task.startDay - minDay) / span) * plotW
        let w = max((task.durationDays / span) * plotW, 8)
        if task.milestone {
            items.append(.ellipse(x: x - 6, y: y + rowH / 2 - 6, width: 12, height: 12, fill: .accent, stroke: .border))
        } else {
            items.append(.rect(x: x, y: y + 6, width: w, height: rowH - 12, fill: .series(ExtraText.seriesIndex(task.section)), stroke: .border, corner: 4, dashed: false))
        }
        y += rowH
    }
    items.append(.line(x1: left, y1: header.top, x2: left, y2: y, stroke: .muted, width: 1, dashed: false))
    return ExtraScene(width: left + plotW + 40, height: y + 24, items: items)
}

/// Accumulates `ExtraItem`s for the git graph while tracking the emitted
/// content's bounding box, so the final scene is sized to fit (rather than
/// guessed from commit/branch counts, which clips long labels).
private final class GitGraphSceneBuilder {
    private(set) var items: [ExtraItem] = []
    private(set) var maxX = 0.0
    private(set) var maxY = 0.0

    private func extend(_ x: Double, _ y: Double) {
        maxX = max(maxX, x)
        maxY = max(maxY, y)
    }

    func line(x1: Double, y1: Double, x2: Double, y2: Double, stroke: ExtraFill, width: Double, dashed: Bool = false) {
        items.append(.line(x1: x1, y1: y1, x2: x2, y2: y2, stroke: stroke, width: width, dashed: dashed))
        extend(max(x1, x2), max(y1, y2))
    }

    func polyline(_ points: [ExtraPoint], fill: ExtraFill = .none, stroke: ExtraFill, width: Double, closed: Bool = false) {
        items.append(.polyline(points: points, fill: fill, stroke: stroke, width: width, closed: closed))
        for point in points { extend(point.x, point.y) }
    }

    func ellipse(x: Double, y: Double, width: Double, height: Double, fill: ExtraFill, stroke: ExtraFill) {
        items.append(.ellipse(x: x, y: y, width: width, height: height, fill: fill, stroke: stroke))
        extend(x + width, y + height)
    }

    func rect(x: Double, y: Double, width: Double, height: Double, fill: ExtraFill, stroke: ExtraFill, corner: Double = 0) {
        items.append(.rect(x: x, y: y, width: width, height: height, fill: fill, stroke: stroke, corner: corner, dashed: false))
        extend(x + width, y + height)
    }

    func text(_ string: String, x: Double, y: Double, size: Double, fill: ExtraFill, anchor: ExtraAnchor, weight: Int = 400) {
        items.append(.text(string, x: x, y: y, size: size, fill: fill, anchor: anchor, weight: weight))
        let measured = ExtraText.width(string, size: size, weight: weight)
        let rightEdge: Double
        switch anchor {
        case .start: rightEdge = x + measured
        case .middle: rightEdge = x + measured / 2
        case .end: rightEdge = x
        }
        extend(rightEdge, y + size)
    }
}

/// Samples a cubic bezier between two lane positions into a polyline, used for
/// fork/merge/cherry-pick connectors that cross lanes (a straight line would
/// visually cut across intervening lanes at a sharp angle).
private func gitGraphCurve(from: ExtraPoint, to: ExtraPoint, vertical: Bool, samples: Int = 16) -> [ExtraPoint] {
    let c1: ExtraPoint
    let c2: ExtraPoint
    if vertical {
        let midY = (from.y + to.y) / 2
        c1 = ExtraPoint(x: from.x, y: midY)
        c2 = ExtraPoint(x: to.x, y: midY)
    } else {
        let midX = (from.x + to.x) / 2
        c1 = ExtraPoint(x: midX, y: from.y)
        c2 = ExtraPoint(x: midX, y: to.y)
    }
    var points: [ExtraPoint] = []
    points.reserveCapacity(samples + 1)
    for i in 0...samples {
        let t = Double(i) / Double(samples)
        let mt = 1 - t
        let x = mt * mt * mt * from.x + 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t * t * t * to.x
        let y = mt * mt * mt * from.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * to.y
        points.append(ExtraPoint(x: x, y: y))
    }
    return points
}

func layoutGitGraph(_ chart: GitGraphChart) -> ExtraScene {
    let vertical = chart.direction == "TB" || chart.direction == "BT"
    let reversed = chart.direction == "BT"
    let nodeRadius = 9.0
    let step = 60.0
    let laneSpan = 56.0
    let pad = 24.0

    // Explicit `branch X order: N` wins; otherwise branches keep declaration order.
    // On a tie (an explicit order collides with another branch's declaration-index
    // fallback), the explicit one sorts first — that's the whole point of asking.
    let laneAssignment = chart.branches.enumerated().sorted { lhs, rhs in
        let lhsRank = (lhs.element.order ?? lhs.offset, lhs.element.order == nil ? 1 : 0)
        let rhsRank = (rhs.element.order ?? rhs.offset, rhs.element.order == nil ? 1 : 0)
        return lhsRank < rhsRank
    }
    var laneOf: [String: Int] = [:]
    for (lane, entry) in laneAssignment.enumerated() {
        laneOf[entry.element.name] = lane
    }
    let commitByID = Dictionary(chart.commits.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    let maxOrder = chart.commits.map(\.order).max() ?? 0

    func chipWidth(_ name: String) -> Double {
        ExtraText.width(name, size: 11, weight: 600) + 16
    }
    let leadingLR = pad + (chart.branches.map { chipWidth($0.name) }.max() ?? 40) + 16
    let topTB = pad + 28

    func point(order: Int, lane: Int) -> ExtraPoint {
        if vertical {
            let x = pad + Double(lane) * laneSpan + laneSpan / 2
            let effectiveOrder = reversed ? (maxOrder - order) : order
            let y = topTB + Double(effectiveOrder) * step
            return ExtraPoint(x: x, y: y)
        } else {
            let x = leadingLR + Double(order) * step
            let y = pad + Double(lane) * laneSpan + laneSpan / 2
            return ExtraPoint(x: x, y: y)
        }
    }
    func commitPoint(_ commit: GitCommit) -> ExtraPoint {
        point(order: commit.order, lane: laneOf[commit.branch] ?? 0)
    }

    let scene = GitGraphSceneBuilder()

    // Connectors first so nodes paint on top of them. Each commit draws an
    // edge to each of its real parents: same-branch consecutive commits get a
    // straight lane line, a branch's first commit gets a curved fork edge back
    // to the commit it forked from, and a merge commit's second parent gets a
    // curved merge edge from the merged branch's tip.
    for commit in chart.commits {
        let to = commitPoint(commit)
        let lane = laneOf[commit.branch] ?? 0
        for (index, parentID) in commit.parents.enumerated() {
            guard let parent = commitByID[parentID] else { continue }
            let from = commitPoint(parent)
            if parent.branch == commit.branch {
                scene.line(x1: from.x, y1: from.y, x2: to.x, y2: to.y, stroke: .series(lane), width: 2)
            } else {
                let strokeLane = index == 0 ? lane : (laneOf[parent.branch] ?? lane)
                scene.polyline(gitGraphCurve(from: from, to: to, vertical: vertical), stroke: .series(strokeLane), width: 2)
            }
        }
        if commit.kind == .cherryPick, let sourceID = commit.cherryPickSource, let source = commitByID[sourceID] {
            let from = commitPoint(source)
            scene.line(x1: from.x, y1: from.y, x2: to.x, y2: to.y, stroke: .series(lane), width: 1.5, dashed: true)
        }
    }

    // Nodes, labels, and tag banners.
    for commit in chart.commits {
        let p = commitPoint(commit)
        let lane = laneOf[commit.branch] ?? 0
        switch commit.kind {
        case .normal, .cherryPick:
            scene.ellipse(x: p.x - nodeRadius, y: p.y - nodeRadius, width: nodeRadius * 2, height: nodeRadius * 2, fill: .series(lane), stroke: .background)
        case .merge:
            scene.ellipse(x: p.x - nodeRadius, y: p.y - nodeRadius, width: nodeRadius * 2, height: nodeRadius * 2, fill: .series(lane), stroke: .background)
            let inner = nodeRadius * 0.45
            scene.ellipse(x: p.x - inner, y: p.y - inner, width: inner * 2, height: inner * 2, fill: .background, stroke: .none)
        case .reverse:
            scene.ellipse(x: p.x - nodeRadius, y: p.y - nodeRadius, width: nodeRadius * 2, height: nodeRadius * 2, fill: .series(lane), stroke: .background)
            let r = nodeRadius * 0.55
            scene.line(x1: p.x - r, y1: p.y - r, x2: p.x + r, y2: p.y + r, stroke: .background, width: 1.5)
            scene.line(x1: p.x - r, y1: p.y + r, x2: p.x + r, y2: p.y - r, stroke: .background, width: 1.5)
        case .highlight:
            let side = nodeRadius * 1.6
            scene.rect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side, fill: .series(lane), stroke: .foreground, corner: 3)
        }

        if let label = commit.label {
            if vertical {
                scene.text(label, x: p.x + nodeRadius + 8, y: p.y + 4, size: 11, fill: .foreground, anchor: .start)
            } else {
                scene.text(label, x: p.x, y: p.y + nodeRadius + 16, size: 10, fill: .muted, anchor: .middle)
            }
        }

        if let tag = commit.tag {
            let tagWidth = ExtraText.width(tag, size: 10, weight: 600) + 14
            let bannerHeight = 20.0
            let notch = 6.0
            let bx = vertical ? p.x + nodeRadius + 8 : p.x - tagWidth / 2
            let by = vertical ? p.y - bannerHeight - 6 : p.y - nodeRadius - bannerHeight - 8
            let banner = [
                ExtraPoint(x: bx, y: by + bannerHeight / 2),
                ExtraPoint(x: bx + notch, y: by),
                ExtraPoint(x: bx + notch + tagWidth, y: by),
                ExtraPoint(x: bx + notch + tagWidth, y: by + bannerHeight),
                ExtraPoint(x: bx + notch, y: by + bannerHeight)
            ]
            scene.polyline(banner, fill: .surface, stroke: .border, width: 1, closed: true)
            scene.text(tag, x: bx + notch + tagWidth / 2, y: by + bannerHeight / 2 + 3, size: 10, fill: .foreground, anchor: .middle, weight: 600)
        }
    }

    // Branch chips: a small pill with the branch name, in its own lane color.
    for branch in chart.branches {
        let lane = laneOf[branch.name] ?? 0
        let width = chipWidth(branch.name)
        let height = 20.0
        if vertical {
            let x = pad + Double(lane) * laneSpan + laneSpan / 2
            scene.rect(x: x - width / 2, y: pad, width: width, height: height, fill: .series(lane), stroke: .none, corner: 4)
            scene.text(branch.name, x: x, y: pad + height / 2 + 3, size: 11, fill: .background, anchor: .middle, weight: 600)
        } else {
            let y = pad + Double(lane) * laneSpan + laneSpan / 2
            scene.rect(x: 8, y: y - height / 2, width: width, height: height, fill: .series(lane), stroke: .none, corner: 4)
            scene.text(branch.name, x: 8 + width / 2, y: y + 3, size: 11, fill: .background, anchor: .middle, weight: 600)
        }
    }

    return ExtraScene(width: max(scene.maxX + pad, 120), height: max(scene.maxY + pad, 80), items: scene.items)
}

func layoutJourney(_ chart: JourneyChart) -> ExtraScene {
    var sections: [String] = []
    for task in chart.tasks where !sections.contains(task.section) {
        sections.append(task.section)
    }
    let colW = 140.0
    let header = titleItems(chart.title, width: max(Double(sections.count) * colW + 80, 320))
    var items = header.items
    let plotTop = header.top + 20
    let plotH = 180.0
    for (i, section) in sections.enumerated() {
        let x = 40 + Double(i) * colW
        items.append(.text(section, x: x + colW / 2, y: header.top, size: 12, fill: .muted, anchor: .middle, weight: 600))
        let tasks = chart.tasks.filter { $0.section == section }
        for (j, task) in tasks.enumerated() {
            let y = plotTop + plotH - Double(task.score) / 5.0 * plotH
            items.append(.ellipse(x: x + 20 + Double(j) * 18, y: y - 6, width: 12, height: 12, fill: .series(i), stroke: .border))
            items.append(.text(task.name, x: x + colW / 2, y: plotTop + plotH + 16 + Double(j) * 14, size: 10, fill: .foreground, anchor: .middle, weight: 400))
        }
    }
    items.append(.line(x1: 30, y1: plotTop, x2: 30, y2: plotTop + plotH, stroke: .muted, width: 1, dashed: false))
    items.append(.line(x1: 30, y1: plotTop + plotH, x2: 40 + Double(max(sections.count, 1)) * colW, y2: plotTop + plotH, stroke: .muted, width: 1, dashed: false))
    let height = plotTop + plotH + 80
    return ExtraScene(width: 40 + Double(max(sections.count, 1)) * colW + 20, height: height, items: items)
}

private struct MindmapNodeSize {
    var width: Double
    var height: Double
}

private final class MindmapSceneBuilder {
    private(set) var items: [ExtraItem] = []
    private(set) var maxX = 0.0
    private(set) var maxY = 0.0

    private func extend(_ x: Double, _ y: Double) {
        maxX = max(maxX, x)
        maxY = max(maxY, y)
    }

    func polyline(
        _ points: [ExtraPoint],
        fill: ExtraFill = .none,
        stroke: ExtraFill,
        width: Double,
        closed: Bool = false
    ) {
        items.append(.polyline(points: points, fill: fill, stroke: stroke, width: width, closed: closed))
        for point in points { extend(point.x, point.y) }
    }

    func ellipse(x: Double, y: Double, width: Double, height: Double, fill: ExtraFill, stroke: ExtraFill) {
        items.append(.ellipse(x: x, y: y, width: width, height: height, fill: fill, stroke: stroke))
        extend(x + width, y + height)
    }

    func rect(x: Double, y: Double, width: Double, height: Double, fill: ExtraFill, stroke: ExtraFill, corner: Double = 0) {
        items.append(.rect(x: x, y: y, width: width, height: height, fill: fill, stroke: stroke, corner: corner, dashed: false))
        extend(x + width, y + height)
    }

    func text(_ string: String, x: Double, y: Double, size: Double, fill: ExtraFill, anchor: ExtraAnchor, weight: Int = 400) {
        items.append(.text(string, x: x, y: y, size: size, fill: fill, anchor: anchor, weight: weight))
        let measured = ExtraText.width(string, size: size, weight: weight)
        let rightEdge: Double
        switch anchor {
        case .start: rightEdge = x + measured
        case .middle: rightEdge = x + measured / 2
        case .end: rightEdge = x
        }
        extend(rightEdge, y + size)
    }
}

private func mindmapNodeSize(_ node: MindmapNode) -> MindmapNodeSize {
    let weight = node.depth == 0 ? 600 : 400
    let width = min(max(ExtraText.width(node.text, size: 12, weight: weight) + 24, 56), 240)
    let height = node.depth == 0 ? 32.0 : 28.0
    return MindmapNodeSize(width: width, height: height)
}

private func mindmapIndex(chart: MindmapChart) -> (
    byParent: [Int: [MindmapNode]],
    nodeByID: [Int: MindmapNode],
    sizes: [Int: MindmapNodeSize]
) {
    let byParent = Dictionary(grouping: chart.nodes.filter { $0.parent != nil }, by: { $0.parent! })
    let nodeByID = Dictionary(chart.nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    let sizes = Dictionary(chart.nodes.map { ($0.id, mindmapNodeSize($0)) }, uniquingKeysWith: { _, last in last })
    return (byParent, nodeByID, sizes)
}

private func appendMindmapNode(
    _ node: MindmapNode,
    center: ExtraPoint,
    size: MindmapNodeSize,
    to scene: MindmapSceneBuilder
) {
    let x = center.x - size.width / 2
    let y = center.y - size.height / 2
    let fill: ExtraFill = node.depth == 0 ? .accent : .series(node.depth - 1)
    let textFill: ExtraFill = .contrast(on: fill)
    let weight = node.depth == 0 ? 600 : 400

    switch node.shape {
    case .circle, .stadium:
        scene.ellipse(x: x, y: y, width: size.width, height: size.height, fill: fill, stroke: .border)
    case .rect:
        scene.rect(x: x, y: y, width: size.width, height: size.height, fill: fill, stroke: .border, corner: 0)
    case .roundedRect:
        scene.rect(x: x, y: y, width: size.width, height: size.height, fill: fill, stroke: .border, corner: 8)
    case .diamond:
        let cx = center.x
        let cy = center.y
        let hw = size.width / 2
        let hh = size.height / 2
        scene.polyline(
            [
                ExtraPoint(x: cx, y: cy - hh),
                ExtraPoint(x: cx + hw, y: cy),
                ExtraPoint(x: cx, y: cy + hh),
                ExtraPoint(x: cx - hw, y: cy),
            ],
            fill: fill,
            stroke: .border,
            width: 1,
            closed: true
        )
    case .hexagon:
        let cx = center.x
        let cy = center.y
        let radius = min(size.width, size.height) / 2
        let points = (0..<6).map { index in
            let angle = Double.pi / 3 * Double(index) - Double.pi / 2
            return ExtraPoint(x: cx + cos(angle) * radius, y: cy + sin(angle) * radius)
        }
        scene.polyline(points, fill: fill, stroke: .border, width: 1, closed: true)
    }

    scene.text(node.text, x: center.x, y: center.y, size: 12, fill: textFill, anchor: .middle, weight: weight)
}

private func mindmapConnectorPoints(
    parentCenter: ExtraPoint,
    childCenter: ExtraPoint,
    parentSize: MindmapNodeSize,
    childSize: MindmapNodeSize,
    horizontal: Bool
) -> [ExtraPoint] {
    if horizontal {
        let parentRight = ExtraPoint(x: parentCenter.x + parentSize.width / 2, y: parentCenter.y)
        let childLeft = ExtraPoint(x: childCenter.x - childSize.width / 2, y: childCenter.y)
        let midX = (parentRight.x + childLeft.x) / 2
        return [
            parentRight,
            ExtraPoint(x: midX, y: parentRight.y),
            ExtraPoint(x: midX, y: childLeft.y),
            childLeft,
        ]
    }
    return mindmapRadialConnector(from: parentCenter, to: childCenter)
}

private func mindmapRadialConnector(from: ExtraPoint, to: ExtraPoint, samples: Int = 14) -> [ExtraPoint] {
    let midX = (from.x + to.x) / 2
    let midY = (from.y + to.y) / 2
    let dx = midX - from.x
    let dy = midY - from.y
    let length = max(sqrt(dx * dx + dy * dy), 1)
    let bulge = 18.0
    let control = ExtraPoint(x: midX + dx / length * bulge, y: midY + dy / length * bulge)
    var points: [ExtraPoint] = []
    for index in 0...samples {
        let t = Double(index) / Double(samples)
        let u = 1 - t
        let x = u * u * from.x + 2 * u * t * control.x + t * t * to.x
        let y = u * u * from.y + 2 * u * t * control.y + t * t * to.y
        points.append(ExtraPoint(x: x, y: y))
    }
    return points
}

func layoutMindmap(_ chart: MindmapChart) -> ExtraScene {
    switch chart.layout {
    case .treeLR:
        return layoutMindmapTreeLR(chart)
    case .radial:
        return layoutMindmapRadial(chart)
    }
}

private func layoutMindmapTreeLR(_ chart: MindmapChart) -> ExtraScene {
    let (byParent, nodeByID, sizes) = mindmapIndex(chart: chart)
    let pad = 40.0
    let columnGap = 40.0
    let siblingGap = 12.0

    var maxWidthAtDepth: [Int: Double] = [:]
    for node in chart.nodes {
        let size = sizes[node.id]!
        maxWidthAtDepth[node.depth] = max(maxWidthAtDepth[node.depth] ?? 0, size.width)
    }

    func columnX(_ depth: Int) -> Double {
        var x = pad
        for depthIndex in 0..<depth {
            x += (maxWidthAtDepth[depthIndex] ?? 80) + columnGap
        }
        return x
    }

    var positions: [Int: ExtraPoint] = [:]
    var nextLeafY = pad

    func place(_ id: Int) -> ExtraPoint {
        if let existing = positions[id] { return existing }
        let node = nodeByID[id]!
        let children = byParent[id] ?? []
        let size = sizes[id]!
        let x = columnX(node.depth) + size.width / 2

        let y: Double
        if children.isEmpty {
            y = nextLeafY + size.height / 2
            nextLeafY += size.height + siblingGap
        } else {
            let childPoints = children.map { place($0.id) }
            y = (childPoints.map(\.y).min()! + childPoints.map(\.y).max()!) / 2
        }

        let point = ExtraPoint(x: x, y: y)
        positions[id] = point
        return point
    }

    for root in chart.nodes where root.parent == nil {
        _ = place(root.id)
    }

    let scene = MindmapSceneBuilder()
    for node in chart.nodes {
        guard let parentID = node.parent,
              let parentCenter = positions[parentID],
              let childCenter = positions[node.id] else {
            continue
        }
        let points = mindmapConnectorPoints(
            parentCenter: parentCenter,
            childCenter: childCenter,
            parentSize: sizes[parentID]!,
            childSize: sizes[node.id]!,
            horizontal: true
        )
        scene.polyline(points, stroke: .muted, width: 1.5)
    }

    for node in chart.nodes {
        guard let center = positions[node.id] else { continue }
        appendMindmapNode(node, center: center, size: sizes[node.id]!, to: scene)
    }

    return ExtraScene(
        width: max(scene.maxX + pad, 120),
        height: max(scene.maxY + pad, 120),
        items: scene.items
    )
}

private func layoutMindmapRadial(_ chart: MindmapChart) -> ExtraScene {
    let (byParent, nodeByID, sizes) = mindmapIndex(chart: chart)
    guard let root = chart.nodes.first(where: { $0.parent == nil }) else {
        return ExtraScene(width: 120, height: 120, items: [])
    }

    let pad = 40.0
    let ringGap = 100.0
    let centerX = 280.0
    let centerY = 280.0
    var positions: [Int: ExtraPoint] = [:]

    func leafCount(_ id: Int) -> Int {
        let children = byParent[id] ?? []
        if children.isEmpty { return 1 }
        return children.map { leafCount($0.id) }.reduce(0, +)
    }

    func assignAngles(_ id: Int, startAngle: Double, endAngle: Double) {
        let node = nodeByID[id]!
        let children = byParent[id] ?? []
        let midAngle = (startAngle + endAngle) / 2

        if node.depth == 0 {
            positions[id] = ExtraPoint(x: centerX, y: centerY)
        } else {
            let radius = Double(node.depth) * ringGap
            positions[id] = ExtraPoint(
                x: centerX + cos(midAngle) * radius,
                y: centerY + sin(midAngle) * radius
            )
        }

        guard !children.isEmpty else { return }
        let totalLeaves = children.map { leafCount($0.id) }.reduce(0, +)
        var angle = startAngle
        for child in children {
            let childLeaves = leafCount(child.id)
            let sweep = (endAngle - startAngle) * Double(childLeaves) / Double(totalLeaves)
            assignAngles(child.id, startAngle: angle, endAngle: angle + sweep)
            angle += sweep
        }
    }

    assignAngles(root.id, startAngle: 0, endAngle: 2 * Double.pi)

    let scene = MindmapSceneBuilder()
    for node in chart.nodes {
        guard let parentID = node.parent,
              let parentCenter = positions[parentID],
              let childCenter = positions[node.id] else {
            continue
        }
        let points = mindmapConnectorPoints(
            parentCenter: parentCenter,
            childCenter: childCenter,
            parentSize: sizes[parentID]!,
            childSize: sizes[node.id]!,
            horizontal: false
        )
        scene.polyline(points, stroke: .muted, width: 1.5)
    }

    for node in chart.nodes {
        guard let center = positions[node.id] else { continue }
        appendMindmapNode(node, center: center, size: sizes[node.id]!, to: scene)
    }

    return ExtraScene(
        width: max(scene.maxX + pad, 360),
        height: max(scene.maxY + pad, 360),
        items: scene.items
    )
}

/// Lays out `treeView-beta` as file-tree rows: bold directories with the
/// trailing `/` stripped, file/folder glyphs, guide rails with elbows,
/// `:::highlight` washes and muted `##` descriptions. Port of Pele's
/// `src/diagrams/treeview/render.ts` (non-tight); custom icon packs and
/// filename/extension maps fall back to the generic glyphs.
func layoutTreeView(_ chart: TreeViewChart) -> ExtraScene {
    let size = 16.0
    let paddingX = 5.0
    let rowIndent = 15.0
    let lineThickness = 1.0
    let pad = 24.0
    let rowH = 28.0
    let iconSize = 16.0
    let iconGap = 6.0
    let descGap = 16.0
    let guideInset = 7.0
    let elbow = 4.0
    let step = rowIndent + paddingX

    struct Row {
        var node: TreeViewNode
        var x: Double
        var cy: Double
        var top: Double
        var height: Double
        var labelX: Double
        var glyph: Bool
        var highlighted: Bool
    }

    func showsIcon(_ node: TreeViewNode) -> Bool {
        if let icon = node.icon, !icon.isEmpty, icon != "none" { return true }
        return chart.showIcons
    }

    func hasIcon(_ list: [TreeViewNode]) -> Bool {
        list.contains(where: showsIcon)
    }

    // Depth-first rows; siblings share an icon slot so names line up.
    var rows: [Row] = []
    var pending: [(node: TreeViewNode, depth: Int, slot: Bool)] = []
    func push(_ list: [TreeViewNode], _ depth: Int) {
        let slot = hasIcon(list)
        for node in list.reversed() {
            pending.append((node, depth, slot))
        }
    }
    push(chart.nodes, 0)
    var rowsHeight = 0.0
    var labelRight = 0.0
    var anyHighlight = false
    while !pending.isEmpty {
        let (node, depth, slot) = pending.removeLast()
        let x = Double(depth) * step
        let labelX = x + (slot ? iconSize + iconGap : 0)
        let width = ExtraText.width(
            node.name, size: size, weight: node.isDirectory ? 600 : 400)
        labelRight = max(labelRight, labelX + width)
        let highlighted = (node.cssClass ?? "").split(whereSeparator: { $0.isWhitespace })
            .contains("highlight")
        anyHighlight = anyHighlight || highlighted
        let cy = rowsHeight + rowH / 2
        rows.append(Row(
            node: node, x: x, cy: cy, top: rowsHeight, height: rowH,
            labelX: labelX, glyph: slot && showsIcon(node), highlighted: highlighted))
        rowsHeight += rowH
        push(node.children, depth + 1)
    }

    var descW = 0.0
    for row in rows {
        if let desc = row.node.description, !desc.isEmpty {
            descW = max(descW, ExtraText.width(desc, size: size))
        }
    }
    let descX = labelRight + descGap
    let inset = pad + (anyHighlight ? 4 : 0)
    // Title width first, like the other layouts.
    var contentW = labelRight
    if descW > 0 { contentW = max(contentW, descX + descW) }
    if let title = chart.title, !title.isEmpty {
        contentW = max(contentW, ExtraText.width(title, size: 18, weight: 600))
    }
    let sceneWidth = max(contentW + 2 * inset, 120)
    let header = titleItems(chart.title, width: sceneWidth)
    let top = header.top
    var items = header.items

    // Guide rails: one vertical per parent with elbows into each child.
    // A node's child rows follow it depth-first, so they run until a row
    // returns to its depth or shallower.
    var guides: [ExtraItem] = []
    for (i, row) in rows.enumerated() where !row.node.children.isEmpty {
        let gx = inset + row.x + guideInset
        let tick = max(gx, inset + row.x + step - paddingX)
        let parentDepth = Int((row.x / step).rounded())
        var kids: [Row] = []
        var j = i + 1
        while j < rows.count {
            let d = Int((rows[j].x / step).rounded())
            if d <= parentDepth { break }
            if d == parentDepth + 1 { kids.append(rows[j]) }
            j += 1
        }
        guard let last = kids.last else { continue }
        let r = min(elbow, tick - gx)
        guides.append(.line(
            x1: gx, y1: top + row.top + row.height - 2, x2: gx, y2: top + last.cy - r,
            stroke: .muted, width: lineThickness, dashed: false))
        if r > 0 {
            let ey = top + last.cy
            var pts = [ExtraPoint(x: gx, y: ey - r)]
            for s in 1...4 {
                let t = Double(s) / 4
                let u = 1 - t
                let px = (u * u + 2 * u * t) * gx + t * t * (gx + r)
                let py = u * u * (ey - r) + (2 * u * t + t * t) * ey
                pts.append(ExtraPoint(x: px, y: py))
            }
            pts.append(ExtraPoint(x: tick, y: ey))
            guides.append(.polyline(
                points: pts, fill: .none, stroke: .muted, width: lineThickness, closed: false))
        } else {
            guides.append(.line(
                x1: gx, y1: top + last.cy, x2: tick, y2: top + last.cy,
                stroke: .muted, width: lineThickness, dashed: false))
        }
        for kid in kids.dropLast() where tick > gx {
            guides.append(.line(
                x1: gx, y1: top + kid.cy, x2: tick, y2: top + kid.cy,
                stroke: .muted, width: lineThickness, dashed: false))
        }
    }
    items.append(contentsOf: guides)

    for row in rows {
        let node = row.node
        let cy = top + row.cy
        if row.highlighted {
            let hx = inset + row.x - 4
            items.append(.rect(
                x: hx, y: top + row.top + 1,
                width: sceneWidth - inset + 4 - hx,
                height: row.height - 2,
                fill: .translucent(.accent), stroke: .none, corner: 4, dashed: false))
        }
        if row.glyph {
            let ix = inset + row.x
            let iy = cy - iconSize / 2
            if node.isDirectory {
                items.append(.rect(
                    x: ix, y: iy + 4, width: iconSize, height: 10,
                    fill: .none, stroke: .muted, corner: 2, dashed: false))
                items.append(.polyline(
                    points: [ExtraPoint(x: ix, y: iy + 4), ExtraPoint(x: ix, y: iy + 1),
                             ExtraPoint(x: ix + 6, y: iy + 1), ExtraPoint(x: ix + 8, y: iy + 4)],
                    fill: .none, stroke: .muted, width: 1.5, closed: false))
            } else {
                items.append(.polyline(
                    points: [ExtraPoint(x: ix + 2, y: iy), ExtraPoint(x: ix + 10, y: iy),
                             ExtraPoint(x: ix + 14, y: iy + 4), ExtraPoint(x: ix + 14, y: iy + 16),
                             ExtraPoint(x: ix + 2, y: iy + 16), ExtraPoint(x: ix + 2, y: iy)],
                    fill: .none, stroke: .muted, width: 1.5, closed: true))
                items.append(.polyline(
                    points: [ExtraPoint(x: ix + 10, y: iy), ExtraPoint(x: ix + 10, y: iy + 4),
                             ExtraPoint(x: ix + 14, y: iy + 4)],
                    fill: .none, stroke: .muted, width: 1.5, closed: false))
            }
        }
        items.append(.text(
            node.name, x: inset + row.labelX, y: cy + size * 0.35, size: size,
            fill: .foreground, anchor: .start,
            weight: node.isDirectory ? 600 : 400))
        if let desc = node.description, !desc.isEmpty {
            items.append(.text(
                desc, x: inset + descX, y: cy + size * 0.35, size: size,
                fill: .muted, anchor: .start, weight: 400))
        }
    }
    return ExtraScene(
        width: sceneWidth, height: top + rowsHeight + pad, items: items)
}

func layoutTimeline(_ chart: TimelineChart) -> ExtraScene {
    let colW = 160.0
    let header = titleItems(chart.title, width: max(Double(chart.entries.count) * colW + 40, 280))
    var items = header.items
    let y = header.top + 40
    items.append(.line(x1: 30, y1: y, x2: 30 + Double(max(chart.entries.count, 1)) * colW, y2: y, stroke: .accent, width: 3, dashed: false))
    var maxH = y + 40
    for (i, entry) in chart.entries.enumerated() {
        let x = 30 + Double(i) * colW + colW / 2
        items.append(.ellipse(x: x - 7, y: y - 7, width: 14, height: 14, fill: .accent, stroke: .background))
        items.append(.text(entry.period, x: x, y: y + 22, size: 12, fill: .foreground, anchor: .middle, weight: 600))
        for (j, event) in entry.events.enumerated() {
            let ey = y + 44 + Double(j) * 18
            items.append(.text(event, x: x, y: ey, size: 11, fill: .muted, anchor: .middle, weight: 400))
            maxH = max(maxH, ey)
        }
    }
    return ExtraScene(width: 60 + Double(max(chart.entries.count, 1)) * colW, height: maxH + 24, items: items)
}

func layoutQuadrant(_ chart: QuadrantChart) -> ExtraScene {
    let width = 480.0
    let height = 420.0
    let header = titleItems(chart.title, width: width)
    var items = header.items
    let plot = CGRect(x: 70, y: header.top, width: 340, height: 300)
    items.append(.rect(x: plot.minX, y: plot.minY, width: plot.width, height: plot.height, fill: .surface, stroke: .border, corner: 0, dashed: false))
    items.append(.line(x1: plot.midX, y1: plot.minY, x2: plot.midX, y2: plot.maxY, stroke: .muted, width: 1, dashed: true))
    items.append(.line(x1: plot.minX, y1: plot.midY, x2: plot.maxX, y2: plot.midY, stroke: .muted, width: 1, dashed: true))
    items.append(.text(chart.xLeft, x: plot.minX, y: plot.maxY + 18, size: 11, fill: .muted, anchor: .start, weight: 400))
    items.append(.text(chart.xRight, x: plot.maxX, y: plot.maxY + 18, size: 11, fill: .muted, anchor: .end, weight: 400))
    items.append(.text(chart.yBottom, x: 16, y: plot.maxY, size: 11, fill: .muted, anchor: .start, weight: 400))
    items.append(.text(chart.yTop, x: 16, y: plot.minY, size: 11, fill: .muted, anchor: .start, weight: 400))
    for (i, point) in chart.points.enumerated() {
        let x = plot.minX + min(max(point.x, 0), 1) * plot.width
        let y = plot.maxY - min(max(point.y, 0), 1) * plot.height
        items.append(.ellipse(x: x - 5, y: y - 5, width: 10, height: 10, fill: .series(i), stroke: .border))
        items.append(.text(point.label, x: x + 8, y: y, size: 10, fill: .foreground, anchor: .start, weight: 400))
    }
    return ExtraScene(width: width, height: height, items: items)
}

/// Pele `rounded` for sankey values: whole ids print without a decimals tail
/// (`35`), fractions round to two places like Mermaid (`342.165` → `342.17`).
func sankeyRounded(_ value: Double) -> String {
    guard value.isFinite else { return String(value) }
    let r = abs(value) < 1e15 ? (value * 100).rounded() / 100 : value
    if r == r.rounded(), abs(r) < Double(Int64.max) { return String(Int64(r)) }
    return String(r)
}

/// Lays out `sankey` as a d3-style flow diagram. Port of Pele's
/// `src/diagrams/sankey/layout.ts` (topological depth layers, nodes sized by
/// `max(in, out)`, stacked bands, crossing-reduction passes) with two
/// lenient differences: circular links take their own trailing layers instead
/// of erroring, and bands draw as closed bezier polylines (Luna has no curve
/// items) in the source node's series color.
func layoutSankey(_ chart: SankeyChart) -> ExtraScene {
    let plotH = 400.0
    let nodeW = 16.0
    let colGap = 200.0
    let pad = 28.0
    let labelSize = 11.0
    let labelGap = 6.0
    let nodePadding = 12.0

    // Ordered nodes in first-mention order (Pele `findOrCreateNode`).
    var indexOf: [String: Int] = [:]
    var ids: [String] = []
    func nodeIndex(_ id: String) -> Int {
        if let i = indexOf[id] { return i }
        indexOf[id] = ids.count
        ids.append(id)
        return ids.count - 1
    }
    struct FlowLink {
        var source: Int
        var target: Int
        var value: Double
        var raw: Double
    }
    var links: [FlowLink] = []
    for link in chart.links {
        let clamped = link.value.isFinite && link.value > 0 ? link.value : 0
        links.append(FlowLink(
            source: nodeIndex(link.source), target: nodeIndex(link.target),
            value: clamped, raw: link.value.isFinite ? link.value : 0))
    }
    let n = ids.count
    guard n > 0 else {
        return ExtraScene(width: 120, height: 120, items: [])
    }
    var outgoing: [[Int]] = Array(repeating: [], count: n)
    var incoming: [[Int]] = Array(repeating: [], count: n)
    for (k, link) in links.enumerated() {
        outgoing[link.source].append(k)
        incoming[link.target].append(k)
    }
    // Longest distance from a source; nodes left over sit on cycles and take
    // their own trailing layers instead of erroring.
    var depth = Array(repeating: 0, count: n)
    var pending = incoming.map(\.count)
    var inOrder = Array(repeating: false, count: n)
    var order: [Int] = []
    for i in 0..<n where pending[i] == 0 {
        order.append(i)
        inOrder[i] = true
    }
    var q = 0
    while q < order.count {
        let i = order[q]
        q += 1
        for k in outgoing[i] {
            let t = links[k].target
            depth[t] = max(depth[t], depth[i] + 1)
            pending[t] -= 1
            if pending[t] == 0 {
                order.append(t)
                inOrder[t] = true
            }
        }
    }
    var layers = (depth.max() ?? 0) + 1
    for i in 0..<n where !inOrder[i] {
        depth[i] = layers
        layers += 1
    }
    // Justify: sinks sit in the last layer.
    var columns = Array(repeating: [Int](), count: layers)
    var flow = Array(repeating: 0.0, count: n)
    var nodeValue = Array(repeating: 0.0, count: n)
    for i in 0..<n {
        let layer = outgoing[i].isEmpty ? layers - 1 : depth[i]
        var into = 0.0, out = 0.0, vin = 0.0, vout = 0.0
        for k in incoming[i] {
            into += links[k].value
            vin += links[k].raw
        }
        for k in outgoing[i] {
            out += links[k].value
            vout += links[k].raw
        }
        flow[i] = max(into, out)
        nodeValue[i] = max(vin, vout)
        columns[layer].append(i)
    }
    let tallest = columns.map(\.count).max() ?? 1
    let gap = tallest > 1 ? min(nodePadding, plotH / Double(tallest - 1)) : nodePadding
    var scale = Double.infinity
    for col in columns {
        let sum = col.reduce(0.0) { $0 + flow[$1] }
        if sum > 0 {
            scale = min(scale, (plotH - Double(col.count - 1) * gap) / sum)
        }
    }
    if !scale.isFinite || scale < 0 { scale = 0 }
    // A thin node still needs room for its label; where every column can
    // afford it, each node claims at least a label's height.
    let labelHeight = labelSize * 1.15
    var claim = max(0, labelHeight - gap)
    func fits(_ s: Double) -> Bool {
        for col in columns {
            var extent = Double(col.count - 1) * gap
            for i in col { extent += max(flow[i] * s, claim) }
            if extent > plotH + 1e-6 { return false }
        }
        return true
    }
    if claim > 0, !fits(scale) {
        if fits(0) {
            var low = 0.0
            for _ in 0..<40 {
                let mid = (low + scale) / 2
                if fits(mid) { low = mid } else { scale = mid }
            }
            scale = low
        } else {
            claim = 0
        }
    }
    let thickness = links.map { $0.value * scale }
    var nodeY = Array(repeating: 0.0, count: n)
    var nodeH = Array(repeating: 0.0, count: n)
    var margin = Array(repeating: 0.0, count: n)
    for col in columns {
        var y = 0.0
        for i in col {
            nodeH[i] = flow[i] * scale
            margin[i] = max(0, claim - nodeH[i]) / 2
            nodeY[i] = y + margin[i]
            y += nodeH[i] + 2 * margin[i] + gap
        }
        // Spare room is shared out between the nodes of a column.
        let spare = (plotH - y + gap) / Double(col.count + 1)
        for (k, i) in col.enumerated() { nodeY[i] += spare * Double(k + 1) }
    }
    func center(_ i: Int) -> Double { nodeY[i] + nodeH[i] / 2 }
    var sourceOff = Array(repeating: 0.0, count: links.count)
    var targetOff = Array(repeating: 0.0, count: links.count)
    // Bands leave and enter a node in the order of where they go, so they do
    // not cross at it.
    func stackOut(_ i: Int) {
        outgoing[i].sort {
            let a = center(links[$0].target), b = center(links[$1].target)
            return a != b ? a < b : $0 < $1
        }
        var y = 0.0
        for k in outgoing[i] {
            sourceOff[k] = y + thickness[k] / 2
            y += thickness[k]
        }
    }
    func stackIn(_ i: Int) {
        incoming[i].sort {
            let a = center(links[$0].source), b = center(links[$1].source)
            return a != b ? a < b : $0 < $1
        }
        var y = 0.0
        for k in incoming[i] {
            targetOff[k] = y + thickness[k] / 2
            y += thickness[k]
        }
    }
    func stackAll() {
        for i in 0..<n {
            stackOut(i)
            stackIn(i)
        }
    }
    // Moves each node towards where its bands would run level, then restores
    // the order and the gaps.
    func settle(_ l: Int, pull: Double, forward: Bool) {
        for i in columns[l] {
            let list = forward ? incoming[i] : outgoing[i]
            if list.isEmpty { continue }
            if forward { stackIn(i) } else { stackOut(i) }
            var weighted = 0.0, weight = 0.0, plain = 0.0
            for k in list {
                let level = forward
                    ? nodeY[links[k].source] + sourceOff[k] - targetOff[k]
                    : nodeY[links[k].target] + targetOff[k] - sourceOff[k]
                weighted += level * thickness[k]
                weight += thickness[k]
                plain += center(forward ? links[k].source : links[k].target) - nodeH[i] / 2
            }
            let wanted = weight > 0 ? weighted / weight : plain / Double(list.count)
            nodeY[i] += (wanted - nodeY[i]) * pull
        }
        columns[l].sort {
            center($0) != center($1) ? center($0) < center($1) : $0 < $1
        }
        var y = 0.0
        for i in columns[l] {
            if nodeY[i] - margin[i] < y { nodeY[i] = y + margin[i] }
            y = nodeY[i] + nodeH[i] + margin[i] + gap
        }
        y = plotH
        for i in columns[l].reversed() {
            if nodeY[i] + nodeH[i] + margin[i] > y {
                nodeY[i] = y - nodeH[i] - margin[i]
            }
            y = nodeY[i] - margin[i] - gap
        }
    }
    stackAll()
    for pass in 0..<6 {
        let pull = pow(0.99, Double(pass))
        if layers >= 2 {
            for l in stride(from: layers - 2, through: 0, by: -1) {
                settle(l, pull: pull, forward: false)
            }
        }
        stackAll()
        for l in 1..<layers { settle(l, pull: pull, forward: true) }
        stackAll()
    }
    let sourceY = links.indices.map { nodeY[links[$0].source] + sourceOff[$0] }
    let targetY = links.indices.map { nodeY[links[$0].target] + targetOff[$0] }

    // Labels sit beside the bars, on the side facing the middle of the chart.
    var central = 0
    var most = 0.0
    for i in 0..<n where nodeValue[i] > most {
        most = nodeValue[i]
        central = outgoing[i].isEmpty ? layers - 1 : depth[i]
    }
    func labelText(_ i: Int) -> String {
        chart.showValues ? "\(ids[i]) \(sankeyRounded(nodeValue[i]))" : ids[i]
    }
    // Room for left-facing labels is reserved before the first column.
    var leftRoom = 0.0
    for i in 0..<n {
        let layer = outgoing[i].isEmpty ? layers - 1 : depth[i]
        if layer < central {
            leftRoom = max(leftRoom, ExtraText.width(labelText(i), size: labelSize) + labelGap)
        }
    }
    let x0 = pad + leftRoom
    func nodeX(_ i: Int) -> Double {
        let layer = outgoing[i].isEmpty ? layers - 1 : depth[i]
        return x0 + Double(layer) * colGap
    }
    // One band: the cubic top edge out and the cubic bottom edge back.
    func band(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ half: Double) -> [ExtraPoint] {
        let segs = 8
        let mid = (ax + bx) / 2
        func cubic(_ t: Double, _ p0: Double, _ p1: Double) -> Double {
            let u = 1 - t
            return u * u * u * p0 + 3 * u * u * t * p0 + 3 * u * t * t * p1 + t * t * t * p1
        }
        // Pele's curve meets the bar with a horizontal tangent; with the
        // shared mid control point x(t) is monotone between the bars.
        func x(_ t: Double) -> Double {
            let u = 1 - t
            return u * u * u * ax + 3 * u * u * t * mid + 3 * u * t * t * mid + t * t * t * bx
        }
        var pts: [ExtraPoint] = []
        for s in 0...segs {
            let t = Double(s) / Double(segs)
            pts.append(ExtraPoint(x: x(t), y: cubic(t, ay - half, by - half)))
        }
        for s in stride(from: segs, through: 0, by: -1) {
            let t = Double(s) / Double(segs)
            pts.append(ExtraPoint(x: x(t), y: cubic(t, ay + half, by + half)))
        }
        return pts
    }
    var items: [ExtraItem] = []
    for (k, link) in links.enumerated() {
        let ax = nodeX(link.source) + nodeW
        let bx = nodeX(link.target)
        let half = max(thickness[k], 1) / 2
        items.append(.polyline(
            points: band(ax, sourceY[k], bx, targetY[k], half),
            fill: .series(ExtraText.seriesIndex(ids[link.source])),
            stroke: .series(ExtraText.seriesIndex(ids[link.source])),
            width: 1, closed: true))
    }
    for i in 0..<n {
        let h = max(nodeH[i], 1)
        items.append(.rect(
            x: nodeX(i), y: nodeY[i], width: nodeW, height: h,
            fill: .series(ExtraText.seriesIndex(ids[i])), stroke: .border, corner: 2, dashed: false))
    }
    var maxX = x0 + Double(max(layers - 1, 0)) * colGap + nodeW
    for i in 0..<n {
        let layer = outgoing[i].isEmpty ? layers - 1 : depth[i]
        let after = layer >= central
        let label = ExtraText.truncate(labelText(i), size: labelSize, weight: 400, maxWidth: 260)
        let lx = after ? nodeX(i) + nodeW + labelGap : nodeX(i) - labelGap
        items.append(.text(
            label, x: lx, y: nodeY[i] + nodeH[i] / 2, size: labelSize,
            fill: .foreground, anchor: after ? .start : .end, weight: 400))
        if after {
            maxX = max(maxX, lx + ExtraText.width(label, size: labelSize))
        }
    }
    return ExtraScene(width: maxX + pad, height: plotH + 2 * pad, items: items)
}

func layoutRadar(_ chart: RadarChart) -> ExtraScene {
    var width = 420.0
    let header = titleItems(chart.title, width: width)
    var items = header.items
    let cx = 210.0
    let cy = header.top + 140
    let radius = 110.0
    let n = max(chart.axes.count, 3)
    let dataMax = chart.series.flatMap(\.values).max()
    let top = chart.max ?? dataMax ?? 1
    let span = max(top - chart.min, 1e-9)
    func scale(_ value: Double) -> Double {
        max(0, radius * (value - chart.min) / span)
    }
    let ticks = max(chart.ticks, 1)
    for ring in 1...ticks {
        let r = radius * Double(ring) / Double(ticks)
        if chart.graticule == "circle" {
            items.append(.ellipse(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r, fill: .none, stroke: .muted))
        } else {
            var pts: [ExtraPoint] = []
            for i in 0..<n {
                let a = -Double.pi / 2 + Double(i) / Double(n) * 2 * Double.pi
                pts.append(ExtraPoint(x: cx + cos(a) * r, y: cy + sin(a) * r))
            }
            items.append(.polyline(points: pts, fill: .none, stroke: .muted, width: 1, closed: true))
        }
    }
    for (i, axis) in chart.axes.enumerated() {
        let a = -Double.pi / 2 + Double(i) / Double(n) * 2 * Double.pi
        items.append(.line(x1: cx, y1: cy, x2: cx + cos(a) * radius, y2: cy + sin(a) * radius, stroke: .border, width: 1, dashed: false))
        items.append(.text(axis, x: cx + cos(a) * (radius + 18), y: cy + sin(a) * (radius + 18), size: 11, fill: .foreground, anchor: .middle, weight: 400))
    }
    for (si, series) in chart.series.enumerated() {
        var pts: [ExtraPoint] = []
        for i in 0..<n {
            let value = i < series.values.count ? series.values[i] : chart.min
            let a = -Double.pi / 2 + Double(i) / Double(n) * 2 * Double.pi
            let r = scale(value)
            pts.append(ExtraPoint(x: cx + cos(a) * r, y: cy + sin(a) * r))
        }
        items.append(.polyline(points: pts, fill: .none, stroke: .series(si), width: 2, closed: true))
    }
    if chart.showLegend, !chart.series.isEmpty {
        let legendWidth = chart.series.map(\.name).reduce(0.0) { max($0, Double($1.count) * 7 + 24) }
        var ly = cy - Double(chart.series.count * 22) / 2
        for (si, series) in chart.series.enumerated() {
            items.append(.rect(x: cx + radius + 16, y: ly, width: 12, height: 12,
                               fill: .series(si), stroke: .none, corner: 2, dashed: false))
            items.append(.text(series.name, x: cx + radius + 32, y: ly + 6, size: 11,
                               fill: .foreground, anchor: .start, weight: 400))
            ly += 22
        }
        width += legendWidth
    }
    return ExtraScene(width: width, height: header.top + 300, items: items)
}

func layoutTreemap(_ chart: TreemapChart) -> ExtraScene {
    let width = 560.0
    let header = titleItems(chart.title, width: width)
    var items = header.items
    let plot = (x: 16.0, y: header.top, w: 528.0, h: 320.0)
    func squarify(_ node: TreemapNode, x: Double, y: Double, w: Double, h: Double, depth: Int) {
        if node.children.isEmpty {
            items.append(.rect(x: x, y: y, width: max(w - 2, 4), height: max(h - 2, 4), fill: .series(depth % 6), stroke: .background, corner: 4, dashed: false))
            if w > 40 && h > 18 {
                items.append(.text(node.name, x: x + w / 2, y: y + h / 2, size: 11, fill: .foreground, anchor: .middle, weight: 500))
            }
            return
        }
        let total = max(node.children.map(\.value).reduce(0, +), 1)
        var cursor = 0.0
        let horizontal = w >= h
        for child in node.children {
            let frac = child.value / total
            if horizontal {
                squarify(child, x: x + cursor, y: y, w: w * frac, h: h, depth: depth + 1)
                cursor += w * frac
            } else {
                squarify(child, x: x, y: y + cursor, w: w, h: h * frac, depth: depth + 1)
                cursor += h * frac
            }
        }
    }
    squarify(chart.root, x: plot.x, y: plot.y, w: plot.w, h: plot.h, depth: 0)
    return ExtraScene(width: width, height: plot.y + plot.h + 16, items: items)
}

func layoutVenn(_ chart: VennChart) -> ExtraScene {
    let width = 420.0
    let header = titleItems(chart.title, width: width)
    var items = header.items
    let centers: [(Double, Double)] = [(160, 180), (260, 180), (210, 260)]
    for (i, set) in chart.sets.prefix(3).enumerated() {
        let c = centers[i]
        // Translucent series fill with a solid series edge, like Pele's
        // `fill-opacity="0.2"` circles, so overlaps darken.
        items.append(.ellipse(
            x: c.0 - 80, y: c.1 - 80, width: 160, height: 160,
            fill: .translucent(.series(i)), stroke: .series(i)))
        items.append(.text(set.label, x: c.0, y: c.1 - 50, size: 13, fill: .foreground, anchor: .middle, weight: 600))
    }
    return ExtraScene(width: width, height: 360, items: items)
}

func layoutPacket(_ chart: PacketChart) -> ExtraScene {
    let bitsPerRow = 32
    let bitW = 18.0
    let rowH = 36.0
    let header = titleItems(chart.title, width: 40 + 32 * bitW)
    var items = header.items
    let maxBit = chart.fields.map(\.end).max() ?? 31
    let rows = max(1, maxBit / bitsPerRow + 1)
    for row in 0..<rows {
        for b in 0..<bitsPerRow {
            let x = 24 + Double(b) * bitW
            let y = header.top + Double(row) * rowH
            items.append(.rect(x: x, y: y, width: bitW, height: rowH, fill: .surface, stroke: .border, corner: 0, dashed: false))
            items.append(.text("\(row * bitsPerRow + b)", x: x + bitW / 2, y: y + 8, size: 8, fill: .muted, anchor: .middle, weight: 400))
        }
    }
    for (i, field) in chart.fields.enumerated() {
        let start = field.start
        let row = start / bitsPerRow
        let col = start % bitsPerRow
        let widthBits = Double(field.end - field.start + 1)
        items.append(.rect(
            x: 24 + Double(col) * bitW,
            y: header.top + Double(row) * rowH + 14,
            width: widthBits * bitW - 1,
            height: rowH - 16,
            fill: .series(i % 6),
            stroke: .border,
            corner: 2,
            dashed: false
        ))
        items.append(.text(field.label, x: 24 + Double(col) * bitW + 4, y: header.top + Double(row) * rowH + 24, size: 10, fill: .foreground, anchor: .start, weight: 500))
    }
    return ExtraScene(width: 48 + 32 * bitW, height: header.top + Double(rows) * rowH + 16, items: items)
}

/// Lays out `block-beta` grids. Port of Pele's `src/diagrams/block/layout.ts`:
/// each container grids its children (`columns -1` flows one row), every
/// column takes the widest block, plain-block rows take the tallest block,
/// and spare room is shared out. Coordinates are top-left (Pele centers).
func layoutBlock(_ chart: BlockChart) -> ExtraScene {
    let gap = 12.0
    let pad = 24.0
    let labelSize = 13.0

    final class Cell {
        var node: BlockNode
        var children: [Cell] = []
        var columns = -1
        var span = 1
        var isSpace = false
        var head = 0.0
        var nw = 0.0, nh = 0.0
        var col = 0, row = 0, cols = 0
        var heights: [Double] = []
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        init(_ node: BlockNode) { self.node = node }
    }

    func leafSize(_ node: BlockNode) -> (w: Double, h: Double, head: Double) {
        if node.kind == "space" { return (0, 0, 0) }
        if node.kind == "composite" {
            let head: Double = node.label.isEmpty ? 0 : 24
            let w = max(ExtraText.width(node.label, size: 12, weight: 600) + 2 * gap, 48)
            return (w, head + 2 * gap, head)
        }
        if node.shape == "block_arrow",
           node.label.trimmingCharacters(in: .whitespaces).isEmpty {
            return (46, 46, 0)
        }
        let w = max(ExtraText.width(node.label, size: labelSize, weight: 500) + 30, 64)
        var h = 50.0
        if node.shape == "cylinder" { h = 86 }
        if node.shape == "block_arrow" { return (max(w, 76), h, 0) }
        return (w, h, 0)
    }

    func build(_ node: BlockNode) -> Cell {
        let cell = Cell(node)
        cell.columns = node.kind == "composite" ? node.columns : -1
        cell.span = max(node.span, 1)
        cell.isSpace = node.kind == "space"
        let size = leafSize(node)
        cell.nw = size.w
        cell.nh = size.h
        cell.head = size.head
        cell.children = node.children.map(build)
        return cell
    }

    // Puts each child in its grid cell and sizes the container. A block
    // wider than the rest of its row stops at the last column.
    func measure(_ box: Cell, inset: Double) {
        let columns = box.columns
        var heights: [Double] = []
        var position = 0
        var cols = 0
        var cw = 0.0
        var tallest = 0.0
        for child in box.children {
            let px: Int
            let py: Int
            if columns > 0 {
                px = position % columns
                py = position / columns
            } else {
                px = position
                py = 0
            }
            // Mermaid lets a block wider than the rest of its row stick out
            // of the grid; here it stops at the last column.
            var span = child.span >= 1 ? min(child.span, 1000) : 1
            if columns > 0, span > columns - px { span = columns - px }
            child.span = span
            child.col = px
            child.row = py
            position += span
            cols = max(cols, px + span)
            if py == heights.count { heights.append(0) }
            if child.children.isEmpty {
                heights[py] = -1
            } else if heights[py] >= 0 {
                heights[py] = max(heights[py], child.nh)
            }
            if child.isSpace { continue }
            cw = max(cw, (child.nw - gap * Double(span - 1)) / Double(span))
            tallest = max(tallest, child.nh)
        }
        var height = Double(max(heights.count - 1, 0)) * gap
        for row in 0..<heights.count {
            if heights[row] < 0 { heights[row] = tallest }
            height += heights[row]
        }
        box.cols = cols
        box.heights = heights
        box.nw = max(box.nw, Double(cols) * cw + Double(max(cols - 1, 0)) * gap + 2 * inset)
        box.nh = height + 2 * inset + box.head
    }

    // Gives each child its cell, sharing out room beyond what is needed.
    func arrange(_ box: Cell, inset: Double) {
        let cols = max(box.cols, 1)
        let rows = box.heights.count
        let cw = (box.w - 2 * inset - Double(cols - 1) * gap) / Double(cols)
        let room = box.h - 2 * inset - box.head - Double(max(rows - 1, 0)) * gap
        let needed = box.heights.reduce(0, +)
        let scale = needed > 0 ? room / needed : 0
        let share = needed > 0 ? 0 : room / Double(max(rows, 1))
        var tops: [Double] = []
        var top = box.y + inset + box.head
        for row in 0..<rows {
            tops.append(top)
            top += box.heights[row] * scale + share + gap
        }
        for child in box.children {
            child.w = cw * Double(child.span) + gap * Double(child.span - 1)
            child.h = box.heights[child.row] * scale + share
            child.x = box.x + inset + Double(child.col) * (cw + gap)
            child.y = tops[child.row]
        }
    }

    let root = build(chart.root)
    var order: [Cell] = [root]
    var cursor = 0
    while cursor < order.count {
        order.append(contentsOf: order[cursor].children)
        cursor += 1
    }
    for box in order.reversed() where !box.children.isEmpty {
        measure(box, inset: box === root ? 0 : gap)
    }
    root.w = root.nw
    root.h = root.nh
    root.x = pad
    root.y = pad
    for box in order where !box.children.isEmpty {
        arrange(box, inset: box === root ? 0 : gap)
    }

    var items: [ExtraItem] = []
    var rects: [String: (x: Double, y: Double, w: Double, h: Double)] = [:]

    func diamond(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [ExtraPoint] {
        [ExtraPoint(x: x + w / 2, y: y), ExtraPoint(x: x + w, y: y + h / 2),
         ExtraPoint(x: x + w / 2, y: y + h), ExtraPoint(x: x, y: y + h / 2)]
    }

    func hexagon(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [ExtraPoint] {
        let c = min(14, w / 4)
        return [ExtraPoint(x: x + c, y: y), ExtraPoint(x: x + w - c, y: y),
                ExtraPoint(x: x + w, y: y + h / 2), ExtraPoint(x: x + w - c, y: y + h),
                ExtraPoint(x: x + c, y: y + h), ExtraPoint(x: x, y: y + h / 2)]
    }

    func slant(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ dx: Double) -> [ExtraPoint] {
        [ExtraPoint(x: x + dx, y: y), ExtraPoint(x: x + w + dx, y: y),
         ExtraPoint(x: x + w - dx, y: y + h), ExtraPoint(x: x - dx, y: y + h)]
    }

    func arrowGlyph(_ x: Double, _ y: Double, _ s: Double, _ direction: String) -> [ExtraPoint] {
        switch direction {
        case "left":
            return [ExtraPoint(x: x, y: y + s / 2), ExtraPoint(x: x + s, y: y),
                    ExtraPoint(x: x + s, y: y + s)]
        case "up":
            return [ExtraPoint(x: x + s / 2, y: y), ExtraPoint(x: x + s, y: y + s),
                    ExtraPoint(x: x, y: y + s)]
        case "down":
            return [ExtraPoint(x: x + s / 2, y: y + s), ExtraPoint(x: x + s, y: y),
                    ExtraPoint(x: x, y: y)]
        default:
            return [ExtraPoint(x: x + s, y: y + s / 2), ExtraPoint(x: x, y: y),
                    ExtraPoint(x: x, y: y + s)]
        }
    }

    // Paint order: composites behind leaves, edges above leaves, labels last.
    // The root container draws no frame of its own (Pele).
    var leafItems: [ExtraItem] = []
    var labelItems: [ExtraItem] = []
    for cell in order where cell !== root {
        let node = cell.node
        if cell.isSpace { continue }
        rects[node.id] = (cell.x, cell.y, cell.w, cell.h)
        if node.kind == "composite" {
            items.append(.rect(
                x: cell.x, y: cell.y, width: cell.w, height: cell.h,
                fill: .background, stroke: .muted, corner: 8, dashed: true))
            if !node.label.isEmpty {
                labelItems.append(.text(
                    ExtraText.truncate(node.label, size: 12, weight: 600, maxWidth: cell.w - 20),
                    x: cell.x + 12, y: cell.y + 16, size: 12,
                    fill: .muted, anchor: .start, weight: 600))
            }
            continue
        }
        let label = ExtraText.truncate(node.label, size: labelSize, weight: 500, maxWidth: cell.w - 16)
        switch node.shape {
        case "circle", "doublecircle":
            leafItems.append(.ellipse(
                x: cell.x, y: cell.y, width: cell.w, height: cell.h,
                fill: .surface, stroke: .border))
        case "diamond":
            leafItems.append(.polyline(
                points: diamond(cell.x, cell.y, cell.w, cell.h),
                fill: .surface, stroke: .border, width: 1.5, closed: true))
        case "hexagon":
            leafItems.append(.polyline(
                points: hexagon(cell.x, cell.y, cell.w, cell.h),
                fill: .surface, stroke: .border, width: 1.5, closed: true))
        case "lean_right":
            leafItems.append(.polyline(
                points: slant(cell.x, cell.y, cell.w - 12, cell.h, 6),
                fill: .surface, stroke: .border, width: 1.5, closed: true))
        case "lean_left":
            leafItems.append(.polyline(
                points: slant(cell.x + 12, cell.y, cell.w - 12, cell.h, -6),
                fill: .surface, stroke: .border, width: 1.5, closed: true))
        case "trapezoid":
            leafItems.append(.polyline(
                points: slant(cell.x, cell.y, cell.w - 12, cell.h, -6),
                fill: .surface, stroke: .border, width: 1.5, closed: true))
        case "inv_trapezoid":
            leafItems.append(.polyline(
                points: slant(cell.x + 12, cell.y, cell.w - 12, cell.h, 6),
                fill: .surface, stroke: .border, width: 1.5, closed: true))
        case "block_arrow"
            where node.label.trimmingCharacters(in: .whitespaces).isEmpty:
            leafItems.append(.polyline(
                points: arrowGlyph(cell.x + cell.w / 2 - 12, cell.y + cell.h / 2 - 12, 24,
                                   node.directions.first ?? "right"),
                fill: .accent, stroke: .border, width: 1.5, closed: true))
            continue
        default:
            let corner: Double =
                node.shape == "round" || node.shape == "stadium" ? 14
                : node.shape == "cylinder" ? 10 : 6
            leafItems.append(.rect(
                x: cell.x, y: cell.y, width: cell.w, height: cell.h,
                fill: .surface, stroke: .border, corner: corner, dashed: false))
        }
        labelItems.append(.text(
            label, x: cell.x + cell.w / 2, y: cell.y + cell.h / 2, size: labelSize,
            fill: .foreground, anchor: .middle, weight: 500))
    }

    func outline(_ r: (x: Double, y: Double, w: Double, h: Double), _ other: ExtraPoint) -> ExtraPoint {
        let cx = r.x + r.w / 2
        let cy = r.y + r.h / 2
        let dx = other.x - cx
        let dy = other.y - cy
        if dx == 0, dy == 0 { return ExtraPoint(x: cx, y: cy) }
        let sx = dx == 0 ? Double.infinity : (r.w / 2) / abs(dx)
        let sy = dy == 0 ? Double.infinity : (r.h / 2) / abs(dy)
        let s = min(sx, sy)
        return ExtraPoint(x: cx + dx * s, y: cy + dy * s)
    }

    func head(_ tip: ExtraPoint, _ angle: Double, hollow: Bool) -> ExtraItem {
        let len = 10.0
        let half = 4.5
        let bx = tip.x - cos(angle) * len
        let by = tip.y - sin(angle) * len
        let px = -sin(angle) * half
        let py = cos(angle) * half
        return .polyline(
            points: [ExtraPoint(x: tip.x, y: tip.y),
                     ExtraPoint(x: bx + px, y: by + py),
                     ExtraPoint(x: bx - px, y: by - py)],
            fill: hollow ? .background : .foreground, stroke: .foreground,
            width: 1.5, closed: true)
    }

    func markers(_ point: ExtraPoint, _ kind: String) -> [ExtraItem] {
        switch kind {
        case "arrow_circle":
            return [.ellipse(
                x: point.x - 4, y: point.y - 4, width: 8, height: 8,
                fill: .background, stroke: .foreground)]
        case "arrow_cross":
            return [.line(
                x1: point.x - 4, y1: point.y - 4, x2: point.x + 4, y2: point.y + 4,
                stroke: .foreground, width: 1.5, dashed: false),
                .line(
                    x1: point.x - 4, y1: point.y + 4, x2: point.x + 4, y2: point.y - 4,
                    stroke: .foreground, width: 1.5, dashed: false)]
        default:
            return []
        }
    }

    // Edges between the same two blocks spread apart instead of stacking.
    var pairCount: [String: Int] = [:]
    for edge in chart.edges {
        pairCount["\(edge.start)\u{0}\(edge.end)", default: 0] += 1
    }
    var pairSeen: [String: Int] = [:]
    var edgeLines: [ExtraItem] = []
    var edgeHeads: [ExtraItem] = []
    var edgeLabels: [ExtraItem] = []
    for edge in chart.edges {
        guard let a = rects[edge.start], let b = rects[edge.end],
              edge.start != edge.end else { continue }
        let key = "\(edge.start)\u{0}\(edge.end)"
        let slot = pairSeen[key, default: 0]
        pairSeen[key] = slot + 1
        let spread = (Double(slot) - Double((pairCount[key] ?? 1) - 1) / 2) * 7
        let ca = ExtraPoint(x: a.x + a.w / 2, y: a.y + a.h / 2)
        let cb = ExtraPoint(x: b.x + b.w / 2, y: b.y + b.h / 2)
        let pa = outline(a, cb)
        let pb = outline(b, ca)
        let dx = pb.x - pa.x
        let dy = pb.y - pa.y
        let len = max(1, sqrt(dx * dx + dy * dy))
        let p1 = ExtraPoint(x: pa.x - dy / len * spread, y: pa.y + dx / len * spread)
        let p2 = ExtraPoint(x: pb.x - dy / len * spread, y: pb.y + dx / len * spread)
        edgeLines.append(.line(
            x1: p1.x, y1: p1.y, x2: p2.x, y2: p2.y,
            stroke: .accent, width: edge.thick ? 2.5 : 1.5, dashed: edge.dotted))
        let angle = atan2(p2.y - p1.y, p2.x - p1.x)
        if edge.startMarker == "arrow_point" {
            edgeHeads.append(head(p1, angle + .pi, hollow: false))
        } else {
            edgeHeads.append(contentsOf: markers(p1, edge.startMarker))
        }
        if edge.endMarker == "arrow_point" {
            edgeHeads.append(head(p2, angle, hollow: false))
        } else {
            edgeHeads.append(contentsOf: markers(p2, edge.endMarker))
        }
        if !edge.label.isEmpty {
            edgeLabels.append(.text(
                ExtraText.truncate(edge.label, size: 10, weight: 400, maxWidth: 160),
                x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2 - 8,
                size: 10, fill: .muted, anchor: .middle, weight: 400))
        }
    }
    // Paint order: composite frames, edge lines, leaves, markers, labels.
    items.append(contentsOf: edgeLines)
    items.append(contentsOf: leafItems)
    items.append(contentsOf: edgeHeads)
    items.append(contentsOf: edgeLabels)
    items.append(contentsOf: labelItems)
    return ExtraScene(width: root.x + root.w + pad, height: root.y + root.h + pad, items: items)
}

func layoutBoxes(_ boxes: [NamedBox], edges: [NamedEdge], title: String) -> ExtraScene {
    let boxW = 170.0
    let colW = 192.0
    let cols = 3
    let hGap = 20.0
    let inner = boxW - 24
    struct PlacedBox {
        var id: String
        var x: Double
        var y: Double
        var h: Double
        var rowBottom: Double
        var labelLines: [String]
        var detailLines: [String]
    }
    // Details wrap inside the box and rows grow to fit the tallest box, so
    // long C4 descriptions paint inside their own box instead of over the
    // neighbor's text.
    //
    // A row whose boxes share an edge reserves a lane below it: the 22pt gap
    // between neighbors cannot fit an edge label, so same-row edges drop
    // into the lane instead of straddling both borders.
    let rowOf = Dictionary(
        boxes.enumerated().map { ($1.id, $0 / cols) },
        uniquingKeysWith: { first, _ in first })
    func needsLane(_ ids: [String]) -> Bool {
        edges.contains {
            $0.from != $0.to
                && ids.contains($0.from) && ids.contains($0.to)
                && rowOf[$0.from] == rowOf[$0.to]
        }
    }
    var placed: [PlacedBox] = []
    var y = 56.0
    var index = 0
    while index < boxes.count {
        let row = Array(boxes[index..<min(index + cols, boxes.count)])
        var specs: [(label: [String], detail: [String], h: Double)] = []
        var rowH = 0.0
        for box in row {
            var label = ExtraText.wrap(box.label, size: 12, weight: 600, maxWidth: inner)
            if label.isEmpty { label = [box.label] }
            let detail = ExtraText.wrap(box.detail, size: 10, weight: 400, maxWidth: inner)
            let h = max(
                12 + Double(label.count) * 15 + (detail.isEmpty ? 0 : 6 + Double(detail.count) * 13) + 10,
                54
            )
            specs.append((label, detail, h))
            rowH = max(rowH, h)
        }
        let lane = needsLane(row.map(\.id)) ? 34.0 : 0.0
        for (col, box) in row.enumerated() {
            placed.append(PlacedBox(
                id: box.id, x: 24 + Double(col) * colW, y: y, h: specs[col].h,
                rowBottom: y + rowH,
                labelLines: specs[col].label, detailLines: specs[col].detail
            ))
        }
        y += rowH + lane + hGap
        index += cols
    }
    let sceneW = 24 + Double(cols) * colW
    var items: [ExtraItem] = titleItems(title, width: sceneW).items
    var byID: [String: PlacedBox] = [:]
    for p in placed where byID[p.id] == nil { byID[p.id] = p }
    for p in placed {
        items.append(.rect(x: p.x, y: p.y, width: boxW, height: p.h, fill: .surface, stroke: .border, corner: 6, dashed: false))
        var ty = p.y + 10
        for line in p.labelLines {
            items.append(.text(line, x: p.x + boxW / 2, y: ty + 7.5, size: 12, fill: .foreground, anchor: .middle, weight: 600))
            ty += 15
        }
        if !p.detailLines.isEmpty {
            ty += 6
            for line in p.detailLines {
                items.append(.text(line, x: p.x + boxW / 2, y: ty + 6.5, size: 10, fill: .muted, anchor: .middle, weight: 400))
                ty += 13
            }
        }
    }
    for edge in edges {
        guard let a = byID[edge.from], let b = byID[edge.to], edge.from != edge.to else { continue }
        if abs(a.y - b.y) < 1 {
            // Same row: neighbors sit only one gap apart, so a label centered
            // between them straddles both borders. Route the edge down into
            // the lane reserved below the row and label the bottom run.
            let left = a.x <= b.x ? a : b
            let right = a.x <= b.x ? b : a
            let laneY = max(a.rowBottom, b.rowBottom) + 22
            let exitY = min(a.y + a.h, b.y + b.h) + 8
            let ex = left.x + boxW / 2
            let nx = right.x + boxW / 2
            items.append(.line(x1: ex, y1: exitY, x2: ex, y2: laneY, stroke: .accent, width: 1.2, dashed: false))
            items.append(.line(x1: ex, y1: laneY, x2: nx, y2: laneY, stroke: .accent, width: 1.2, dashed: false))
            items.append(.line(x1: nx, y1: laneY, x2: nx, y2: exitY, stroke: .accent, width: 1.2, dashed: false))
            if !edge.label.isEmpty {
                items.append(.text(
                    edge.label, x: (ex + nx) / 2, y: laneY + 11,
                    size: 10, fill: .muted, anchor: .middle, weight: 400
                ))
            }
        } else {
            let upper = a.y < b.y ? a : b
            let lower = a.y < b.y ? b : a
            items.append(.line(
                x1: upper.x + boxW / 2, y1: upper.y + upper.h,
                x2: lower.x + boxW / 2, y2: lower.y,
                stroke: .accent, width: 1.2, dashed: false
            ))
            if !edge.label.isEmpty {
                items.append(.text(
                    edge.label, x: (upper.x + lower.x) / 2 + boxW / 2 + 6,
                    y: (upper.y + upper.h + lower.y) / 2,
                    size: 10, fill: .muted, anchor: .start, weight: 400
                ))
            }
        }
    }
    return ExtraScene(width: sceneW, height: y + 8, items: items)
}

func layoutArchitecture(_ chart: ArchitectureChart) -> ExtraScene {
    let nodeW = 140.0
    let nodeH = 50.0
    let gap = 20.0
    let pad = 18.0
    let groupHead = 32.0
    let rowCap = 620.0

    // Dedupe; last declaration wins.
    var groups: [NamedBox] = []
    var seenGroups = Set<String>()
    for g in chart.groups.reversed() where !seenGroups.contains(g.id) {
        seenGroups.insert(g.id)
        groups.append(g)
    }
    groups.reverse()
    var services: [NamedBox] = []
    var seenServices = Set<String>()
    for s in chart.services.reversed() where !seenServices.contains(s.id) {
        seenServices.insert(s.id)
        services.append(s)
    }
    services.reverse()
    if groups.isEmpty && services.isEmpty {
        services = [NamedBox(id: "svc", label: "service", detail: "", group: nil)]
    }
    var groupByID: [String: NamedBox] = [:]
    for g in groups where groupByID[g.id] == nil { groupByID[g.id] = g }

    // Detach dangling and cyclic `in` links so every box is reachable.
    func safeParent(of group: NamedBox) -> String? {
        guard let parent = group.group, parent != group.id, groupByID[parent] != nil else { return nil }
        var seen: Set<String> = [group.id]
        var current: String? = parent
        while let id = current {
            if seen.contains(id) { return nil }
            seen.insert(id)
            current = groupByID[id]?.group
        }
        return parent
    }
    var groupParent: [String: String?] = [:]
    for g in groups { groupParent[g.id] = safeParent(of: g) }
    func nodeParent(_ service: NamedBox) -> String? {
        guard let parent = service.group, groupByID[parent] != nil else { return nil }
        return parent
    }

    struct Block {
        var id: String
        var w: Double
        var h: Double
        var group: NamedBox?
        var node: NamedBox?
        var children: [Placed]
    }
    struct Placed {
        var id: String
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        var isGroup: Bool
    }
    enum Run { case single(Block); case row([Block]); case column([Block]) }

    // Recursive flow layout. Returns the container size plus placements in
    // the container's local coordinates (descendants flattened).
    func layoutContainer(_ gid: String?) -> (w: Double, h: Double, placed: [Placed]) {
        var blocks: [Block] = []
        for g in groups where (groupParent[g.id] ?? nil) == gid {
            let sub = layoutContainer(g.id)
            blocks.append(Block(id: g.id, w: sub.w, h: sub.h, group: g, node: nil, children: sub.placed))
        }
        for s in services where nodeParent(s) == gid {
            blocks.append(Block(id: s.id, w: nodeW, h: nodeH, group: nil, node: s, children: []))
        }
        let nodeIDs = Set(blocks.compactMap(\.node?.id))
        var runs: [Run] = blocks.map { .single($0) }
        func runIndex(containing id: String) -> Int? {
            for (i, run) in runs.enumerated() {
                switch run {
                case .single(let b) where b.id == id: return i
                case .row(let arr) where arr.contains(where: { $0.id == id }): return i
                case .column(let arr) where arr.contains(where: { $0.id == id }): return i
                default: break
                }
            }
            return nil
        }
        func extract(_ id: String) -> Block? {
            for (i, run) in runs.enumerated() {
                switch run {
                case .single(let b) where b.id == id:
                    runs.remove(at: i)
                    return b
                case .row(var arr):
                    if let k = arr.firstIndex(where: { $0.id == id }) {
                        let b = arr.remove(at: k)
                        runs[i] = .row(arr)
                        return b
                    }
                case .column(var arr):
                    if let k = arr.firstIndex(where: { $0.id == id }) {
                        let b = arr.remove(at: k)
                        runs[i] = .column(arr)
                        return b
                    }
                default: break
                }
            }
            return nil
        }
        // `align row|column` runs keep directive order at the first hit.
        for align in chart.alignments {
            let members = align.members.filter { nodeIDs.contains($0) }
            guard members.count >= 2, let at = runIndex(containing: members[0]) else { continue }
            var picked: [Block] = []
            for member in members {
                if let block = extract(member) { picked.append(block) }
            }
            if picked.count >= 2 {
                runs.insert(align.axis == "row" ? .row(picked) : .column(picked), at: min(at, runs.count))
            } else {
                for (offset, block) in picked.enumerated() {
                    runs.insert(.single(block), at: min(at + offset, runs.count))
                }
            }
        }
        var rows: [[Block]] = []
        var current: [Block] = []
        var currentW = 0.0
        func flushRow() {
            if !current.isEmpty { rows.append(current) }
            current = []
            currentW = 0
        }
        for run in runs {
            switch run {
            case .single(let block):
                if !current.isEmpty, currentW + gap + block.w > rowCap { flushRow() }
                if !current.isEmpty { currentW += gap }
                current.append(block)
                currentW += block.w
            case .row(let arr) where !arr.isEmpty:
                flushRow()
                rows.append(arr)
            case .column(let arr):
                flushRow()
                for block in arr { rows.append([block]) }
            default: break
            }
        }
        flushRow()
        let contentW = rows.map { $0.map(\.w).reduce(0, +) + gap * Double(max($0.count - 1, 0)) }.max() ?? 0
        let rowsH = rows.map { $0.map(\.h).max() ?? 0 }.reduce(0, +) + gap * Double(max(rows.count - 1, 0))
        let head = gid == nil ? 0 : groupHead
        let width = (gid == nil ? contentW : contentW + pad * 2)
        let height = head + rowsH + (gid == nil ? 0 : pad * 2)
        var placed: [Placed] = []
        var y = head
        for row in rows {
            let rowH = row.map(\.h).max() ?? 0
            let rowW = row.map(\.w).reduce(0, +) + gap * Double(max(row.count - 1, 0))
            var x = gid == nil ? (contentW - rowW) / 2 : pad + (contentW - rowW) / 2
            for block in row {
                let by = y + (rowH - block.h) / 2
                placed.append(Placed(id: block.id, x: x, y: by, w: block.w, h: block.h, isGroup: block.group != nil))
                for child in block.children {
                    placed.append(Placed(
                        id: child.id, x: x + child.x, y: by + child.y,
                        w: child.w, h: child.h, isGroup: child.isGroup
                    ))
                }
                x += block.w + gap
            }
            y += rowH + gap
        }
        return (width, height, placed)
    }

    let flow = layoutContainer(nil)
    let title = chart.title ?? "Architecture"
    let header = titleItems(title, width: flow.w + 48)
    var items = header.items
    var byID: [String: Placed] = [:]
    for p in flow.placed where byID[p.id] == nil {
        byID[p.id] = Placed(
            id: p.id, x: p.x + 24, y: p.y + header.top,
            w: p.w, h: p.h, isGroup: p.isGroup
        )
    }
    var nodeByIDFinal: [String: NamedBox] = [:]
    for s in services where nodeByIDFinal[s.id] == nil { nodeByIDFinal[s.id] = s }

    for p in byID.values where p.isGroup {
        items.append(.rect(x: p.x, y: p.y, width: p.w, height: p.h, fill: .surface, stroke: .border, corner: 8, dashed: false))
        items.append(.text(
            ExtraText.truncate(groupByID[p.id]?.label ?? p.id, size: 12, weight: 600, maxWidth: max(p.w - 24, 24)),
            x: p.x + 12, y: p.y + 16, size: 12, fill: .foreground, anchor: .start, weight: 600
        ))
    }
    // Edge lines paint here (under the nodes) so long port-to-port runs
    // hide behind intermediate boxes instead of striking through them.
    let nodeItemsStart = items.count
    for p in byID.values where !p.isGroup {
        guard let box = nodeByIDFinal[p.id] else { continue }
        if box.shape == "junction" {
            items.append(.ellipse(
                x: p.x + p.w / 2 - 10, y: p.y + (p.h - 20) / 2, width: 20, height: 20,
                fill: .surface, stroke: .border
            ))
            items.append(.text(
                ExtraText.truncate(box.label, size: 10, weight: 400, maxWidth: p.w - 8),
                x: p.x + p.w / 2, y: p.y + p.h - 8, size: 10, fill: .foreground, anchor: .middle, weight: 400
            ))
        } else {
            items.append(.rect(x: p.x, y: p.y, width: p.w, height: p.h, fill: .surface, stroke: .border, corner: 8, dashed: false))
            var labelLines = ExtraText.wrap(box.label, size: 12, weight: 600, maxWidth: nodeW - 24)
            if labelLines.count > 2 {
                labelLines = Array(labelLines.prefix(2))
                labelLines[1] += "…"
            }
            let total = Double(labelLines.count) * 15
            var ty = p.y + (p.h - total) / 2 + 7.5
            for line in labelLines {
                items.append(.text(line, x: p.x + p.w / 2, y: ty, size: 12, fill: .foreground, anchor: .middle, weight: 600))
                ty += 15
            }
        }
    }

    func sidePoint(_ r: Placed, _ port: String) -> CGPoint {
        switch port {
        case "L": return CGPoint(x: r.x, y: r.y + r.h / 2)
        case "R": return CGPoint(x: r.x + r.w, y: r.y + r.h / 2)
        case "T": return CGPoint(x: r.x + r.w / 2, y: r.y)
        default: return CGPoint(x: r.x + r.w / 2, y: r.y + r.h)
        }
    }
    func facingSide(from: Placed, to: Placed) -> String {
        let dx = (to.x + to.w / 2) - (from.x + from.w / 2)
        let dy = (to.y + to.h / 2) - (from.y + from.h / 2)
        if abs(dx) >= abs(dy) { return dx >= 0 ? "R" : "L" }
        return dy >= 0 ? "B" : "T"
    }
    // Orthogonal route from one side port to another, each left along its side's
    // normal. Ported from Pele architecture/render.ts (`route`, STUB 12), without
    // Pele's junction gap/wire cases. Boxes are y-down layout coordinates.
    // (sx0, sy0, sx1, sy1) and (ex0, ey0, ex1, ey1) are the endpoint boxes to steer around.
    let archStub = 12.0
    func archRoute(sx: Double, sy: Double, sdx: Double, sdy: Double,
                   ex: Double, ey: Double, edx: Double, edy: Double,
                   sBox: (Double, Double, Double, Double),
                   eBox: (Double, Double, Double, Double),
                   forceLane: Double? = nil) -> [ExtraPoint] {
        let pt = { (x: Double, y: Double) in ExtraPoint(x: x, y: y) }
        let s1x = sx + sdx * archStub
        let s1y = sy + sdy * archStub
        let e1x = ex + edx * archStub
        let e1y = ey + edy * archStub
        if sdx * edx + sdy * edy == 0 {
            let cx = sdx != 0 ? ex : sx
            let cy = sdx != 0 ? sy : ey
            if (cx - sx) * sdx + (cy - sy) * sdy > 0 && (cx - ex) * edx + (cy - ey) * edy > 0 {
                return [pt(sx, sy), pt(cx, cy), pt(ex, ey)]
            }
            return sdx != 0
                ? [pt(sx, sy), pt(s1x, s1y), pt(s1x, e1y), pt(e1x, e1y), pt(ex, ey)]
                : [pt(sx, sy), pt(s1x, s1y), pt(e1x, s1y), pt(e1x, e1y), pt(ex, ey)]
        }
        let sideways = sdx != 0
        let offset = sideways ? ey - sy : ex - sx
        if sdx == -edx && sdy == -edy {
            let ahead = (ex - sx) * sdx + (ey - sy) * sdy
            if ahead > 0 {
                if abs(offset) < 0.5 { return [pt(sx, sy), pt(ex, ey)] }
                // Turn midway between the two boxes, clear of both titles when there is such a place.
                if sideways {
                    let lo = sdx > 0 ? sBox.2 : eBox.2
                    let hi = sdx > 0 ? eBox.0 : sBox.0
                    let mx = lo < hi ? (lo + hi) / 2 : (sx + ex) / 2
                    return [pt(sx, sy), pt(mx, sy), pt(mx, ey), pt(ex, ey)]
                }
                let lo = sdy > 0 ? sBox.3 : eBox.3
                let hi = sdy > 0 ? eBox.1 : sBox.1
                let my = lo < hi ? (lo + hi) / 2 : (sy + ey) / 2
                return [pt(sx, sy), pt(sx, my), pt(ex, my), pt(ex, ey)]
            }
        } else if abs(offset) >= 1 {
            if sideways {
                let x = sdx > 0 ? max(sx, ex) + archStub : min(sx, ex) - archStub
                return [pt(sx, sy), pt(x, sy), pt(x, ey), pt(ex, ey)]
            }
            let y = sdy > 0 ? max(sy, ey) + archStub : min(sy, ey) - archStub
            return [pt(sx, sy), pt(sx, y), pt(ex, y), pt(ex, ey)]
        }
        // The straight way is blocked by one of the two boxes: go between them, or around both.
        if sideways {
            let lane = forceLane ?? (sBox.3 + archStub <= eBox.1 ? (sBox.3 + eBox.1) / 2
                : eBox.3 + archStub <= sBox.1 ? (eBox.3 + sBox.1) / 2 : max(sBox.3, eBox.3) + archStub)
            return [pt(sx, sy), pt(s1x, sy), pt(s1x, lane), pt(e1x, lane), pt(e1x, ey), pt(ex, ey)]
        }
        let lane = forceLane ?? (sBox.2 + archStub <= eBox.0 ? (sBox.2 + eBox.0) / 2
            : eBox.2 + archStub <= sBox.0 ? (eBox.2 + sBox.0) / 2 : max(sBox.2, eBox.2) + archStub)
        return [pt(sx, sy), pt(sx, s1y), pt(lane, s1y), pt(lane, e1y), pt(ex, e1y), pt(ex, ey)]
    }

    // Drops repeated points and joins runs that continue in a straight line.
    func archSimplify(_ p: [ExtraPoint]) -> [ExtraPoint] {
        guard !p.isEmpty else { return p }
        var out = [p[0]]
        for i in 1..<p.count {
            let x = p[i].x
            let y = p[i].y
            let n = out.count
            let sameX = abs(x - out[n - 1].x) < 0.01
            let sameY = abs(y - out[n - 1].y) < 0.01
            if sameX && sameY { continue }
            if n >= 2 && ((sameX && abs(out[n - 2].x - out[n - 1].x) < 0.01)
                || (sameY && abs(out[n - 2].y - out[n - 1].y) < 0.01)) {
                out[n - 1] = ExtraPoint(x: x, y: y)
            } else {
                out.append(ExtraPoint(x: x, y: y))
            }
        }
        return out
    }

    func archNormal(_ port: String) -> (Double, Double) {
        switch port {
        case "L": return (-1, 0)
        case "R": return (1, 0)
        case "T": return (0, -1)
        default: return (0, 1)
        }
    }
    func arrowhead(_ tip: CGPoint, angle: Double) -> ExtraItem {
        let len = 9.0
        let half = 4.2
        let bx = tip.x - cos(angle) * len
        let by = tip.y - sin(angle) * len
        let px = -sin(angle) * half
        let py = cos(angle) * half
        return .polyline(
            points: [
                ExtraPoint(x: tip.x, y: tip.y),
                ExtraPoint(x: bx + px, y: by + py),
                ExtraPoint(x: bx - px, y: by - py)
            ],
            fill: .accent, stroke: .accent, width: 1, closed: true
        )
    }
    var edgeLines: [ExtraItem] = []
    var edgeHeads: [ExtraItem] = []
    for edge in chart.edges {
        guard let fromNode = nodeByIDFinal[edge.from], let toNode = nodeByIDFinal[edge.to] else { continue }
        let fromRect: Placed
        let fromID: String
        if edge.fromGroup, let parent = nodeParent(fromNode), let g = byID[parent] {
            fromRect = g
            fromID = parent
        } else if let r = byID[edge.from] {
            fromRect = r
            fromID = edge.from
        } else { continue }
        let toRect: Placed
        let toID: String
        if edge.toGroup, let parent = nodeParent(toNode), let g = byID[parent] {
            toRect = g
            toID = parent
        } else if let r = byID[edge.to] {
            toRect = r
            toID = edge.to
        } else { continue }
        let fp = edge.fromPort ?? facingSide(from: fromRect, to: toRect)
        let tp = edge.toPort ?? facingSide(from: toRect, to: fromRect)
        let p1 = sidePoint(fromRect, fp)
        let p2 = sidePoint(toRect, tp)
        let (sdx, sdy) = archNormal(fp)
        let (edx, edy) = archNormal(tp)
        var sx = p1.x
        var sy = p1.y
        var ex = p2.x
        var ey = p2.y
        if sx == ex && sy == ey && sdx == edx && sdy == edy {
            // An edge from a side back to the same side: part the two ends so it shows as a loop.
            sx -= 8 * abs(sdy)
            sy -= 8 * abs(sdx)
            ex += 8 * abs(sdy)
            ey += 8 * abs(sdx)
        }
        func archPoints(forceLane: Double? = nil) -> [ExtraPoint] {
            archSimplify(archRoute(
                sx: sx, sy: sy, sdx: sdx, sdy: sdy,
                ex: ex, ey: ey, edx: edx, edy: edy,
                sBox: (fromRect.x, fromRect.y, fromRect.x + fromRect.w, fromRect.y + fromRect.h),
                eBox: (toRect.x, toRect.y, toRect.x + toRect.w, toRect.y + toRect.h),
                forceLane: forceLane
            ))
        }
        // Ancestor groups of an endpoint: the route travels inside them by construction.
        func ancestorGroups(of groupID: String?) -> Set<String> {
            var out = Set<String>()
            var cur = groupID
            while let g = cur, groupByID[g] != nil {
                out.insert(g)
                cur = groupByID[g]?.group
            }
            return out
        }
        let homeGroups = ancestorGroups(of: edge.fromGroup ? fromID : nodeParent(fromNode))
            .union(ancestorGroups(of: edge.toGroup ? toID : nodeParent(toNode)))
        func hitsThirdBox(_ points: [ExtraPoint]) -> Bool {
            for k in 0..<(points.count - 1) {
                let mid = CGPoint(x: (points[k].x + points[k + 1].x) / 2,
                                  y: (points[k].y + points[k + 1].y) / 2)
                for (id, r) in byID where id != fromID && id != toID && !homeGroups.contains(id) {
                    let box = CGRect(x: r.x, y: r.y, width: r.w, height: r.h).insetBy(dx: 0.5, dy: 0.5)
                    if box.contains(mid) { return true }
                }
            }
            return false
        }
        var points = archPoints()
        if hitsThirdBox(points) {
            // The lane between the endpoints crosses another box: go around the outside instead.
            let allX = byID.values.flatMap { [$0.x, $0.x + $0.w] }
            let allY = byID.values.flatMap { [$0.y, $0.y + $0.h] }
            let lanes = sdx != 0
                ? [(allY.min() ?? ey) - archStub, (allY.max() ?? ey) + archStub]
                : [(allX.min() ?? ex) - archStub, (allX.max() ?? ex) + archStub]
            for lane in lanes {
                let candidate = archPoints(forceLane: lane)
                if !hitsThirdBox(candidate) {
                    points = candidate
                    break
                }
            }
        }
        edgeLines.append(.polyline(points: points, fill: .none, stroke: .accent, width: 1.5, closed: false))
        if edge.startArrow, let first = points.first, points.count > 1 {
            let next = points[1]
            edgeHeads.append(arrowhead(
                CGPoint(x: first.x, y: first.y),
                angle: atan2(first.y - next.y, first.x - next.x)
            ))
        }
        if edge.endArrow, let last = points.last, points.count > 1 {
            let prev = points[points.count - 2]
            edgeHeads.append(arrowhead(
                CGPoint(x: last.x, y: last.y),
                angle: atan2(last.y - prev.y, last.x - prev.x)
            ))
        }
    }
    items.insert(contentsOf: edgeLines, at: nodeItemsStart)
    items.append(contentsOf: edgeHeads)
    return ExtraScene(width: flow.w + 48, height: header.top + flow.h + 20, items: items)
}

func layoutC4(_ chart: C4Chart) -> ExtraScene {
    layoutBoxes(chart.boxes, edges: chart.edges, title: chart.title ?? chart.kind)
}

/// Lays out `kanban` boards: one 200-wide column per section with wrapped
/// cards, ticket/assignee meta rows and priority edge stripes. Port of
/// Pele's `src/diagrams/kanban/render.ts` geometry; column folding,
/// markdown and icons are skipped.
func layoutKanban(_ chart: KanbanChart) -> ExtraScene {
    let colW = 200.0
    let colGap = 12.0
    let colPad = 8.0
    let cardPad = 10.0
    let cardGap = 8.0
    let metaGap = 4.0
    let titleSize = 16.0
    let small = 14.0
    let lineH = 24.0
    let smallLineH = 21.0
    let textW = colW - 2 * colPad - 2 * cardPad

    // Priority edge colors (Pele `PRIORITY`): the high ones in the critical
    // color, the low ones muted, the nearer to Medium the fainter. Luna has
    // no theme-critical fill, so the accent stands in for it.
    func priorityStroke(_ priority: String?) -> ExtraFill? {
        switch (priority ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "very high": return .accent
        case "high": return .translucent(.accent)
        case "low": return .translucent(.muted)
        case "very low": return .muted
        default: return nil
        }
    }

    struct CardLayout {
        var card: KanbanCard
        var lines: [String]
        var ticketLines: [String]
        var assignedLines: [String]
        var meta: Double
        var height: Double
    }
    func layoutCard(_ card: KanbanCard) -> CardLayout {
        let lines = ExtraText.wrap(card.label, size: small, maxWidth: textW)
        let labelH = max(Double(max(lines.count, 1)) * smallLineH, smallLineH)
        let ticketLines = card.ticket.map { ExtraText.wrap($0, size: small, maxWidth: textW) } ?? []
        let assignedLines = card.assigned.map { ExtraText.wrap($0, size: small, maxWidth: textW) } ?? []
        let ticketH = Double(ticketLines.count) * smallLineH
        let assignedH = Double(assignedLines.count) * smallLineH
        let ticketW = ticketLines.map { ExtraText.width($0, size: small) }.max() ?? 0
        let assignedW = assignedLines.map { ExtraText.width($0, size: small) }.max() ?? 0
        let meta = (ticketH == 0 && assignedH == 0) ? 0
            : ticketW + assignedW + 8 > textW ? ticketH + assignedH : max(ticketH, assignedH)
        let height = 2 * cardPad + max(labelH, smallLineH) + (meta > 0 ? metaGap + meta : 0)
        return CardLayout(
            card: card, lines: lines.isEmpty ? [""] : lines,
            ticketLines: ticketLines, assignedLines: assignedLines,
            meta: meta, height: height)
    }

    let boardW = Double(max(chart.columns.count, 1)) * (colW + colGap)
    let header = titleItems(chart.title, width: boardW + 32)
    var items = header.items
    var maxY = header.top
    for (i, column) in chart.columns.enumerated() {
        let x = 16 + Double(i) * (colW + colGap)
        let cards = column.cards.map(layoutCard)
        let bodyH = cards.reduce(0) { $0 + $1.height + cardGap }
        let headH = lineH + 2 * colPad
        let colH = headH + bodyH + colPad
        items.append(.rect(
            x: x, y: header.top, width: colW, height: colH,
            fill: .surface, stroke: .border, corner: 6, dashed: false))
        let countLabel = "\(column.cards.count)"
        let countW = ExtraText.width(countLabel, size: small)
        items.append(.text(
            ExtraText.truncate(column.name, size: titleSize, weight: 600, maxWidth: colW - 24 - countW),
            x: x + colPad + 4, y: header.top + colPad + lineH / 2, size: titleSize,
            fill: .foreground, anchor: .start, weight: 600))
        items.append(.text(
            countLabel, x: x + colW - colPad - 4, y: header.top + colPad + lineH / 2, size: small,
            fill: .muted, anchor: .end, weight: 400))
        var y = header.top + headH
        for laid in cards {
            let cardX = x + colPad
            let cardW = colW - 2 * colPad
            items.append(.rect(
                x: cardX, y: y, width: cardW, height: laid.height,
                fill: .background, stroke: .border, corner: 6, dashed: false))
            if let stroke = priorityStroke(laid.card.priority) {
                items.append(.line(
                    x1: cardX + 2.5, y1: y + 5, x2: cardX + 2.5, y2: y + laid.height - 5,
                    stroke: stroke, width: 3, dashed: false))
            }
            for (li, text) in laid.lines.enumerated() {
                items.append(.text(
                    text, x: cardX + cardPad, y: y + cardPad + smallLineH * (Double(li) + 0.5),
                    size: small, fill: .foreground, anchor: .start, weight: 400))
            }
            let bottom = y + laid.height - cardPad
            if !laid.ticketLines.isEmpty {
                let top = bottom - laid.meta
                for (li, text) in laid.ticketLines.enumerated() {
                    items.append(.text(
                        text, x: cardX + cardPad, y: top + smallLineH * (Double(li) + 0.5),
                        size: small, fill: .muted, anchor: .start, weight: 400))
                }
            }
            if !laid.assignedLines.isEmpty {
                for (li, text) in laid.assignedLines.enumerated() {
                    items.append(.text(
                        text, x: cardX + cardW - cardPad,
                        y: bottom - smallLineH * Double(laid.assignedLines.count - li - 1) - smallLineH / 2,
                        size: small, fill: .muted, anchor: .end, weight: 400))
                }
            }
            y += laid.height + cardGap
            maxY = max(maxY, y)
        }
        maxY = max(maxY, header.top + headH + colPad)
    }
    return ExtraScene(width: boardW + 32, height: max(maxY + 8, 120), items: items)
}

/// Lays out `usecase-beta` left to right: a stick-figure actor column, a
/// use-case column (ellipses, rects for `[…]` cases), `systemBoundary` boxes
/// around their members, and one routed edge per relationship. Ported from
/// Pele's `src/diagrams/usecase/render.ts` geometry (40×60 actor figure) onto
/// Luna's fixed two-column layout instead of the compound engine.
func layoutUseCase(_ chart: UseCaseChart) -> ExtraScene {
    let pad = 28.0
    let figW = 40.0
    let figH = 60.0
    let actorGap = 30.0
    let caseGap = 30.0
    let columnGap = 110.0

    struct NodeFrame {
        var id: String
        var isActor: Bool
        var rect: Bool
        var x, y, w, h: Double
        var cx: Double { x + w / 2 }
        var cy: Double { y + h / 2 }
    }
    var frames: [String: NodeFrame] = [:]
    var items: [ExtraItem] = []

    let actorSlotW = max(72, chart.actors.map {
        ExtraText.width($0.label, size: 11, weight: 400) + 20
    }.max() ?? 72)
    var actorY = pad
    for actor in chart.actors {
        let fx = pad + (actorSlotW - figW) / 2
        let label = ExtraText.truncate(actor.label, size: 11, weight: 400, maxWidth: actorSlotW)
        // Stick figure: head, body, arms, legs (Pele FIGURE_W × FIGURE_H).
        items.append(.ellipse(
            x: fx + figW / 2 - 8, y: actorY, width: 16, height: 16,
            fill: .surface, stroke: .foreground))
        items.append(.line(
            x1: fx + figW / 2, y1: actorY + 16, x2: fx + figW / 2, y2: actorY + 40,
            stroke: .foreground, width: 1.5, dashed: false))
        items.append(.line(
            x1: fx + figW / 2 - 14, y1: actorY + 24, x2: fx + figW / 2 + 14, y2: actorY + 24,
            stroke: .foreground, width: 1.5, dashed: false))
        items.append(.line(
            x1: fx + figW / 2, y1: actorY + 40, x2: fx + figW / 2 - 9, y2: actorY + figH,
            stroke: .foreground, width: 1.5, dashed: false))
        items.append(.line(
            x1: fx + figW / 2, y1: actorY + 40, x2: fx + figW / 2 + 9, y2: actorY + figH,
            stroke: .foreground, width: 1.5, dashed: false))
        items.append(.text(label, x: fx + figW / 2, y: actorY + figH + 14,
                           size: 11, fill: .foreground, anchor: .middle, weight: 400))
        frames[actor.id] = NodeFrame(
            id: actor.id, isActor: true, rect: false,
            x: fx, y: actorY, w: figW, h: figH)
        actorY += figH + 24 + actorGap
    }

    let caseX = pad + actorSlotW + columnGap
    var caseY = pad
    // Boundary members stay grouped: order cases by (boundary, declaration).
    let memberBoundary: [String: Int] = Dictionary(
        chart.boundaries.enumerated().flatMap { bi, b in
            b.members.map { ($0, bi) }
        },
        uniquingKeysWith: { first, _ in first }
    )
    let declIndex = Dictionary(
        chart.cases.enumerated().map { ($1.id, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    let orderedCases = chart.cases.sorted {
        ((memberBoundary[$0.id] ?? Int.max), declIndex[$0.id] ?? 0)
            < ((memberBoundary[$1.id] ?? Int.max), declIndex[$1.id] ?? 0)
    }
    for uc in orderedCases {
        let w = max(96, ExtraText.width(uc.label, size: 12, weight: 400) + 40)
        let h = uc.shape == "rect" ? 38.0 : 46.0
        let label = ExtraText.truncate(uc.label, size: 12, weight: 400, maxWidth: w - 20)
        if uc.shape == "rect" {
            items.append(.rect(
                x: caseX, y: caseY, width: w, height: h,
                fill: .surface, stroke: .border, corner: 2, dashed: false))
        } else {
            items.append(.ellipse(
                x: caseX, y: caseY, width: w, height: h,
                fill: .surface, stroke: .border))
        }
        items.append(.text(label, x: caseX + w / 2, y: caseY + h / 2,
                           size: 12, fill: .foreground, anchor: .middle, weight: 400))
        frames[uc.id] = NodeFrame(
            id: uc.id, isActor: false, rect: uc.shape == "rect",
            x: caseX, y: caseY, w: w, h: h)
        caseY += h + caseGap
    }

    // Boundary boxes behind their members.
    for boundary in chart.boundaries {
        let boxes = boundary.members.compactMap { frames[$0] }
        guard !boxes.isEmpty else { continue }
        let bx = boxes.map(\.x).min()! - 18
        let by = boxes.map(\.y).min()! - 34
        let bx1 = boxes.map { $0.x + $0.w }.max()! + 18
        let by1 = boxes.map { $0.y + $0.h }.max()! + 16
        items.insert(.rect(
            x: bx, y: by, width: bx1 - bx, height: by1 - by,
            fill: .background, stroke: .muted, corner: 8, dashed: true), at: 0)
        items.append(.text(
            ExtraText.truncate(boundary.label, size: 11, weight: 600, maxWidth: bx1 - bx - 24),
            x: bx + 12, y: by + 18, size: 11, fill: .muted, anchor: .start, weight: 600))
    }

    func outlinePoint(_ f: NodeFrame, toward other: ExtraPoint) -> ExtraPoint {
        if f.isActor {
            // Lines meet an actor at its figure, not its label.
            let facingLeft = other.x < f.cx
            return ExtraPoint(x: facingLeft ? f.x : f.x + f.w, y: f.y + f.h * 0.45)
        }
        let dx = other.x - f.cx
        let dy = other.y - f.cy
        if dx == 0 && dy == 0 { return ExtraPoint(x: f.cx, y: f.cy) }
        if f.rect {
            let sx = dx == 0 ? Double.infinity : (f.w / 2) / abs(dx)
            let sy = dy == 0 ? Double.infinity : (f.h / 2) / abs(dy)
            let s = min(sx, sy)
            return ExtraPoint(x: f.cx + dx * s, y: f.cy + dy * s)
        }
        let s = 1 / sqrt((dx / (f.w / 2)) * (dx / (f.w / 2)) + (dy / (f.h / 2)) * (dy / (f.h / 2)))
        return ExtraPoint(x: f.cx + dx * s, y: f.cy + dy * s)
    }

    func arrowhead(_ tip: ExtraPoint, angle: Double, hollow: Bool) -> ExtraItem {
        let len = 10.0
        let half = 4.5
        let bx = tip.x - cos(angle) * len
        let by = tip.y - sin(angle) * len
        let px = -sin(angle) * half
        let py = cos(angle) * half
        return .polyline(
            points: [
                ExtraPoint(x: tip.x, y: tip.y),
                ExtraPoint(x: bx + px, y: by + py),
                ExtraPoint(x: bx - px, y: by - py),
            ],
            fill: hollow ? .background : .foreground, stroke: .foreground,
            width: 1.5, closed: true)
    }

    func marker(_ point: ExtraPoint, kind: String) {
        switch kind {
        case "arrow":
            break // Drawn by the caller, which knows the edge angle.
        case "circle":
            items.append(.ellipse(
                x: point.x - 4, y: point.y - 4, width: 8, height: 8,
                fill: .background, stroke: .foreground))
        case "cross":
            items.append(.line(
                x1: point.x - 4, y1: point.y - 4, x2: point.x + 4, y2: point.y + 4,
                stroke: .foreground, width: 1.5, dashed: false))
            items.append(.line(
                x1: point.x - 4, y1: point.y + 4, x2: point.x + 4, y2: point.y - 4,
                stroke: .foreground, width: 1.5, dashed: false))
        default:
            break
        }
    }

    // Parallel edges between the same pair spread apart so they never sit on
    // exactly the same line.
    var pairCount: [String: Int] = [:]
    for edge in chart.edges {
        pairCount["\(edge.from)\u{0}\(edge.to)", default: 0] += 1
    }
    var pairSeen: [String: Int] = [:]
    for edge in chart.edges {
        guard let a = frames[edge.from], let b = frames[edge.to] else { continue }
        let key = "\(edge.from)\u{0}\(edge.to)"
        let siblings = pairCount[key] ?? 1
        let slot = pairSeen[key, default: 0]
        pairSeen[key] = slot + 1
        let spread = (Double(slot) - Double(siblings - 1) / 2) * 6
        let pa = outlinePoint(a, toward: ExtraPoint(x: b.cx, y: b.cy))
        let pb = outlinePoint(b, toward: ExtraPoint(x: a.cx, y: a.cy))
        let dx = pb.x - pa.x
        let dy = pb.y - pa.y
        let len = max(1, sqrt(dx * dx + dy * dy))
        // Offset perpendicular to the edge direction.
        let ox = -dy / len * spread
        let oy = dx / len * spread
        let p1 = ExtraPoint(x: pa.x + ox, y: pa.y + oy)
        let p2 = ExtraPoint(x: pb.x + ox, y: pb.y + oy)
        let dashed = edge.kind == "include" || edge.kind == "extend"
        items.append(.line(
            x1: p1.x, y1: p1.y, x2: p2.x, y2: p2.y,
            stroke: .muted, width: 1.5, dashed: dashed))
        let angle = atan2(p2.y - p1.y, p2.x - p1.x)
        if edge.startMarker == "arrow" {
            items.append(arrowhead(p1, angle: angle + .pi, hollow: edge.kind == "generalization"))
        } else {
            marker(p1, kind: edge.startMarker)
        }
        if edge.endMarker == "arrow" {
            items.append(arrowhead(p2, angle: angle, hollow: edge.kind == "generalization"))
        } else {
            marker(p2, kind: edge.endMarker)
        }
        let caption = edge.label.isEmpty && dashed ? edge.kind : edge.label
        if !caption.isEmpty {
            items.append(.text(
                ExtraText.truncate(caption, size: 10, weight: 400, maxWidth: 170),
                x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2 - 8,
                size: 10, fill: .muted, anchor: .middle, weight: 400))
        }
    }

    var maxX = pad + 120.0
    let maxY = max(actorY, caseY) + pad
    for f in frames.values {
        maxX = max(maxX, f.x + f.w)
    }
    for item in items {
        switch item {
        case .text(_, let x, _, _, _, _, _): maxX = max(maxX, x + 40)
        default: break
        }
    }
    return ExtraScene(width: maxX + pad, height: max(maxY, 160), items: items)
}

func layoutIshikawa(_ chart: IshikawaChart) -> ExtraScene {
    var items: [ExtraItem] = []
    let causeStep = 16.0
    let labelGap = 26.0
    // Each bone gets a column wide enough for its own longest line, so
    // neighboring categories can never print over each other.
    struct BoneColumn { var name: String; var causes: [String]; var width: Double }
    let columns: [BoneColumn] = chart.bones.map { bone in
        var w = ExtraText.width(bone.name, size: 12, weight: 600) + 32
        for cause in bone.causes {
            w = max(w, ExtraText.width(cause, size: 10, weight: 400) + 24)
        }
        return BoneColumn(
            name: ExtraText.truncate(bone.name, size: 12, weight: 600, maxWidth: 260),
            causes: bone.causes,
            width: min(max(w, 110), 280)
        )
    }
    let gap = 24.0
    let leftPad = 24.0
    let spineGap = 28.0
    let effectW = min(max(ExtraText.width(chart.effect, size: 12, weight: 600) + 36, 90), 240)
    let bonesW = columns.map(\.width).reduce(0, +) + gap * Double(max(columns.count - 1, 0))
    // Vertical room: causes stack outward from each category label.
    func stackHeight(_ causes: [String]) -> Double {
        labelGap + Double(max(causes.count - 1, 0)) * causeStep + 22
    }
    var topNeed = 30.0
    var bottomNeed = 30.0
    for (i, col) in columns.enumerated() {
        if i % 2 == 0 {
            topNeed = max(topNeed, stackHeight(col.causes))
        } else {
            bottomNeed = max(bottomNeed, stackHeight(col.causes))
        }
    }
    let spineY = topNeed + 24
    let height = spineY + bottomNeed + 24
    let spineX0 = leftPad
    let spineX1 = leftPad + bonesW + spineGap
    items.append(.line(x1: spineX0, y1: spineY, x2: spineX1, y2: spineY, stroke: .foreground, width: 2.5, dashed: false))
    items.append(.rect(x: spineX1, y: spineY - 20, width: effectW, height: 40, fill: .accent, stroke: .border, corner: 4, dashed: false))
    items.append(.text(
        ExtraText.truncate(chart.effect, size: 12, weight: 600, maxWidth: effectW - 16),
        x: spineX1 + effectW / 2, y: spineY, size: 12, fill: .background, anchor: .middle, weight: 600
    ))
    var x = leftPad
    for (i, col) in columns.enumerated() {
        let cx = x + col.width / 2
        let up = i % 2 == 0
        let labelY = up ? spineY - stackHeight(col.causes) + 12 : spineY + stackHeight(col.causes) - 12
        items.append(.line(x1: cx - 14, y1: labelY, x2: cx + 18, y2: spineY, stroke: .muted, width: 1.5, dashed: false))
        items.append(.text(col.name, x: cx, y: labelY, size: 12, fill: .foreground, anchor: .middle, weight: 600))
        for (j, cause) in col.causes.enumerated() {
            let cy = labelY + (up ? 1 : -1) * (labelGap + Double(j) * causeStep)
            items.append(.text(
                ExtraText.truncate(cause, size: 10, weight: 400, maxWidth: col.width - 12),
                x: cx, y: cy, size: 10, fill: .muted, anchor: .middle, weight: 400
            ))
        }
        x += col.width + gap
    }
    return ExtraScene(width: spineX1 + effectW + 24, height: height, items: items)
}

func layoutCynefin(_ chart: CynefinChart) -> ExtraScene {
    let width = 460.0
    let header = titleItems(chart.title, width: width)
    var items = header.items
    let names = chart.domains.map(\.name)
    let rects = [
        CGRect(x: 30, y: header.top, width: 190, height: 140),
        CGRect(x: 230, y: header.top, width: 190, height: 140),
        CGRect(x: 30, y: header.top + 150, width: 190, height: 140),
        CGRect(x: 230, y: header.top + 150, width: 190, height: 140)
    ]
    for (i, rect) in rects.enumerated() {
        items.append(.rect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height, fill: .series(i), stroke: .border, corner: 8, dashed: false))
        let name = i < names.count ? names[i] : ""
        items.append(.text(name, x: rect.midX, y: rect.minY + 18, size: 13, fill: .foreground, anchor: .middle, weight: 600))
        let itemsIn = i < chart.domains.count ? chart.domains[i].items : []
        for (j, item) in itemsIn.prefix(5).enumerated() {
            items.append(.text(item, x: rect.minX + 12, y: rect.minY + 40 + Double(j) * 16, size: 11, fill: .foreground, anchor: .start, weight: 400))
        }
    }
    return ExtraScene(width: width, height: header.top + 310, items: items)
}

func layoutWardley(_ chart: WardleyChart) -> ExtraScene {
    let width = 520.0
    let header = titleItems(chart.title, width: width)
    var items = header.items
    let plot = CGRect(x: 50, y: header.top, width: 430, height: 280)
    items.append(.rect(x: plot.minX, y: plot.minY, width: plot.width, height: plot.height, fill: .surface, stroke: .border, corner: 0, dashed: false))
    items.append(.text("visible", x: 12, y: plot.minY + 10, size: 10, fill: .muted, anchor: .start, weight: 400))
    items.append(.text("invisible", x: 12, y: plot.maxY - 8, size: 10, fill: .muted, anchor: .start, weight: 400))
    items.append(.text("genesis → commodity", x: plot.midX, y: plot.maxY + 16, size: 10, fill: .muted, anchor: .middle, weight: 400))
    var pos: [String: ExtraPoint] = [:]
    for (i, component) in chart.components.enumerated() {
        let x = plot.minX + min(max(component.evolution, 0), 1) * plot.width
        let y = plot.maxY - min(max(component.visibility, 0), 1) * plot.height
        pos[component.name] = ExtraPoint(x: x, y: y)
        items.append(.ellipse(x: x - 6, y: y - 6, width: 12, height: 12, fill: .series(i), stroke: .border))
        items.append(.text(component.name, x: x + 8, y: y, size: 11, fill: .foreground, anchor: .start, weight: 400))
    }
    for edge in chart.edges {
        if let a = pos[edge.from], let b = pos[edge.to] {
            items.append(.line(x1: a.x, y1: a.y, x2: b.x, y2: b.y, stroke: .muted, width: 1, dashed: false))
        }
    }
    return ExtraScene(width: width, height: plot.maxY + 36, items: items)
}

func layoutEventModel(_ chart: EventModelChart) -> ExtraScene {
    var items: [ExtraItem] = []
    let nodeW = 132.0
    let nodeH = 46.0
    let stepX = 152.0
    let leftW = 160.0
    let rowH = 88.0
    let top = 28.0
    let lanes = chart.lanes.isEmpty
        ? [EventModelLane(name: "Lane", frames: chart.frames)]
        : chart.lanes
    var laneRow: [String: Int] = [:]
    for (i, lane) in lanes.enumerated() where laneRow[lane.name] == nil {
        laneRow[lane.name] = i
    }
    var pos: [String: ExtraPoint] = [:]
    for (seq, frame) in chart.frames.enumerated() {
        let row = laneRow[frame.lane] ?? 0
        let x = leftW + Double(seq) * stepX
        let y = top + Double(row) * rowH
        pos[frame.number] = ExtraPoint(x: x, y: y)
    }
    // Inferred timeline relations first (under the nodes). Reset frames
    // break the chain, matching Mermaid's `rf` semantics.
    for (seq, frame) in chart.frames.enumerated() {
        guard seq > 0, !frame.isReset else { continue }
        let prev = chart.frames[seq - 1]
        guard let a = pos[prev.number], let b = pos[frame.number] else { continue }
        items.append(.line(
            x1: a.x + nodeW, y1: a.y + nodeH / 2,
            x2: b.x, y2: b.y + nodeH / 2,
            stroke: .muted, width: 1.2, dashed: false
        ))
    }
    // Explicit `->>` relations as dashed edges.
    for frame in chart.frames {
        guard let a = pos[frame.number] else { continue }
        for ref in frame.refs {
            guard let b = pos[ref], ref != frame.number else { continue }
            items.append(.line(
                x1: a.x + nodeW / 2, y1: a.y + nodeH,
                x2: b.x + nodeW / 2, y2: b.y,
                stroke: .accent, width: 1.2, dashed: true
            ))
        }
    }
    for (i, lane) in lanes.enumerated() {
        let y = top + Double(i) * rowH
        items.append(.text(
            ExtraText.truncate(lane.name, size: 12, weight: 600, maxWidth: leftW - 20),
            x: 12, y: y + nodeH / 2, size: 12, fill: .foreground, anchor: .start, weight: 600
        ))
        let laneEnd = leftW + Double(max(chart.frames.count, 1)) * stepX
        items.append(.line(x1: leftW - 12, y1: y + nodeH / 2, x2: laneEnd, y2: y + nodeH / 2, stroke: .muted, width: 1, dashed: true))
    }
    for frame in chart.frames {
        guard let p = pos[frame.number] else { continue }
        items.append(.rect(x: p.x, y: p.y, width: nodeW, height: nodeH, fill: .surface, stroke: .border, corner: 6, dashed: false))
        if !frame.kind.isEmpty {
            items.append(.text(frame.kind, x: p.x + nodeW / 2, y: p.y + 12, size: 9, fill: .muted, anchor: .middle, weight: 600))
        }
        items.append(.text(
            ExtraText.truncate(frame.name, size: 11, weight: 500, maxWidth: nodeW - 12),
            x: p.x + nodeW / 2, y: p.y + (frame.kind.isEmpty ? nodeH / 2 : 30),
            size: 11, fill: .foreground, anchor: .middle, weight: 500
        ))
    }
    let width = leftW + Double(max(chart.frames.count, 1)) * stepX + 24
    let height = top + Double(max(lanes.count, 1)) * rowH + 12
    return ExtraScene(width: width, height: height, items: items)
}

func layoutInfo(_ chart: InfoChart) -> ExtraScene {
    let version = "Luna v\(MermaidRenderer.version)"
    let titleWidth = chart.title.map { ExtraText.width($0, size: 18, weight: 600) } ?? 0
    let versionWidth = ExtraText.width(version, size: 13)
    let width = max(240, max(titleWidth, versionWidth) + 64)
    let header = titleItems(chart.title, width: width)
    var items = header.items
    let y = header.top + 8
    items.append(.text(version, x: width / 2, y: y, size: 13, fill: .muted, anchor: .middle, weight: 400))
    return ExtraScene(width: width, height: y + 32, items: items)
}

/// Lays out railroad (syntax) diagrams: one ruled track per grammar rule
/// with pill terminals, box nonterminals, stacked choice branches, bypasses
/// and loops. Port of Pele's `src/diagrams/railroad/render.ts`; arcs draw as
/// sampled polylines (Luna has no curve items) and long-sequence folding is
/// skipped (Luna scenes size to content instead of a fixed width).
func layoutRailroad(_ chart: RailroadChart) -> ExtraScene {
    let size = 14.0
    let headSize = 16.0
    let padding = 12.0
    let boxH = 30.0
    let gap = 16.0
    let sep = 10.0
    let arc = 10.0
    let radius = 4.0
    let lead = 12.0
    let headGap = 6.0
    let ruleGap = 18.0
    let countSize = 12.0
    let arrowLen = 7.0
    let pad = 24.0
    let headHeight = 24.0

    enum BoxKind {
        case terminal
        case nonterminal
        case special
        case sequence
        case choice
        case bypass
        case loop
    }

    final class Box {
        var kind: BoxKind
        var width: Double
        var up: Double
        var down: Double
        var kids: [Box]
        var text: String
        var reach: Double
        init(
            kind: BoxKind, width: Double, up: Double, down: Double,
            kids: [Box] = [], text: String = "", reach: Double = 0
        ) {
            self.kind = kind
            self.width = width
            self.up = up
            self.down = down
            self.kids = kids
            self.text = text
            self.reach = reach
        }
    }

    func even(_ value: Double) -> Double {
        (value / 2).rounded(.up) * 2
    }

    func leaf(_ kind: BoxKind, _ text: String, mono: Bool) -> Box {
        let half = boxH / 2
        let measured = mono
            ? Double(text.count) * size * 0.6 + 2 * padding
            : ExtraText.width(text, size: size) + 2 * padding
        return Box(kind: kind, width: max(even(measured), boxH), up: half, down: half, text: text)
    }

    // Where the next branch of a choice sits below the baseline.
    func below(_ offset: Double, _ above: Box, _ branch: Box) -> Double {
        max(offset + above.down + sep + branch.up, 2 * arc)
    }

    func bypass(_ kid: Box) -> Box {
        let reach = max(kid.up + sep, 2 * arc)
        return Box(
            kind: .bypass, width: kid.width + 4 * arc, up: reach, down: kid.down,
            kids: [kid], reach: reach)
    }

    func measure(_ node: RailroadNode) -> Box {
        switch node {
        case .terminal(let value):
            return leaf(.terminal, railroadShown(value), mono: true)
        case .nonterminal(let name):
            return leaf(.nonterminal, railroadShown(name), mono: false)
        case .special(let text):
            return leaf(.special, "? \(railroadShown(text)) ?", mono: false)
        case .sequence(let elements):
            let kids = elements.map(measure)
            let width = Double(max(0, kids.count - 1)) * gap + kids.reduce(0) { $0 + $1.width }
            let up = kids.map(\.up).max() ?? 0
            let down = kids.map(\.down).max() ?? 0
            return Box(kind: .sequence, width: width, up: up, down: down, kids: kids)
        case .choice(let alternatives):
            let kids = alternatives.map(measure)
            var inner = 0.0
            var offset = 0.0
            for (i, kid) in kids.enumerated() {
                inner = max(inner, kid.width)
                if i > 0 { offset = below(offset, kids[i - 1], kid) }
            }
            return Box(
                kind: .choice, width: inner + 4 * arc,
                up: kids.first?.up ?? 0, down: kids.last.map { offset + $0.down } ?? 0,
                kids: kids)
        case .optional(let element):
            return bypass(measure(element))
        case .repetition(let element, let least, let most):
            let kid = measure(element)
            if least == 1, most == 1 { return kid }
            let text = railroadCount(min: least, max: most)
            let reach = Swift.max(kid.down + sep, 2 * arc)
            let label = text.isEmpty ? 0 : even(ExtraText.width(text, size: countSize) + 4)
            return Box(
                kind: .loop, width: Swift.max(kid.width, label) + 2 * arc, up: kid.up,
                down: reach + (text.isEmpty ? arrowLen / 2 + 1 : countSize + 6),
                kids: [kid], text: text, reach: reach)
        }
    }

    var items: [ExtraItem] = []
    // Track strokes: straight runs stay lines, quarter turns sample arcs.
    var trackLines: [ExtraItem] = []
    var trackCurves: [ExtraItem] = []
    var trackX = 0.0
    var trackY = 0.0
    var curvePts: [ExtraPoint] = []
    func trackFlush() {
        if curvePts.count > 1 {
            trackCurves.append(.polyline(
                points: curvePts, fill: .none, stroke: .foreground, width: 1.5, closed: false))
        }
        curvePts = []
    }
    func trackMove(_ x: Double, _ y: Double) {
        trackFlush()
        trackX = x
        trackY = y
    }
    func trackH(_ x2: Double) {
        // Like Pele's `line`, a run needs a positive length to draw.
        if x2 > trackX {
            trackFlush()
            trackLines.append(.line(
                x1: trackX, y1: trackY, x2: x2, y2: trackY,
                stroke: .foreground, width: 1.5, dashed: false))
            trackX = x2
        }
    }
    func trackV(_ y2: Double) {
        trackFlush()
        trackLines.append(.line(
            x1: trackX, y1: trackY, x2: trackX, y2: y2,
            stroke: .foreground, width: 1.5, dashed: false))
        trackY = y2
    }
    func trackArc(_ cx: Double, _ cy: Double, _ a0: Double, _ a1: Double) {
        if curvePts.isEmpty {
            curvePts.append(ExtraPoint(x: trackX, y: trackY))
        }
        for s in 1...5 {
            let a = a0 + (a1 - a0) * Double(s) / 5
            curvePts.append(ExtraPoint(x: cx + arc * cos(a), y: cy + arc * sin(a)))
        }
        if let last = curvePts.last {
            trackX = last.x
            trackY = last.y
        }
    }
    // Quarter turns from the current point, as in Pele's path fragments.
    func eastToSouth() { trackArc(trackX, trackY + arc, -.pi / 2, 0) }
    func southToEast() { trackArc(trackX + arc, trackY, .pi, .pi / 2) }
    func eastToNorth() { trackArc(trackX, trackY - arc, .pi / 2, 0) }
    func northToEast() { trackArc(trackX + arc, trackY, .pi, 3 * .pi / 2) }
    func loopDown() { trackArc(trackX - arc, trackY, 0, .pi / 2) }
    func loopUp() { trackArc(trackX - arc, trackY, 0, -.pi / 2) }

    func place(_ root: Box, _ left: Double, _ baseline: Double) {
        // One stack of (box, x, y) triples. Pele keeps two parallel arrays
        // and reverses its coordinate array element-wise, which swaps each
        // queued pair's x and y; stacking triples keeps every pair intact.
        var stack: [(box: Box, x: Double, y: Double)] = [(root, left, baseline)]
        func push(_ box: Box, _ x: Double, _ y: Double) {
            stack.append((box, x, y))
        }
        // Queued children reverse so the leftmost places first (Pele).
        func reverseFrom(_ from: Int) {
            var i = from
            var j = stack.count - 1
            while i < j {
                stack.swapAt(i, j)
                i += 1
                j -= 1
            }
        }
        while !stack.isEmpty {
            let (box, x, y) = stack.removeLast()
            let kids = box.kids
            let right = x + box.width
            switch box.kind {
            case .sequence:
                var kx = right
                for i in stride(from: kids.count - 1, through: 0, by: -1) {
                    kx -= kids[i].width
                    push(kids[i], kx, y)
                    if i > 0 {
                        trackMove(kx - gap, y)
                        trackH(kx)
                    }
                    kx -= gap
                }
            case .choice:
                let inner = box.width - 4 * arc
                let railIn = x + arc
                let railOut = right - arc
                let from = stack.count
                var offset = 0.0
                for (i, kid) in kids.enumerated() {
                    if i > 0 { offset = below(offset, kids[i - 1], kid) }
                    let ky = y + offset
                    let kx = x + 2 * arc + (inner - kid.width) / 2
                    let last = i == kids.count - 1
                    if i == 0 {
                        trackMove(x, y)
                        trackH(kx)
                        trackMove(kx + kid.width, y)
                        trackH(right)
                    } else {
                        if last {
                            trackMove(x, y)
                            eastToSouth()
                            trackV(ky - arc)
                        } else {
                            trackMove(railIn, ky - arc)
                        }
                        southToEast()
                        if kx > railIn + arc { trackH(kx) }
                        trackMove(kx + kid.width, ky)
                        if kx > railIn + arc { trackH(railOut - arc) }
                        eastToNorth()
                        if last {
                            trackV(y + arc)
                            northToEast()
                        }
                    }
                    push(kid, kx, ky)
                }
                reverseFrom(from)
            case .bypass:
                let kid = kids[0]
                let kx = x + 2 * arc
                trackMove(x, y)
                trackH(kx)
                trackMove(kx + kid.width, y)
                trackH(right)
                trackMove(x, y)
                eastToNorth()
                trackV(y - box.reach + arc)
                northToEast()
                trackH(right - 2 * arc)
                eastToSouth()
                trackV(y - arc)
                southToEast()
                push(kid, kx, y)
            case .loop:
                let kid = kids[0]
                let kx = x + (box.width - kid.width) / 2
                let loopY = y + box.reach
                let middle = x + box.width / 2
                trackMove(x, y)
                trackH(kx)
                trackMove(kx + kid.width, y)
                trackH(right)
                trackMove(x + arc, y)
                loopDown()
                trackV(loopY - arc)
                southToEast()
                trackH(right - arc)
                eastToNorth()
                trackV(y + arc)
                loopUp()
                items.append(.polyline(
                    points: [ExtraPoint(x: middle - arrowLen / 2, y: loopY),
                             ExtraPoint(x: middle + arrowLen / 2, y: loopY - arrowLen / 2),
                             ExtraPoint(x: middle + arrowLen / 2, y: loopY + arrowLen / 2)],
                    fill: .foreground, stroke: .foreground, width: 1, closed: true))
                if !box.text.isEmpty {
                    items.append(.text(
                        box.text, x: middle, y: loopY + countSize + 3, size: countSize,
                        fill: .muted, anchor: .middle, weight: 400))
                }
                push(kid, kx, y)
            case .terminal, .nonterminal, .special:
                let top = y - boxH / 2
                let labelY = y + size * 0.35
                switch box.kind {
                case .terminal:
                    items.append(.rect(
                        x: x, y: top, width: box.width, height: boxH,
                        fill: .surface, stroke: .border, corner: boxH / 2, dashed: false))
                    items.append(.text(
                        box.text, x: x + box.width / 2, y: labelY, size: size,
                        fill: .foreground, anchor: .middle, weight: 400))
                case .nonterminal:
                    items.append(.rect(
                        x: x, y: top, width: box.width, height: boxH,
                        fill: .background, stroke: .border, corner: 4, dashed: false))
                    items.append(.text(
                        box.text, x: x + box.width / 2, y: labelY, size: size,
                        fill: .foreground, anchor: .middle, weight: 400))
                default:
                    items.append(.rect(
                        x: x, y: top, width: box.width, height: boxH,
                        fill: .background, stroke: .border, corner: 4, dashed: true))
                    items.append(.text(
                        box.text, x: x + box.width / 2, y: labelY, size: size,
                        fill: .muted, anchor: .middle, weight: 400))
                }
            }
        }
        trackFlush()
    }

    // Measure first for the scene width, then place below the title.
    let measured = chart.rules.map { ($0.name, measure($0.definition)) }
    var width = 0.0
    for (name, box) in measured {
        width = max(
            width, pad + 2 * radius + lead + box.width + lead + 2 * radius - pad,
            ExtraText.width(name, size: headSize, weight: 700))
    }
    let sceneWidth = max(width + 2 * pad, 120)
    let header = titleItems(chart.title, width: sceneWidth)
    var ruleItems: [ExtraItem] = []
    var top = max(pad, header.top)
    var bottom = top
    for (name, box) in measured {
        let baseline = top + headHeight + headGap + box.up
        let start = pad + 2 * radius
        let left = start + lead
        let end = left + box.width + lead
        trackMove(start, baseline)
        trackH(left)
        trackMove(left + box.width, baseline)
        trackH(end)
        place(box, left, baseline)
        if radius > 0 {
            ruleItems.append(.ellipse(
                x: pad, y: baseline - radius, width: 2 * radius, height: 2 * radius,
                fill: .muted, stroke: .muted))
            ruleItems.append(.ellipse(
                x: end, y: baseline - radius, width: 2 * radius, height: 2 * radius,
                fill: .muted, stroke: .muted))
        }
        ruleItems.append(.text(
            name, x: pad, y: top + headHeight / 2 + headSize * 0.35, size: headSize,
            fill: .foreground, anchor: .start, weight: 600))
        bottom = baseline + box.down
        top = bottom + sep + ruleGap
    }
    trackFlush()
    return ExtraScene(
        width: sceneWidth,
        height: max(bottom + pad, 120),
        items: header.items + ruleItems + items + trackLines + trackCurves)
}

/// Text is literal here: control characters show as escape text, and an
/// all-blank terminal reads as visible blanks (Pele `shown`).
func railroadShown(_ text: String) -> String {
    if !text.isEmpty, text.allSatisfy({ $0 == " " }) {
        return String(repeating: "␣", count: text.count)
    }
    return text
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

/// Repetition counts read like Mermaid: `3×`, `≥2×`, `≤4×`, `2–4×`.
func railroadCount(min: Int, max: Int?) -> String {
    guard let max else {
        return min <= 1 ? "" : "≥\(min)×"
    }
    if min == max { return "\(min)×" }
    if min == 0 { return "≤\(max)×" }
    return "\(min)–\(max)×"
}
