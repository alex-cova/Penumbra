import Foundation

func parseExtra(kind: DiagramKind, lines: [String], source: String) throws -> ExtraParsed {
    switch kind {
    case .pie: return .pie(parsePieChart(lines))
    case .gantt: return .gantt(parseGanttChart(lines))
    case .gitGraph: return .gitGraph(parseGitGraph(lines))
    case .journey: return .journey(parseJourney(lines))
    case .mindmap: return .mindmap(parseMindmap(source))
    case .timeline: return .timeline(parseTimeline(lines))
    case .quadrantChart: return .quadrant(parseQuadrant(lines))
    case .sankey: return .sankey(parseSankey(lines))
    case .radar: return .radar(parseRadar(lines))
    case .treemap: return .treemap(parseTreemap(source))
    case .venn: return .venn(parseVenn(lines))
    case .packet: return .packet(parsePacket(lines))
    case .block: return .block(parseBlock(lines))
    case .requirement: return .requirement(parseRequirement(lines))
    case .architecture: return .architecture(parseArchitecture(lines))
    case .c4: return .c4(parseC4(lines))
    case .kanban: return .kanban(parseKanban(source))
    case .usecase: return .usecase(parseUseCase(lines))
    case .treeView: return .treeView(TreeViewChart(nodes: parseMindmap(source).nodes))
    case .ishikawa: return .ishikawa(parseIshikawa(lines))
    case .cynefin: return .cynefin(parseCynefin(lines))
    case .wardley: return .wardley(parseWardley(lines))
    case .eventmodeling: return .eventmodeling(parseEventModel(lines))
    case .railroad: return .railroad(parseRailroad(lines))
    default:
        throw MermaidParserError.unsupportedDiagram(kind.rawValue)
    }
}

func rewriteAgentflowAsFlowchart(_ source: String) -> String {
    var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if let index = lines.firstIndex(where: {
        let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("agentflow")
    }) {
        let rest = lines[index]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop { !$0.isWhitespace }
            .trimmingCharacters(in: .whitespaces)
        if rest.isEmpty {
            lines[index] = "flowchart TD"
        } else {
            lines[index] = "flowchart \(rest)"
        }
    }
    return lines.joined(separator: "\n")
}

// MARK: - Pie

func parsePieChart(_ lines: [String]) -> PieChart {
    var title: String?
    var showData = false
    var slices: [PieSlice] = []
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("pie") {
            if lower.contains("showdata") { showData = true }
            if let range = line.range(of: #"title\s+(.+)$"#, options: [.regularExpression, .caseInsensitive]) {
                var rest = String(line[range])
                rest = rest.replacingOccurrences(of: #"^title\s+"#, with: "", options: .regularExpression)
                title = ExtraText.unquote(rest)
            }
            continue
        }
        if lower.hasPrefix("title ") {
            title = ExtraText.unquote(String(line.dropFirst(6)))
            continue
        }
        if let colon = line.lastIndex(of: ":") {
            let label = ExtraText.unquote(String(line[..<colon]))
            let value = Double(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)) ?? 0
            if !label.isEmpty {
                slices.append(PieSlice(label: label, value: value))
            }
        }
    }
    return PieChart(title: title, showData: showData, slices: slices)
}

// MARK: - Gantt

func parseGanttChart(_ lines: [String]) -> GanttChart {
    var title: String?
    var section = "Tasks"
    var tasks: [GanttTask] = []
    let markers: [Double] = []
    var nextStart: Double = 0
    var ids: [String: (start: Double, duration: Double)] = [:]

    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("gantt") || lower.hasPrefix("dateformat") || lower.hasPrefix("axisformat") {
            continue
        }
        if lower.hasPrefix("title ") {
            title = ExtraText.unquote(String(line.dropFirst(6)))
            continue
        }
        if lower.hasPrefix("section ") {
            section = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            continue
        }
        if lower.hasPrefix("vert ") || lower.hasPrefix("milestone ") {
            continue
        }
        guard let colon = line.lastIndex(of: ":") else { continue }
        let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let spec = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var taskID = "t\(tasks.count)"
        var start = nextStart
        var duration = 3.0
        let milestone = spec.lowercased().contains("milestone")
        var usedAfter = false

        for part in parts {
            let p = part.trimmingCharacters(in: .whitespaces)
            let pl = p.lowercased()
            if pl == "milestone" || pl == "done" || pl == "active" || pl == "crit" { continue }
            if pl.hasPrefix("after ") {
                let ref = String(p.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if let prior = ids[ref] {
                    start = prior.start + prior.duration
                    usedAfter = true
                }
                continue
            }
            if let days = parseDurationDays(p) {
                duration = days
                continue
            }
            if let day = parseDayOffset(p) {
                start = day
                continue
            }
            if !p.isEmpty && !p.contains(" ") && ids[p] == nil && !p.contains("-") {
                taskID = p
            }
        }
        if milestone { duration = 0 }
        if !usedAfter { nextStart = max(nextStart, start + max(duration, 1)) }
        ids[taskID] = (start, max(duration, milestone ? 0.4 : 1))
        tasks.append(GanttTask(
            name: name,
            id: taskID,
            startDay: start,
            durationDays: max(duration, milestone ? 0.4 : 1),
            section: section,
            milestone: milestone
        ))
    }
    return GanttChart(title: title, tasks: tasks, markers: markers)
}

private func parseDurationDays(_ token: String) -> Double? {
    let t = token.lowercased()
    guard let match = t.range(of: #"^(\d+(?:\.\d+)?)([dwh])$"#, options: .regularExpression) else { return nil }
    let body = String(t[match])
    guard let idx = body.firstIndex(where: { $0.isLetter }) else { return nil }
    let value = Double(body[..<idx]) ?? 0
    switch body[idx] {
    case "w": return value * 7
    case "h": return value / 24
    default: return value
    }
}

private func parseDayOffset(_ token: String) -> Double? {
    let t = token.trimmingCharacters(in: .whitespaces)
    let parts = t.split(separator: "-")
    guard parts.count == 3,
          let y = Double(parts[0]),
          let m = Double(parts[1]),
          let d = Double(parts[2])
    else { return nil }
    return y * 365 + m * 30 + d
}

// MARK: - Git graph

/// Extracts `key: value` attributes from a gitGraph command line, e.g.
/// `commit id: "Alpha" tag: "v1.0" type: HIGHLIGHT`. Values may be double- or
/// single-quoted (kept whole, colons and all) or a single bare token.
private func gitAttributes(_ line: String) -> [String: String] {
    guard let regex = try? NSRegularExpression(pattern: #"([A-Za-z_-]+)\s*:\s*("[^"]*"|'[^']*'|\S+)"#) else {
        return [:]
    }
    let ns = line as NSString
    var result: [String: String] = [:]
    regex.enumerateMatches(in: line, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
        guard let match, match.numberOfRanges == 3 else { return }
        let key = ns.substring(with: match.range(at: 1)).lowercased()
        let value = ExtraText.unquote(ns.substring(with: match.range(at: 2)))
        result[key] = value
    }
    return result
}

func parseGitGraph(_ lines: [String]) -> GitGraphChart {
    var direction = "LR"
    var current = "main"
    var branchOrder = ["main"]
    var branchInfo: [String: GitBranchInfo] = ["main": GitBranchInfo(name: "main")]
    var heads: [String: String] = [:]
    var commits: [GitCommit] = []
    var order = 0

    func ensureBranch(_ name: String, forkParent: String?) {
        guard branchInfo[name] == nil else { return }
        branchOrder.append(name)
        branchInfo[name] = GitBranchInfo(name: name, forkParent: forkParent)
    }

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("gitgraph") {
            if let range = lower.range(of: #"\b(lr|tb|bt)\b"#, options: .regularExpression) {
                direction = lower[range].uppercased()
            }
            continue
        }
        if lower.hasPrefix("commit") {
            let attrs = gitAttributes(trimmed)
            let id = attrs["id"] ?? "c\(order)"
            let kind: GitCommitKind
            switch attrs["type"]?.uppercased() {
            case "REVERSE": kind = .reverse
            case "HIGHLIGHT": kind = .highlight
            default: kind = .normal
            }
            let parent = heads[current]
            commits.append(GitCommit(
                id: id,
                label: attrs["id"] ?? attrs["msg"],
                tag: attrs["tag"],
                kind: kind,
                branch: current,
                order: order,
                parents: parent.map { [$0] } ?? []
            ))
            heads[current] = id
            order += 1
            continue
        }
        if lower.hasPrefix("branch ") {
            let attrs = gitAttributes(trimmed)
            let name = ExtraText.unquote(String(trimmed.dropFirst(7)).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "branch")
            if branchInfo[name] == nil {
                branchOrder.append(name)
                let explicitOrder = attrs["order"].flatMap { Int($0) }
                branchInfo[name] = GitBranchInfo(name: name, order: explicitOrder, forkParent: heads[current])
            }
            heads[name] = heads[current]
            current = name
            continue
        }
        if lower.hasPrefix("checkout ") || lower.hasPrefix("switch ") {
            let name = ExtraText.unquote(String(trimmed.split(whereSeparator: { $0.isWhitespace }).dropFirst().first.map(String.init) ?? current))
            ensureBranch(name, forkParent: heads[current])
            current = name
            continue
        }
        if lower.hasPrefix("merge ") {
            let attrs = gitAttributes(trimmed)
            let sourceBranch = ExtraText.unquote(String(trimmed.dropFirst(6)).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? current)
            let id = attrs["id"] ?? "m\(order)"
            let primary = heads[current]
            let merged = heads[sourceBranch]
            var parents: [String] = []
            if let primary { parents.append(primary) }
            if let merged, merged != primary { parents.append(merged) }
            commits.append(GitCommit(
                id: id,
                label: attrs["id"] ?? attrs["msg"],
                tag: attrs["tag"],
                kind: .merge,
                branch: current,
                order: order,
                parents: parents
            ))
            heads[current] = id
            order += 1
            continue
        }
        if lower.hasPrefix("cherry-pick") {
            let attrs = gitAttributes(trimmed)
            let id = "p\(order)"
            let parent = heads[current]
            commits.append(GitCommit(
                id: id,
                label: attrs["id"],
                kind: .cherryPick,
                branch: current,
                order: order,
                parents: parent.map { [$0] } ?? [],
                cherryPickSource: attrs["id"]
            ))
            heads[current] = id
            order += 1
        }
    }
    if commits.isEmpty {
        commits.append(GitCommit(id: "c0", label: nil, branch: "main", order: 0, parents: []))
    }
    let branches = branchOrder.compactMap { branchInfo[$0] }
    return GitGraphChart(direction: direction, commits: commits, branches: branches)
}

// MARK: - Journey

func parseJourney(_ lines: [String]) -> JourneyChart {
    var title: String?
    var section = "Journey"
    var tasks: [JourneyTask] = []
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("journey") { continue }
        if lower.hasPrefix("title ") {
            title = ExtraText.unquote(String(line.dropFirst(6)))
            continue
        }
        if lower.hasPrefix("section ") {
            section = String(line.dropFirst(8))
            continue
        }
        if let colon = line.lastIndex(of: ":") {
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: colon)...].split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            let score = Int(rest.first ?? "3") ?? 3
            let actors = rest.dropFirst().joined(separator: ",").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            tasks.append(JourneyTask(section: section, name: name, score: score, actors: actors))
        }
    }
    return JourneyChart(title: title, tasks: tasks)
}

// MARK: - Mindmap / tree (indent)

func parseMindmap(_ source: String) -> MindmapChart {
    var nodes: [MindmapNode] = []
    var stack: [(indent: Int, id: Int)] = []
    var nextID = 0
    let raw = DiagramKindDetector.stripFrontmatter(source)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    for rawLine in raw {
        if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("%%") { continue }
        let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.reduce(0) { acc, ch in acc + (ch == "\t" ? 4 : 1) }
        var text = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        let lower = text.lowercased()
        if lower.hasPrefix("mindmap") || lower.hasPrefix("treeview") { continue }
        text = stripMindmapShape(text)
        while let last = stack.last, last.indent >= indent {
            stack.removeLast()
        }
        let parent = stack.last?.id
        nodes.append(MindmapNode(id: nextID, text: text, parent: parent, depth: stack.count))
        stack.append((indent, nextID))
        nextID += 1
    }
    if nodes.isEmpty {
        nodes.append(MindmapNode(id: 0, text: "root", parent: nil, depth: 0))
    }
    return MindmapChart(nodes: nodes)
}

private func stripMindmapShape(_ text: String) -> String {
    var t = text
    let patterns = [#"^\(\((.+)\)\)$"#, #"^\[\[(.+)\]\]$"#, #"^\[(.+)\]$"#, #"^\((.+)\)$"#, #"^\{\{(.+)\}\}$"#, #"^\{(.+)\}$"#]
    for pattern in patterns {
        if let match = t.range(of: pattern, options: .regularExpression) {
            t = String(t[match])
            t = t.replacingOccurrences(of: #"^\(+|\)+$|^\[+|\]+$|^\{+|\}$+"#, with: "", options: .regularExpression)
            break
        }
    }
    return ExtraText.unquote(t)
}

// MARK: - Timeline

func parseTimeline(_ lines: [String]) -> TimelineChart {
    var title: String?
    var section: String?
    var period = "Now"
    var entries: [TimelineEvent] = []
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("timeline") { continue }
        if lower.hasPrefix("title ") {
            title = ExtraText.unquote(String(line.dropFirst(6)))
            continue
        }
        if lower.hasPrefix("section ") {
            section = String(line.dropFirst(8))
            continue
        }
        if line.hasPrefix(":") {
            if entries.isEmpty {
                entries.append(TimelineEvent(period: period, events: [String(line.dropFirst()).trimmingCharacters(in: .whitespaces)], section: section))
            } else {
                entries[entries.count - 1].events.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            }
            continue
        }
        period = ExtraText.unquote(line)
        entries.append(TimelineEvent(period: period, events: [], section: section))
    }
    return TimelineChart(title: title, entries: entries)
}

// MARK: - Quadrant

func parseQuadrant(_ lines: [String]) -> QuadrantChart {
    var title: String?
    var xLeft = "low", xRight = "high", yBottom = "low", yTop = "high"
    var points: [QuadrantPoint] = []
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("quadrantchart") { continue }
        if lower.hasPrefix("title ") { title = ExtraText.unquote(String(line.dropFirst(6))); continue }
        if lower.hasPrefix("x-axis ") {
            let parts = String(line.dropFirst(7)).components(separatedBy: "-->")
            if parts.count == 2 {
                xLeft = ExtraText.unquote(parts[0])
                xRight = ExtraText.unquote(parts[1])
            }
            continue
        }
        if lower.hasPrefix("y-axis ") {
            let parts = String(line.dropFirst(7)).components(separatedBy: "-->")
            if parts.count == 2 {
                yBottom = ExtraText.unquote(parts[0])
                yTop = ExtraText.unquote(parts[1])
            }
            continue
        }
        if let colon = line.lastIndex(of: ":") {
            let label = ExtraText.unquote(String(line[..<colon]))
            let rest = line[line.index(after: colon)...]
                .replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "")
            let nums = rest
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .compactMap { Double($0) }
            if nums.count >= 2 {
                points.append(QuadrantPoint(label: label, x: nums[0], y: nums[1]))
            }
        }
    }
    return QuadrantChart(title: title, xLeft: xLeft, xRight: xRight, yBottom: yBottom, yTop: yTop, points: points)
}

// MARK: - Sankey

func parseSankey(_ lines: [String]) -> SankeyChart {
    var links: [SankeyLink] = []
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("sankey") { continue }
        let parts = line.split(separator: ",", omittingEmptySubsequences: false).map { ExtraText.unquote(String($0)) }
        if parts.count >= 3, let value = Double(parts.last ?? "") {
            links.append(SankeyLink(source: parts[0], target: parts[1], value: value))
        }
    }
    return SankeyChart(links: links)
}

// MARK: - Radar

func parseRadar(_ lines: [String]) -> RadarChart {
    var title: String?
    var axes: [String] = []
    var series: [RadarSeries] = []
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("radar") { continue }
        if lower.hasPrefix("title ") { title = ExtraText.unquote(String(line.dropFirst(6))); continue }
        if let match = line.range(of: #"^axis\s+\[([^\]]+)\]"#, options: [.regularExpression, .caseInsensitive]) {
            let inner = String(line[match])
            if let start = inner.firstIndex(of: "["), let end = inner.firstIndex(of: "]") {
                axes = inner[inner.index(after: start)..<end]
                    .split(separator: ",")
                    .map { ExtraText.unquote(String($0)) }
            }
            continue
        }
        if lower.hasPrefix("curve ") || lower.hasPrefix("series ") {
            var name = "series"
            var rest = line
            if let quote = line.range(of: "\"") {
                let after = line[quote.upperBound...]
                if let end = after.firstIndex(of: "\"") {
                    name = String(after[..<end])
                    rest = String(line[line.index(after: end)...])
                }
            }
            if let start = rest.firstIndex(of: "["), let end = rest.firstIndex(of: "]") {
                let values = rest[rest.index(after: start)..<end]
                    .split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                series.append(RadarSeries(name: name, values: values))
            }
        }
    }
    if axes.isEmpty {
        axes = (series.first?.values ?? [1, 1, 1]).enumerated().map { "A\($0.offset + 1)" }
    }
    return RadarChart(title: title, axes: axes, series: series)
}

// MARK: - Treemap

func parseTreemap(_ source: String) -> TreemapChart {
    var title: String?
    struct Item { var indent: Int; var name: String; var value: Double? }
    var items: [Item] = []
    let raw = DiagramKindDetector.stripFrontmatter(source)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    for rawLine in raw {
        let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        var text = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.hasPrefix("%%") { continue }
        let lower = text.lowercased()
        if lower.hasPrefix("treemap") { continue }
        if lower.hasPrefix("title ") {
            title = ExtraText.unquote(String(text.dropFirst(6)))
            continue
        }
        var value: Double?
        if let colon = text.lastIndex(of: ":") {
            value = Double(text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            text = ExtraText.unquote(String(text[..<colon]))
        } else {
            text = ExtraText.unquote(text)
        }
        items.append(Item(indent: indent, name: text, value: value))
    }
    func build(_ start: Int, _ minIndent: Int) -> (TreemapNode, Int) {
        let item = items[start]
        var children: [TreemapNode] = []
        var i = start + 1
        while i < items.count, items[i].indent > minIndent {
            let (child, next) = build(i, items[i].indent)
            children.append(child)
            i = next
        }
        let value = item.value ?? children.reduce(0) { $0 + $1.value }
        return (TreemapNode(name: item.name, value: max(value, 1), children: children), i)
    }
    let root: TreemapNode
    if items.isEmpty {
        root = TreemapNode(name: "root", value: 1, children: [])
    } else {
        var children: [TreemapNode] = []
        var i = 0
        let base = items[0].indent
        while i < items.count {
            let (node, next) = build(i, items[i].indent)
            children.append(node)
            i = next
            _ = base
        }
        if children.count == 1 {
            root = children[0]
        } else {
            root = TreemapNode(name: title ?? "treemap", value: children.reduce(0) { $0 + $1.value }, children: children)
        }
    }
    return TreemapChart(title: title, root: root)
}

// MARK: - Venn

func parseVenn(_ lines: [String]) -> VennChart {
    var title: String?
    var sets: [VennSet] = []
    var intersections: [(ids: [String], label: String)] = []
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("venn") { continue }
        if lower.hasPrefix("title ") { title = ExtraText.unquote(String(line.dropFirst(6))); continue }
        if lower.hasPrefix("set ") {
            let rest = String(line.dropFirst(4))
            let parts = rest.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if let id = parts.first {
                let label = ExtraText.unquote(parts.dropFirst().joined(separator: " "))
                sets.append(VennSet(id: id, label: label.isEmpty ? id : label))
            }
            continue
        }
        if let eq = line.firstIndex(of: "=") {
            let ids = line[..<eq].split(separator: "&").map { $0.trimmingCharacters(in: .whitespaces) }
            let label = ExtraText.unquote(String(line[line.index(after: eq)...]))
            intersections.append((ids, label))
        }
    }
    if sets.isEmpty {
        sets = [VennSet(id: "A", label: "A"), VennSet(id: "B", label: "B")]
    }
    return VennChart(title: title, sets: Array(sets.prefix(3)), intersections: intersections)
}

// MARK: - Packet

func parsePacket(_ lines: [String]) -> PacketChart {
    var title: String?
    var fields: [PacketField] = []
    var cursor = 0
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("packet") { continue }
        if lower.hasPrefix("title ") { title = ExtraText.unquote(String(line.dropFirst(6))); continue }
        if line.hasPrefix("+"), let colon = line.firstIndex(of: ":") {
            let count = Int(line[line.index(after: line.startIndex)..<colon].trimmingCharacters(in: .whitespaces)) ?? 1
            let label = ExtraText.unquote(String(line[line.index(after: colon)...]))
            fields.append(PacketField(start: cursor, end: cursor + max(count, 1) - 1, label: label))
            cursor += max(count, 1)
            continue
        }
        if let colon = line.firstIndex(of: ":") {
            let range = line[..<colon].trimmingCharacters(in: .whitespaces)
            let label = ExtraText.unquote(String(line[line.index(after: colon)...]))
            let bits = range.split(separator: "-")
            if bits.count == 2, let start = Int(bits[0]), let end = Int(bits[1]) {
                fields.append(PacketField(start: start, end: end, label: label))
                cursor = end + 1
            } else if let start = Int(range) {
                fields.append(PacketField(start: start, end: start, label: label))
                cursor = start + 1
            }
        }
    }
    return PacketChart(title: title, fields: fields)
}

// MARK: - Block

func parseBlock(_ lines: [String]) -> BlockChart {
    var columns = 3
    var cells: [BlockCell] = []
    var row = 0
    var col = 0
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("block") { continue }
        if lower.hasPrefix("columns ") {
            columns = Int(line.dropFirst(8).trimmingCharacters(in: .whitespaces)) ?? 3
            continue
        }
        if lower.hasPrefix("space") {
            col += 1
            if col >= columns { col = 0; row += 1 }
            continue
        }
        let tokens = tokenizeBlock(line)
        for token in tokens {
            cells.append(BlockCell(id: token.id, label: token.label, column: col, row: row))
            col += 1
            if col >= columns { col = 0; row += 1 }
        }
    }
    return BlockChart(columns: max(columns, 1), cells: cells)
}

private func tokenizeBlock(_ line: String) -> [(id: String, label: String)] {
    var result: [(id: String, label: String)] = []
    var remaining = line.trimmingCharacters(in: .whitespaces)
    while !remaining.isEmpty {
        remaining = remaining.trimmingCharacters(in: .whitespaces)
        if remaining.hasPrefix("space") {
            break
        }
        if let match = remaining.range(of: #"^([A-Za-z0-9_]+)\[\"([^\"]+)\"\]"#, options: .regularExpression)
            ?? remaining.range(of: #"^([A-Za-z0-9_]+)\[([^\]]+)\]"#, options: .regularExpression)
            ?? remaining.range(of: #"^([A-Za-z0-9_]+)"#, options: .regularExpression) {
            let token = String(remaining[match])
            remaining.removeSubrange(..<match.upperBound)
            if let bracket = token.firstIndex(of: "[") {
                let id = String(token[..<bracket])
                var label = String(token[token.index(after: bracket)...])
                if label.hasSuffix("]") { label.removeLast() }
                result.append((id, ExtraText.unquote(label)))
            } else {
                result.append((token, token))
            }
        } else {
            break
        }
    }
    return result
}

// MARK: - Boxes + edges helpers

private func parseCallArgs(_ line: String) -> (name: String, args: [String])? {
    guard let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")") else { return nil }
    let name = String(line[..<open]).trimmingCharacters(in: .whitespaces)
    let inner = String(line[line.index(after: open)..<close])
    var args: [String] = []
    var current = ""
    var inQuote = false
    for ch in inner {
        if ch == "\"" {
            inQuote.toggle()
            current.append(ch)
        } else if ch == "," && !inQuote {
            args.append(ExtraText.unquote(current))
            current = ""
        } else {
            current.append(ch)
        }
    }
    if !current.trimmingCharacters(in: .whitespaces).isEmpty {
        args.append(ExtraText.unquote(current))
    }
    return (name, args)
}

func parseRequirement(_ lines: [String]) -> RequirementChart {
    var boxes: [NamedBox] = []
    var edges: [NamedEdge] = []
    var currentID: String?
    var currentLabel = ""
    var currentDetail = ""
    func flush() {
        if let id = currentID {
            boxes.append(NamedBox(id: id, label: currentLabel.isEmpty ? id : currentLabel, detail: currentDetail, group: nil))
        }
        currentID = nil
        currentLabel = ""
        currentDetail = ""
    }
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("requirementdiagram") { continue }
        if lower.hasPrefix("requirement ") || lower.hasPrefix("element ") || lower.hasPrefix("functionalrequirement ") {
            flush()
            let rest = line.split(whereSeparator: { $0.isWhitespace }).dropFirst().first.map(String.init) ?? "item"
            currentID = rest.replacingOccurrences(of: "{", with: "")
            currentLabel = currentID ?? rest
            continue
        }
        if line.contains("->") || line.contains("satisfies") || line.contains("contains") {
            flush()
            let cleaned = line.replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: ">", with: " ")
            let parts = cleaned.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if parts.count >= 2 {
                edges.append(NamedEdge(from: parts[0], to: parts.last ?? parts[1], label: parts.dropFirst().dropLast().joined(separator: " ")))
            }
            continue
        }
        if lower.hasPrefix("id:") { currentLabel = ExtraText.unquote(String(line.dropFirst(3))); continue }
        if lower.hasPrefix("text:") { currentDetail = ExtraText.unquote(String(line.dropFirst(5))); continue }
        if line.contains("}") { flush() }
    }
    flush()
    return RequirementChart(boxes: boxes, edges: edges)
}

func parseArchitecture(_ lines: [String]) -> ArchitectureChart {
    var groups: [NamedBox] = []
    var services: [NamedBox] = []
    var edges: [NamedEdge] = []
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("architecture") { continue }
        if lower.hasPrefix("group ") {
            let rest = String(line.dropFirst(6))
            let id = rest.split(whereSeparator: { $0 == "(" || $0.isWhitespace }).first.map(String.init) ?? rest
            var label = id
            if let start = rest.firstIndex(of: "["), let end = rest.firstIndex(of: "]") {
                label = ExtraText.unquote(String(rest[rest.index(after: start)..<end]))
            }
            groups.append(NamedBox(id: id, label: label, detail: "", group: nil))
            continue
        }
        if lower.hasPrefix("service ") || lower.hasPrefix("junction ") {
            let rest = String(line.dropFirst(line.lowercased().hasPrefix("service") ? 8 : 9))
            let id = rest.split(whereSeparator: { $0 == "(" || $0.isWhitespace }).first.map(String.init) ?? rest
            var label = id
            var group: String?
            if let start = rest.firstIndex(of: "["), let end = rest.firstIndex(of: "]") {
                label = ExtraText.unquote(String(rest[rest.index(after: start)..<end]))
            }
            if let inRange = rest.range(of: #"\bin\s+(\S+)"#, options: .regularExpression) {
                group = String(rest[inRange]).split(whereSeparator: { $0.isWhitespace }).last.map(String.init)
            }
            services.append(NamedBox(id: id, label: label, detail: "", group: group))
            continue
        }
        if line.contains("--") || line.contains(":") {
            let colonReplaced = line.replacingOccurrences(of: ":", with: " ")
            let spaced = colonReplaced.replacingOccurrences(of: "--", with: " ")
            var tokens: [String] = []
            for piece in spaced.split(separator: " ", omittingEmptySubsequences: true) {
                let token = String(piece)
                if token == "L" || token == "R" || token == "T" || token == "B" { continue }
                tokens.append(token)
            }
            if tokens.count >= 2 {
                let from = tokens[0]
                let to = tokens[1]
                let label = tokens.dropFirst(2).joined(separator: " ")
                edges.append(NamedEdge(from: from, to: to, label: label))
            }
        }
    }
    return ArchitectureChart(groups: groups, services: services, edges: edges)
}

func parseC4(_ lines: [String]) -> C4Chart {
    var title: String?
    var kind = "C4Context"
    var boxes: [NamedBox] = []
    var edges: [NamedEdge] = []
    if let header = lines.first { kind = header.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? kind }
    for line in lines {
        if let args = parseCallArgs(line) {
            let fn = args.name.lowercased()
            if fn == "title" || fn.hasSuffix(".title") {
                title = args.args.first
                continue
            }
            if fn.contains("rel") {
                if args.args.count >= 2 {
                    edges.append(NamedEdge(from: args.args[0], to: args.args[1], label: args.args.dropFirst(2).first ?? ""))
                }
                continue
            }
            if ["person", "system", "container", "component", "node", "system_ext", "container_ext", "person_ext", "systemdb", "containerdb"].contains(where: { fn.contains($0) }) {
                let id = args.args.first ?? "id"
                let label = args.args.dropFirst().first ?? id
                let detail = args.args.dropFirst(2).first ?? ""
                boxes.append(NamedBox(id: id, label: label, detail: detail, group: fn.contains("person") ? "actor" : "system"))
            }
        } else if line.lowercased().hasPrefix("title ") {
            title = ExtraText.unquote(String(line.dropFirst(6)))
        }
    }
    return C4Chart(title: title, kind: kind, boxes: boxes, edges: edges)
}

func parseKanban(_ source: String) -> KanbanChart {
    var title: String?
    var columns: [KanbanColumn] = []
    var current: String?
    var cards: [String] = []
    func flush() {
        if let name = current {
            columns.append(KanbanColumn(name: name, cards: cards))
        }
        cards = []
    }
    let raw = DiagramKindDetector.stripFrontmatter(source)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    for rawLine in raw {
        let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.count
        let text = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.hasPrefix("%%") { continue }
        let lower = text.lowercased()
        if lower.hasPrefix("kanban") { continue }
        if lower.hasPrefix("title ") { title = ExtraText.unquote(String(text.dropFirst(6))); continue }
        if indent <= 2 || current == nil {
            flush()
            current = ExtraText.unquote(text)
        } else {
            cards.append(ExtraText.unquote(text))
        }
    }
    flush()
    return KanbanChart(title: title, columns: columns)
}

func parseUseCase(_ lines: [String]) -> UseCaseChart {
    var actors: [NamedBox] = []
    var cases: [NamedBox] = []
    var edges: [NamedEdge] = []
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("usecase") { continue }
        if lower.hasPrefix("actor ") {
            let name = ExtraText.unquote(String(line.dropFirst(6)))
            actors.append(NamedBox(id: name, label: name, detail: "", group: "actor"))
            continue
        }
        if let args = parseCallArgs(line), args.name.lowercased() == "actor" {
            let name = args.args.first ?? "actor"
            actors.append(NamedBox(id: name, label: name, detail: "", group: "actor"))
            continue
        }
        if line.contains("-->") || line.contains("->") || line.contains("--") {
            let spaced = line.replacingOccurrences(of: "-->", with: " ")
                .replacingOccurrences(of: "->", with: " ")
                .replacingOccurrences(of: "--", with: " ")
            var parts: [String] = []
            for token in spaced.split(whereSeparator: { $0.isWhitespace }) {
                let cleaned = ExtraText.unquote(String(token).replacingOccurrences(of: ":", with: ""))
                if !cleaned.isEmpty && cleaned != ":" {
                    parts.append(cleaned)
                }
            }
            if parts.count >= 2 {
                edges.append(NamedEdge(from: parts[0], to: parts[1], label: parts.dropFirst(2).joined(separator: " ")))
            }
            continue
        }
        if lower.contains("(") && lower.contains(")") {
            if let start = line.firstIndex(of: "("), let end = line.firstIndex(of: ")") {
                let label = ExtraText.unquote(String(line[line.index(after: start)..<end]))
                cases.append(NamedBox(id: label, label: label, detail: "", group: "case"))
            }
        }
    }
    return UseCaseChart(actors: actors, cases: cases, edges: edges)
}

func parseIshikawa(_ lines: [String]) -> IshikawaChart {
    var effect = "Effect"
    var bones: [(name: String, causes: [String])] = []
    var current: String?
    var causes: [String] = []
    func flush() {
        if let name = current { bones.append((name, causes)) }
        causes = []
    }
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("ishikawa") { continue }
        if lower.hasPrefix("effect ") || lower.hasPrefix("title ") {
            effect = ExtraText.unquote(String(line.split(whereSeparator: { $0.isWhitespace }).dropFirst().joined(separator: " ")))
            continue
        }
        if !line.hasPrefix(" ") && !line.hasPrefix(":") {
            flush()
            current = ExtraText.unquote(line)
        } else {
            causes.append(ExtraText.unquote(line.hasPrefix(":") ? String(line.dropFirst()) : line))
        }
    }
    flush()
    if bones.isEmpty {
        bones = [("Cause", ["factor"])]
    }
    return IshikawaChart(effect: effect, bones: bones)
}

func parseCynefin(_ lines: [String]) -> CynefinChart {
    var title: String?
    var domains: [(name: String, items: [String])] = [
        ("Clear", []), ("Complicated", []), ("Complex", []), ("Chaotic", [])
    ]
    var current = 0
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("cynefin") { continue }
        if lower.hasPrefix("title ") { title = ExtraText.unquote(String(line.dropFirst(6))); continue }
        if let idx = domains.firstIndex(where: { lower.hasPrefix($0.name.lowercased()) }) {
            current = idx
            continue
        }
        domains[current].items.append(ExtraText.unquote(line))
    }
    return CynefinChart(title: title, domains: domains)
}

func parseWardley(_ lines: [String]) -> WardleyChart {
    var title: String?
    var components: [WardleyComponent] = []
    var edges: [NamedEdge] = []
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("wardley") { continue }
        if lower.hasPrefix("title ") { title = ExtraText.unquote(String(line.dropFirst(6))); continue }
        if lower.hasPrefix("component ") {
            let rest = String(line.dropFirst(10))
            let name: String
            if let quote = rest.firstIndex(of: "["), let end = rest.firstIndex(of: "]") {
                name = ExtraText.unquote(String(rest[rest.index(after: quote)..<end]))
            } else {
                name = ExtraText.unquote(rest.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? rest)
            }
            let nums = rest.split(whereSeparator: { $0 == "," || $0 == "[" || $0 == "]" || $0.isWhitespace }).compactMap { Double($0) }
            let vis = nums.count >= 2 ? nums[0] : 0.5
            let evo = nums.count >= 2 ? nums[1] : (nums.first ?? 0.5)
            components.append(WardleyComponent(name: name, visibility: vis, evolution: evo))
            continue
        }
        if line.contains("->") {
            let parts = line.replacingOccurrences(of: "->", with: " ").split(whereSeparator: { $0.isWhitespace }).map { ExtraText.unquote(String($0)) }
            if parts.count >= 2 {
                edges.append(NamedEdge(from: parts[0], to: parts[1], label: ""))
            }
        }
    }
    return WardleyChart(title: title, components: components, edges: edges)
}

func parseEventModel(_ lines: [String]) -> EventModelChart {
    var lanes: [(name: String, events: [String])] = []
    var current = "Lane"
    var events: [String] = []
    func flush() {
        if !events.isEmpty || lanes.isEmpty { lanes.append((current, events)) }
        events = []
    }
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("eventmodeling") { continue }
        if lower.hasPrefix("lane ") || lower.hasPrefix("actor ") || lower.hasPrefix("stream ") {
            flush()
            current = ExtraText.unquote(String(line.split(whereSeparator: { $0.isWhitespace }).dropFirst().joined(separator: " ")))
            continue
        }
        events.append(ExtraText.unquote(line))
    }
    flush()
    return EventModelChart(lanes: lanes)
}

func parseRailroad(_ lines: [String]) -> RailroadChart {
    var title: String?
    var terms: [String] = []
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("railroad") { continue }
        if lower.hasPrefix("title ") { title = ExtraText.unquote(String(line.dropFirst(6))); continue }
        terms.append(contentsOf: line.split(whereSeparator: { $0.isWhitespace }).map { ExtraText.unquote(String($0)) }.filter { !$0.isEmpty })
    }
    if terms.isEmpty { terms = ["start", "end"] }
    return RailroadChart(title: title, terms: terms)
}
