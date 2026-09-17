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
    case .treeView(let chart): return layoutMindmap(MindmapChart(nodes: chart.nodes))
    case .ishikawa(let chart): return layoutIshikawa(chart)
    case .cynefin(let chart): return layoutCynefin(chart)
    case .wardley(let chart): return layoutWardley(chart)
    case .eventmodeling(let chart): return layoutEventModel(chart)
    case .railroad(let chart): return layoutRailroad(chart)
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

func layoutGitGraph(_ chart: GitGraphChart) -> ExtraScene {
    let branchIndex = Dictionary(uniqueKeysWithValues: chart.branches.enumerated().map { ($0.element, $0.offset) })
    let vertical = chart.direction == "TB" || chart.direction == "BT"
    let step = 56.0
    let lane = 48.0
    let pad = 40.0
    var items: [ExtraItem] = []
    if vertical {
        for commit in chart.commits {
            let laneI = Double(branchIndex[commit.branch] ?? 0)
            let x = pad + laneI * lane
            let y = pad + Double(commit.order) * step
            items.append(.ellipse(x: x - 8, y: y - 8, width: 16, height: 16, fill: .series(Int(laneI)), stroke: .border))
            items.append(.text(commit.message, x: x + 16, y: y, size: 11, fill: .foreground, anchor: .start, weight: 400))
        }
        for branch in chart.branches {
            let laneI = Double(branchIndex[branch] ?? 0)
            let x = pad + laneI * lane
            let ys = chart.commits.filter { $0.branch == branch }.map { pad + Double($0.order) * step }
            if let minY = ys.min(), let maxY = ys.max() {
                items.append(.line(x1: x, y1: minY, x2: x, y2: maxY, stroke: .series(Int(laneI)), width: 2, dashed: false))
            }
        }
        let width = pad * 2 + Double(max(chart.branches.count, 1)) * lane + 120
        let height = pad * 2 + Double(max(chart.commits.count, 1)) * step
        return ExtraScene(width: width, height: height, items: items)
    }
    for commit in chart.commits {
        let laneI = Double(branchIndex[commit.branch] ?? 0)
        let x = pad + Double(commit.order) * step
        let y = pad + laneI * lane
        items.append(.ellipse(x: x - 8, y: y - 8, width: 16, height: 16, fill: .series(Int(laneI)), stroke: .border))
        items.append(.text(commit.message, x: x, y: y + 18, size: 10, fill: .muted, anchor: .middle, weight: 400))
    }
    for branch in chart.branches {
        let laneI = Double(branchIndex[branch] ?? 0)
        let y = pad + laneI * lane
        items.append(.text(branch, x: 8, y: y, size: 11, fill: .foreground, anchor: .start, weight: 500))
        let xs = chart.commits.filter { $0.branch == branch }.map { pad + Double($0.order) * step }
        if let minX = xs.min(), let maxX = xs.max() {
            items.append(.line(x1: minX, y1: y, x2: maxX, y2: y, stroke: .series(Int(laneI)), width: 2, dashed: false))
        }
    }
    for merge in chart.merges {
        let fromY = pad + Double(branchIndex[merge.from] ?? 0) * lane
        let toY = pad + Double(branchIndex[merge.to] ?? 0) * lane
        let x = pad + Double(max(merge.at - 1, 0)) * step
        items.append(.line(x1: x, y1: fromY, x2: x + step, y2: toY, stroke: .accent, width: 1.5, dashed: false))
    }
    let width = pad * 2 + Double(max(chart.commits.count, 1)) * step
    let height = pad * 2 + Double(max(chart.branches.count, 1)) * lane
    return ExtraScene(width: width, height: height, items: items)
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

func layoutMindmap(_ chart: MindmapChart) -> ExtraScene {
    var items: [ExtraItem] = []
    let byParent = Dictionary(grouping: chart.nodes.filter { $0.parent != nil }, by: { $0.parent! })
    let nodeByID = Dictionary(uniqueKeysWithValues: chart.nodes.map { ($0.id, $0) })
    var positions: [Int: ExtraPoint] = [:]
    var leafY = 40.0
    func place(_ id: Int) -> ExtraPoint {
        if let existing = positions[id] { return existing }
        let children = byParent[id] ?? []
        let x = 40 + Double(nodeByID[id]?.depth ?? 0) * 160
        let y: Double
        if children.isEmpty {
            y = leafY
            leafY += 36
        } else {
            let childPts = children.map { place($0.id) }
            y = (childPts.map(\.y).min()! + childPts.map(\.y).max()!) / 2
        }
        let pt = ExtraPoint(x: x, y: y)
        positions[id] = pt
        return pt
    }
    for node in chart.nodes { _ = place(node.id) }
    for node in chart.nodes {
        guard let pt = positions[node.id] else { continue }
        let w = min(max(ExtraText.width(node.text) + 20, 60), 150)
        items.append(.rect(x: pt.x, y: pt.y - 12, width: w, height: 24, fill: node.depth == 0 ? .accent : .surface, stroke: .border, corner: 8, dashed: false))
        items.append(.text(node.text, x: pt.x + w / 2, y: pt.y, size: 12, fill: .foreground, anchor: .middle, weight: node.depth == 0 ? 600 : 400))
        if let parent = node.parent, let ppt = positions[parent] {
            let pw = min(max(ExtraText.width(nodeByID[parent]?.text ?? "") + 20, 60), 150)
            items.append(.line(x1: ppt.x + pw, y1: ppt.y, x2: pt.x, y2: pt.y, stroke: .muted, width: 1.2, dashed: false))
        }
    }
    let width = (positions.values.map(\.x).max() ?? 200) + 180
    let height = max(leafY + 20, 120)
    return ExtraScene(width: width, height: height, items: items)
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

func layoutSankey(_ chart: SankeyChart) -> ExtraScene {
    var values: [String: Double] = [:]
    for link in chart.links {
        values[link.source, default: 0] += link.value
        values[link.target, default: 0] += link.value
    }
    let sources = Set(chart.links.map(\.source))
    let targets = Set(chart.links.map(\.target))
    let left = sources.subtracting(targets)
    let right = targets.subtracting(sources)
    let middle = Set(values.keys).subtracting(left).subtracting(right)
    let columns = [Array(left).sorted(), Array(middle).sorted(), Array(right).sorted()].map { $0.isEmpty ? [" "] : $0 }
    let width = 560.0
    let height = 320.0
    var items: [ExtraItem] = []
    var nodeRect: [String: (x: Double, y: Double, h: Double)] = [:]
    for (ci, col) in columns.enumerated() {
        let x = 40 + Double(ci) * 200
        let total = col.map { values[$0] ?? 1 }.reduce(0, +)
        var y = 30.0
        for name in col {
            let h = max(18, ((values[name] ?? 1) / max(total, 1)) * 240)
            items.append(.rect(x: x, y: y, width: 16, height: h, fill: .series(ExtraText.seriesIndex(name)), stroke: .border, corner: 2, dashed: false))
            items.append(.text(name, x: x + 22, y: y + h / 2, size: 11, fill: .foreground, anchor: .start, weight: 400))
            nodeRect[name] = (x, y, h)
            y += h + 12
        }
    }
    for (i, link) in chart.links.enumerated() {
        guard let s = nodeRect[link.source], let t = nodeRect[link.target] else { continue }
        items.append(.line(x1: s.x + 16, y1: s.y + s.h / 2, x2: t.x, y2: t.y + t.h / 2, stroke: .series(i % 6), width: max(2, link.value), dashed: false))
    }
    return ExtraScene(width: width, height: height, items: items)
}

func layoutRadar(_ chart: RadarChart) -> ExtraScene {
    let width = 420.0
    let header = titleItems(chart.title, width: width)
    var items = header.items
    let cx = 210.0
    let cy = header.top + 140
    let radius = 110.0
    let n = max(chart.axes.count, 3)
    for ring in 1...4 {
        var pts: [ExtraPoint] = []
        for i in 0..<n {
            let a = -Double.pi / 2 + Double(i) / Double(n) * 2 * Double.pi
            let r = radius * Double(ring) / 4
            pts.append(ExtraPoint(x: cx + cos(a) * r, y: cy + sin(a) * r))
        }
        items.append(.polyline(points: pts, fill: .none, stroke: .muted, width: 1, closed: true))
    }
    for (i, axis) in chart.axes.enumerated() {
        let a = -Double.pi / 2 + Double(i) / Double(n) * 2 * Double.pi
        items.append(.line(x1: cx, y1: cy, x2: cx + cos(a) * radius, y2: cy + sin(a) * radius, stroke: .border, width: 1, dashed: false))
        items.append(.text(axis, x: cx + cos(a) * (radius + 18), y: cy + sin(a) * (radius + 18), size: 11, fill: .foreground, anchor: .middle, weight: 400))
    }
    let maxV = max(chart.series.flatMap(\.values).max() ?? 1, 1)
    for (si, series) in chart.series.enumerated() {
        var pts: [ExtraPoint] = []
        for i in 0..<n {
            let value = i < series.values.count ? series.values[i] : 0
            let a = -Double.pi / 2 + Double(i) / Double(n) * 2 * Double.pi
            let r = radius * (value / maxV)
            pts.append(ExtraPoint(x: cx + cos(a) * r, y: cy + sin(a) * r))
        }
        items.append(.polyline(points: pts, fill: .none, stroke: .series(si), width: 2, closed: true))
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
        items.append(.ellipse(x: c.0 - 80, y: c.1 - 80, width: 160, height: 160, fill: .series(i), stroke: .border))
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

func layoutBlock(_ chart: BlockChart) -> ExtraScene {
    let cellW = 120.0
    let cellH = 56.0
    var items: [ExtraItem] = []
    let rows = (chart.cells.map(\.row).max() ?? 0) + 1
    for cell in chart.cells {
        let x = 20 + Double(cell.column) * (cellW + 12)
        let y = 20 + Double(cell.row) * (cellH + 12)
        items.append(.rect(x: x, y: y, width: cellW, height: cellH, fill: .surface, stroke: .border, corner: 8, dashed: false))
        items.append(.text(cell.label, x: x + cellW / 2, y: y + cellH / 2, size: 13, fill: .foreground, anchor: .middle, weight: 500))
    }
    let width = 40 + Double(max(chart.columns, 1)) * (cellW + 12)
    let height = 40 + Double(max(rows, 1)) * (cellH + 12)
    return ExtraScene(width: width, height: height, items: items)
}

func layoutBoxes(_ boxes: [NamedBox], edges: [NamedEdge], title: String) -> ExtraScene {
    let colW = 180.0
    let rowH = 70.0
    var items: [ExtraItem] = titleItems(title, width: max(Double(boxes.count) * 100, 320)).items
    var pos: [String: ExtraPoint] = [:]
    for (i, box) in boxes.enumerated() {
        let x = 24 + Double(i % 3) * colW
        let y = 50 + Double(i / 3) * rowH
        pos[box.id] = ExtraPoint(x: x, y: y)
        items.append(.rect(x: x, y: y, width: 160, height: 52, fill: .surface, stroke: .border, corner: 6, dashed: false))
        items.append(.text(box.label, x: x + 80, y: y + 20, size: 12, fill: .foreground, anchor: .middle, weight: 600))
        if !box.detail.isEmpty {
            items.append(.text(box.detail, x: x + 80, y: y + 38, size: 10, fill: .muted, anchor: .middle, weight: 400))
        }
    }
    for edge in edges {
        guard let a = pos[edge.from], let b = pos[edge.to] else { continue }
        items.append(.line(x1: a.x + 80, y1: a.y + 52, x2: b.x + 80, y2: b.y, stroke: .accent, width: 1.2, dashed: false))
        if !edge.label.isEmpty {
            items.append(.text(edge.label, x: (a.x + b.x) / 2 + 80, y: (a.y + b.y) / 2 + 26, size: 10, fill: .muted, anchor: .middle, weight: 400))
        }
    }
    let rows = max((boxes.count + 2) / 3, 1)
    return ExtraScene(width: 40 + 3 * colW, height: 70 + Double(rows) * rowH, items: items)
}

func layoutArchitecture(_ chart: ArchitectureChart) -> ExtraScene {
    var boxes = chart.groups + chart.services
    if boxes.isEmpty { boxes = [NamedBox(id: "svc", label: "service", detail: "", group: nil)] }
    return layoutBoxes(boxes, edges: chart.edges, title: "Architecture")
}

func layoutC4(_ chart: C4Chart) -> ExtraScene {
    layoutBoxes(chart.boxes, edges: chart.edges, title: chart.title ?? chart.kind)
}

func layoutKanban(_ chart: KanbanChart) -> ExtraScene {
    let colW = 160.0
    let header = titleItems(chart.title, width: Double(max(chart.columns.count, 1)) * (colW + 16) + 32)
    var items = header.items
    var maxY = header.top
    for (i, column) in chart.columns.enumerated() {
        let x = 16 + Double(i) * (colW + 16)
        items.append(.rect(x: x, y: header.top, width: colW, height: 28, fill: .accent, stroke: .border, corner: 6, dashed: false))
        items.append(.text(column.name, x: x + colW / 2, y: header.top + 14, size: 12, fill: .background, anchor: .middle, weight: 600))
        for (j, card) in column.cards.enumerated() {
            let y = header.top + 40 + Double(j) * 44
            items.append(.rect(x: x, y: y, width: colW, height: 36, fill: .surface, stroke: .border, corner: 6, dashed: false))
            items.append(.text(card, x: x + 10, y: y + 18, size: 12, fill: .foreground, anchor: .start, weight: 400))
            maxY = max(maxY, y + 44)
        }
        maxY = max(maxY, header.top + 40)
    }
    return ExtraScene(width: 32 + Double(max(chart.columns.count, 1)) * (colW + 16), height: maxY + 16, items: items)
}

func layoutUseCase(_ chart: UseCaseChart) -> ExtraScene {
    var items: [ExtraItem] = []
    for (i, actor) in chart.actors.enumerated() {
        let y = 40 + Double(i) * 70
        items.append(.ellipse(x: 36, y: y, width: 24, height: 24, fill: .surface, stroke: .border))
        items.append(.line(x1: 48, y1: y + 24, x2: 48, y2: y + 48, stroke: .foreground, width: 1.5, dashed: false))
        items.append(.text(actor.label, x: 48, y: y + 58, size: 11, fill: .foreground, anchor: .middle, weight: 400))
    }
    for (i, uc) in chart.cases.enumerated() {
        let y = 40 + Double(i) * 56
        items.append(.ellipse(x: 180, y: y, width: 160, height: 40, fill: .surface, stroke: .border))
        items.append(.text(uc.label, x: 260, y: y + 20, size: 12, fill: .foreground, anchor: .middle, weight: 400))
    }
    for edge in chart.edges {
        items.append(.line(x1: 70, y1: 70, x2: 180, y2: 60, stroke: .muted, width: 1, dashed: false))
        if !edge.label.isEmpty {
            items.append(.text(edge.label, x: 120, y: 50, size: 10, fill: .muted, anchor: .middle, weight: 400))
        }
    }
    let height = max(40 + Double(max(chart.actors.count, chart.cases.count)) * 70, 160)
    return ExtraScene(width: 380, height: height, items: items)
}

func layoutIshikawa(_ chart: IshikawaChart) -> ExtraScene {
    var items: [ExtraItem] = []
    let y = 160.0
    items.append(.line(x1: 40, y1: y, x2: 480, y2: y, stroke: .foreground, width: 2.5, dashed: false))
    items.append(.rect(x: 480, y: y - 18, width: 90, height: 36, fill: .accent, stroke: .border, corner: 4, dashed: false))
    items.append(.text(chart.effect, x: 525, y: y, size: 12, fill: .background, anchor: .middle, weight: 600))
    let spacing = 420.0 / Double(max(chart.bones.count, 1))
    for (i, bone) in chart.bones.enumerated() {
        let x = 60 + Double(i) * spacing
        let up = i % 2 == 0
        let by = up ? 70.0 : 250.0
        items.append(.line(x1: x, y1: by, x2: x + 40, y2: y, stroke: .muted, width: 1.5, dashed: false))
        items.append(.text(bone.name, x: x, y: by, size: 12, fill: .foreground, anchor: .middle, weight: 600))
        for (j, cause) in bone.causes.enumerated() {
            items.append(.text(cause, x: x + 8, y: by + (up ? -18 : 18) - Double(j) * 14, size: 10, fill: .muted, anchor: .start, weight: 400))
        }
    }
    return ExtraScene(width: 590, height: 320, items: items)
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
    let rowH = 64.0
    for (i, lane) in chart.lanes.enumerated() {
        let y = 24 + Double(i) * rowH
        items.append(.text(lane.name, x: 12, y: y + 24, size: 12, fill: .foreground, anchor: .start, weight: 600))
        items.append(.line(x1: 90, y1: y + 24, x2: 90 + Double(max(lane.events.count, 1)) * 110, y2: y + 24, stroke: .muted, width: 1, dashed: true))
        for (j, event) in lane.events.enumerated() {
            let x = 100 + Double(j) * 110
            items.append(.rect(x: x, y: y + 8, width: 96, height: 32, fill: .surface, stroke: .border, corner: 6, dashed: false))
            items.append(.text(event, x: x + 48, y: y + 24, size: 11, fill: .foreground, anchor: .middle, weight: 400))
        }
    }
    let width = 120 + Double((chart.lanes.map { $0.events.count }.max() ?? 1)) * 110
    let height = 24 + Double(max(chart.lanes.count, 1)) * rowH
    return ExtraScene(width: width, height: height, items: items)
}

func layoutRailroad(_ chart: RailroadChart) -> ExtraScene {
    let header = titleItems(chart.title, width: 80 + Double(chart.terms.count) * 90)
    var items = header.items
    var x = 24.0
    let y = header.top + 24
    items.append(.line(x1: x, y1: y, x2: x + Double(chart.terms.count) * 90, y2: y, stroke: .muted, width: 2, dashed: false))
    for term in chart.terms {
        items.append(.rect(x: x, y: y - 16, width: 80, height: 32, fill: .surface, stroke: .border, corner: 16, dashed: false))
        items.append(.text(term, x: x + 40, y: y, size: 12, fill: .foreground, anchor: .middle, weight: 500))
        x += 90
    }
    return ExtraScene(width: x + 24, height: y + 40, items: items)
}
