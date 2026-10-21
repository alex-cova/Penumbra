import Foundation

func parseExtra(
    kind: DiagramKind,
    lines: [String],
    source: String,
    mindmapLayout: MindmapLayoutMode? = nil,
    config: [String: YamlValue] = [:]
) throws -> ExtraParsed {
    switch kind {
    case .pie: return .pie(parsePieChart(lines))
    case .gantt: return .gantt(parseGanttChart(lines))
    case .gitGraph: return .gitGraph(parseGitGraph(lines))
    case .journey: return .journey(parseJourney(lines))
    case .mindmap: return .mindmap(try parseMindmap(source, layout: mindmapLayout))
    case .timeline: return .timeline(parseTimeline(lines))
    case .quadrantChart: return .quadrant(parseQuadrant(lines))
    case .sankey: return .sankey(parseSankey(lines, showValues: sankeyShowValues(config)))
    case .radar: return .radar(parseRadar(lines))
    case .treemap: return .treemap(try parseTreemap(source))
    case .venn: return .venn(parseVenn(lines))
    case .packet: return .packet(parsePacket(lines))
    case .block: return .block(parseBlock(lines))
    case .requirement: return .requirement(parseRequirement(lines))
    case .architecture: return .architecture(parseArchitecture(lines))
    case .c4: return .c4(parseC4(lines))
    case .kanban: return .kanban(parseKanban(source))
    case .usecase: return .usecase(parseUseCase(lines))
    case .treeView: return .treeView(try parseTreeView(source, showIcons: treeViewShowIcons(config)))
    case .ishikawa: return .ishikawa(parseIshikawa(source))
    case .cynefin: return .cynefin(parseCynefin(lines))
    case .wardley: return .wardley(parseWardley(lines))
    case .eventmodeling: return .eventmodeling(parseEventModel(lines))
    case .railroad: return .railroad(try parseRailroad(source))
    case .info: return .info(parseInfoChart(lines))
    default:
        throw MermaidParserError.unsupportedDiagram(kind.rawValue)
    }
}

/// Mermaid `info` shows the renderer's version (plus an optional title),
/// mirroring Mermaid/Pele rendering their own version in the info box.
func parseInfoChart(_ lines: [String]) -> InfoChart {
    var title: String?
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("info") { continue }
        if lower.hasPrefix("showinfo") { continue }
        if lower.hasPrefix("acctitle:") || lower.hasPrefix("accdescr:") { continue }
        if lower.hasPrefix("title ") {
            title = ExtraText.unquote(String(line.dropFirst(6)))
            continue
        }
    }
    return InfoChart(title: title)
}

/// Swimlanes are flowchart subgraphs promoted to lanes: `swimlane-beta [dir]`
/// rewrites to `flowchart [dir]` and the existing ELK flowchart path renders
/// each top-level subgraph as a lane group.
func rewriteSwimlaneAsFlowchart(_ source: String) -> String {
    var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if let index = lines.firstIndex(where: {
        let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("swimlane")
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

func parseMindmap(_ source: String, layout: MindmapLayoutMode? = nil) throws -> MindmapChart {
    let layout = layout ?? .treeLR
    var nodes: [MindmapNode] = []
    var stack: [(indent: Int, id: Int)] = []
    var nextID = 0
    let raw = DiagramKindDetector.stripFrontmatter(source)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    for rawLine in raw {
        if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("%%") { continue }
        let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.reduce(0) { acc, ch in acc + (ch == "\t" ? 4 : 1) }
        let text = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        let lower = text.lowercased()
        if lower.hasPrefix("mindmap") || lower.hasPrefix("treeview") { continue }
        let parsed = parseMindmapNode(text)
        while let last = stack.last, last.indent >= indent {
            stack.removeLast()
        }
        let parent = stack.last?.id
        if stack.count >= LunaLimits.maxNesting {
            throw MermaidParserError.limit(
                "Mindmap nesting exceeds the \(LunaLimits.maxNesting) limit.")
        }
        nodes.append(MindmapNode(
            id: nextID,
            text: parsed.text,
            parent: parent,
            depth: stack.count,
            shape: parsed.shape
        ))
        stack.append((indent, nextID))
        nextID += 1
    }
    if nodes.isEmpty {
        nodes.append(MindmapNode(id: 0, text: "root", parent: nil, depth: 0))
    }
    return MindmapChart(nodes: nodes, layout: layout)
}

// MARK: - TreeView
//
// Port of Pele's box-drawing preprocessor
// (`src/diagrams/treeview/boxDrawing.ts`): `treeView-beta` bodies drawn with
// `├──`/`└──`/`│` glyphs are converted to space indentation before the
// indentation-sensitive parser runs, so each glyph row becomes a real node.
// Unlike Pele this port is lenient (no throws): malformed rows pass through
// and are parsed as plain indented text.

/// Reads frontmatter `config.treeView.showIcons` (Pele default `false`).
func treeViewShowIcons(_ config: [String: YamlValue]) -> Bool {
    var sections: [[String: YamlValue]] = []
    if case .object(let treeView) = config["treeView"] { sections.append(treeView) }
    if case .object(let cfg) = config["config"],
       case .object(let treeView) = cfg["treeView"] { sections.append(treeView) }
    for treeView in sections {
        if case .bool(let b) = treeView["showIcons"] { return b }
    }
    return false
}

/// Parses `treeView-beta`: indentation-nested entries (box-drawing is
/// expanded to spaces first) with `name :::class`, `name icon(pack:name)`
/// and `name ## description` annotations, quoted names, and a trailing `/`
/// marking directories. Port of Pele's `src/diagrams/treeview` front end.
func parseTreeView(_ source: String, showIcons: Bool = false) throws -> TreeViewChart {
    let expanded = expandTreeViewBoxDrawing(source)
    var lines = expanded.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    // A leading `---` frontmatter block never holds entries.
    if let first = lines.first,
       first.trimmingCharacters(in: .whitespaces) == "---",
       let close = lines.dropFirst().firstIndex(where: {
           $0.trimmingCharacters(in: .whitespaces) == "---"
       }) {
        lines = Array(lines[lines.index(after: close)...])
    }
    var title: String?
    // Reference tree while stacking (Pele `TreeViewDb`); converted to values
    // at the end.
    final class Builder {
        var node: TreeViewNode
        var kids: [Builder] = []
        init(_ node: TreeViewNode) { self.node = node }
    }
    var stack: [(indent: Int, box: Builder)] = []
    var roots: [Builder] = []

    func isBlank(_ ch: Character) -> Bool {
        ch == " " || ch == "\t"
    }

    // Where the name ends and the annotations begin: the first `:::`, `icon(`
    // or `##` marker that follows a blank.
    func annotationStart(_ text: String) -> String.Index? {
        var i = text.startIndex
        var quote: Character? = nil
        while i < text.endIndex {
            let ch = text[i]
            if let q = quote {
                if ch == q { quote = nil }
                i = text.index(after: i)
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                i = text.index(after: i)
                continue
            }
            if isBlank(ch) {
                var j = text.index(after: i)
                while j < text.endIndex, isBlank(text[j]) { j = text.index(after: j) }
                if j < text.endIndex {
                    if text[j...].hasPrefix(":::") {
                        var k = text.index(j, offsetBy: 3, limitedBy: text.endIndex) ?? text.endIndex
                        while k < text.endIndex, isBlank(text[k]) { k = text.index(after: k) }
                        if k < text.endIndex,
                           text[k].isLetter || text[k] == "_" { return i }
                    } else if text[j...].hasPrefix("icon(") || text[j...].hasPrefix("##") {
                        return i
                    }
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    func parseEntry(_ body: String) -> TreeViewNode? {
        var name: String
        var rest: String
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if let q = trimmed.first, q == "\"" || q == "'" {
            var j = trimmed.index(after: trimmed.startIndex)
            while j < trimmed.endIndex, trimmed[j] != q { j = trimmed.index(after: j) }
            guard j < trimmed.endIndex else { return nil }
            name = String(trimmed[trimmed.index(after: trimmed.startIndex)..<j])
            rest = String(trimmed[trimmed.index(after: j)...])
        } else if let split = annotationStart(trimmed) {
            name = String(trimmed[..<split]).trimmingCharacters(in: .whitespaces)
            rest = String(trimmed[split...])
        } else {
            name = trimmed
            rest = ""
        }
        if name.isEmpty { return nil }
        var cssClass: String?
        var icon: String?
        var description: String?
        var tail = rest.trimmingCharacters(in: .whitespaces)
        while !tail.isEmpty {
            if tail.hasPrefix(":::") {
                tail = String(tail.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let end = tail.firstIndex(where: { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" })
                    ?? tail.endIndex
                cssClass = String(tail[..<end])
                tail = String(tail[end...]).trimmingCharacters(in: .whitespaces)
            } else if tail.hasPrefix("icon(") {
                guard let close = tail.firstIndex(of: ")") else { break }
                icon = String(tail[tail.index(tail.startIndex, offsetBy: 5)..<close])
                tail = String(tail[tail.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            } else if tail.hasPrefix("##") {
                description = String(tail.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                break
            } else {
                break
            }
        }
        var isDirectory = false
        if name.hasSuffix("/") {
            isDirectory = true
            name = String(name.dropLast())
        }
        return TreeViewNode(
            name: name, isDirectory: isDirectory, cssClass: cssClass,
            icon: icon, description: description)
    }

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("%%") { continue }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("treeview") { continue }
        if lower.hasPrefix("title ") {
            title = ExtraText.unquote(String(trimmed.dropFirst(6)))
            continue
        }
        if lower.hasPrefix("acctitle") || lower.hasPrefix("accdescr") { continue }
        if trimmed == "---" { continue }
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        guard let entry = parseEntry(String(line.dropFirst(indent))) else { continue }
        while let last = stack.last, indent <= last.indent {
            stack.removeLast()
        }
        let box = Builder(entry)
        if let parent = stack.last {
            parent.box.kids.append(box)
        } else {
            roots.append(box)
        }
        stack.append((indent, box))
    }
    func build(_ box: Builder) -> TreeViewNode {
        var node = box.node
        node.children = box.kids.map(build)
        return node
    }
    return TreeViewChart(
        title: title, showIcons: showIcons,
        nodes: roots.map(build))
}

func expandTreeViewBoxDrawing(_ source: String) -> String {
    let branchChars: Set<Character> = ["├", "└"]
    let dashChars: Set<Character> = ["─", "━", "┄", "┅", "┈", "┉"]
    let allBoxChars: Set<Character> = ["├", "└", "│", "┃", "─", "━", "┄", "┅", "┈", "┉", "┗", "┣"]
    let boxGuideChars: Set<Character> = [" ", "\t", "│", "┃"]
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.contains(where: { $0.contains(where: allBoxChars.contains) }) else { return source }
    guard let keywordIdx = lines.firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("treeview")
    }) else { return source }
    func isPassThrough(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("%%") { return true }
        let lower = t.lowercased()
        return lower.hasPrefix("title ") || lower.hasPrefix("accTitle")
            || lower.hasPrefix("accDescr") || lower.hasPrefix("---")
    }
    func isDecorationOnly(_ line: String) -> Bool {
        !line.isEmpty && line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "│" || $0 == "┃" }
    }
    var content: [String] = []
    for line in lines[(keywordIdx + 1)...] {
        if isPassThrough(line) || isDecorationOnly(line) { continue }
        content.append(line.replacingOccurrences(of: "\t", with: "    "))
    }
    guard content.contains(where: { $0.contains(where: allBoxChars.contains) }) else { return source }
    let segmentWidth = content.compactMap { line -> Int? in
        let n = line.replacingOccurrences(of: "\t", with: "    ")
        return n.firstIndex(where: branchChars.contains).map { n.distance(from: n.startIndex, to: $0) }
            .flatMap { $0 > 0 ? $0 : nil }
    }.first ?? 4
    var out = Array(lines[...keywordIdx])
    for line in lines[(keywordIdx + 1)...] {
        if isPassThrough(line) { out.append(line); continue }
        if isDecorationOnly(line) { continue }
        let n = line.replacingOccurrences(of: "\t", with: "    ")
        if let bIdx = n.firstIndex(where: branchChars.contains) {
            let col = n.distance(from: n.startIndex, to: bIdx)
            let depth = Int((Double(col) / Double(segmentWidth)).rounded()) + 1
            var pos = n.index(after: bIdx)
            while pos < n.endIndex && dashChars.contains(n[pos]) { pos = n.index(after: pos) }
            while pos < n.endIndex && n[pos] == " " { pos = n.index(after: pos) }
            let text = String(n[pos...]).trimmingCharacters(in: .whitespaces)
            out.append(text.isEmpty ? line : String(repeating: "    ", count: depth) + text)
        } else if n.contains(where: allBoxChars.contains) {
            // A bare guide row (`│`) cannot hold a name; a name that merely
            // contains a box character is a root item.
            if n.allSatisfy({ boxGuideChars.contains($0) }) { continue }
            out.append(line)
        } else {
            out.append(line)
        }
    }
    return out.joined(separator: "\n")
}

private func parseMindmapNode(_ text: String) -> (text: String, shape: MindmapNodeShape) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let patterns: [(String, MindmapNodeShape)] = [
        (#"^\(\((.+)\)\)$"#, .circle),
        (#"^\[\[(.+)\]\]$"#, .roundedRect),
        (#"^\[(.+)\]$"#, .rect),
        (#"^\((.+)\)$"#, .stadium),
        (#"^\{\{(.+)\}\}$"#, .hexagon),
        (#"^\{(.+)\}$"#, .diamond),
    ]
    for (pattern, shape) in patterns {
        if let match = trimmed.range(of: pattern, options: .regularExpression) {
            var inner = String(trimmed[match])
            inner = inner.replacingOccurrences(
                of: #"^\(+|\)+$|^\[+|\]+$|^\{+|\}$+"#,
                with: "",
                options: .regularExpression
            )
            return (ExtraText.unquote(inner), shape)
        }
    }
    return (ExtraText.unquote(trimmed), .roundedRect)
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

/// Splits one `source,target,value` row. Like Pele's sankey lexer, only
/// double quotes group (with `""` escapes); single quotes are literal text.
func splitSankeyFields(_ line: String) -> [String] {
    var fields: [String] = []
    var current = ""
    var quoted = false
    var i = line.startIndex
    while i < line.endIndex {
        let ch = line[i]
        if quoted {
            if ch == "\"" {
                let next = line.index(after: i)
                if next < line.endIndex, line[next] == "\"" {
                    current.append("\"")
                    i = line.index(after: next)
                } else {
                    quoted = false
                    i = next
                }
            } else {
                current.append(ch)
                i = line.index(after: i)
            }
        } else if ch == "\"" {
            quoted = true
            i = line.index(after: i)
        } else if ch == "," {
            fields.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
            i = line.index(after: i)
        } else {
            current.append(ch)
            i = line.index(after: i)
        }
    }
    fields.append(current.trimmingCharacters(in: .whitespaces))
    return fields
}

/// Reads frontmatter `config.sankey.showValues` (Pele: anything but an
/// explicit `false` shows values). Accepts the block at the top level or
/// nested under `config:`, like the mindmap layout reader.
func sankeyShowValues(_ config: [String: YamlValue]) -> Bool {
    var sections: [[String: YamlValue]] = []
    if case .object(let sankey) = config["sankey"] { sections.append(sankey) }
    if case .object(let cfg) = config["config"],
       case .object(let sankey) = cfg["sankey"] { sections.append(sankey) }
    for sankey in sections {
        if case .bool(let b) = sankey["showValues"] { return b }
    }
    return true
}

func parseSankey(_ lines: [String], showValues: Bool = true) -> SankeyChart {
    var links: [SankeyLink] = []
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("sankey") { continue }
        let fields = splitSankeyFields(line)
        guard fields.count == 3,
              !fields[0].isEmpty, !fields[1].isEmpty,
              let value = Double(fields[2]) else { continue }
        links.append(SankeyLink(source: fields[0], target: fields[1], value: value))
    }
    return SankeyChart(links: links, showValues: showValues)
}

// MARK: - Radar

/// Splits on top-level commas, ignoring commas inside quotes, brackets and braces.
private func splitRadarEntries(_ text: String) -> [String] {
    var out: [String] = []
    var depth = 0
    var quote: Character?
    var current = ""
    var iterator = text.makeIterator()
    var pending: Character?
    func nextChar() -> Character? {
        if let p = pending { pending = nil; return p }
        return iterator.next()
    }
    while let c = nextChar() {
        if let q = quote {
            current.append(c)
            if c == "\\" {
                if let n = nextChar() { current.append(n) }
            } else if c == q {
                quote = nil
            }
            continue
        }
        if c == "\"" || c == "'" {
            quote = c
            current.append(c)
        } else if c == "[" || c == "{" {
            depth += 1
            current.append(c)
        } else if c == "]" || c == "}" {
            depth = max(0, depth - 1)
            current.append(c)
        } else if c == "," && depth == 0 {
            out.append(current)
            current = ""
        } else {
            current.append(c)
        }
    }
    out.append(current)
    return out
}

/// Parses one `id["Label"]`, `id` or `"Label"` radar entry.
private func parseRadarEntry(_ text: String) -> (id: String, label: String)? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let open = trimmed.firstIndex(of: "["), trimmed.hasSuffix("\"]"),
       trimmed.index(after: open) < trimmed.endIndex, trimmed[trimmed.index(after: open)] == "\"" {
        let id = String(trimmed[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        let label = String(trimmed[trimmed.index(open, offsetBy: 2)..<trimmed.index(trimmed.endIndex, offsetBy: -2)])
        return (id.isEmpty ? label : id, ExtraText.unquote(label))
    }
    if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 {
        let label = String(trimmed.dropFirst().dropLast())
        return (label, ExtraText.unquote(label))
    }
    if let bracket = trimmed.firstIndex(of: "[") {
        // Legacy `axis [A, B]` items arrive already split; anything else keeps its head.
        let head = String(trimmed[..<bracket]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !head.isEmpty { return (head, head) }
        return nil
    }
    return (trimmed, trimmed)
}

func parseRadar(_ lines: [String]) -> RadarChart {
    var title: String?
    var axes: [String] = []
    var axisIDs: [String] = []
    var series: [RadarSeries] = []
    var maxValue: Double?
    var minValue = 0.0
    var ticks = 5
    var showLegend = true
    var graticule = "circle"
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("radar") { continue }
        if lower.hasPrefix("title ") {
            title = ExtraText.unquote(String(trimmed.dropFirst(6)))
            continue
        }
        if lower.hasPrefix("axis ") || lower == "axis" {
            var rest = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.hasPrefix("[") {
                // Legacy `axis [A, B, C]` form.
                rest = String(rest.dropFirst().prefix { $0 != "]" })
                for item in splitRadarEntries(rest) {
                    if let entry = parseRadarEntry(item) {
                        axisIDs.append(entry.id)
                        axes.append(entry.label)
                    }
                }
                continue
            }
            for item in splitRadarEntries(rest) {
                if let entry = parseRadarEntry(item) {
                    axisIDs.append(entry.id)
                    axes.append(entry.label)
                }
            }
            continue
        }
        if lower.hasPrefix("curve ") || lower.hasPrefix("series ") || lower == "curve" || lower == "series" {
            let keywordLength = lower.hasPrefix("series") ? 6 : 5
            let rest = String(trimmed.dropFirst(keywordLength)).trimmingCharacters(in: .whitespacesAndNewlines)
            for item in splitRadarEntries(rest) {
                let part = item.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !part.isEmpty else { continue }
                var name = "series"
                var valuesText = part
                if let brace = part.firstIndex(of: "{") {
                    let head = String(part[part.startIndex..<brace]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let entry = parseRadarEntry(head) { name = entry.label }
                    valuesText = String(part[part.index(after: brace)...])
                    if valuesText.hasSuffix("}") { valuesText = String(valuesText.dropLast()) }
                } else if let bracket = part.firstIndex(of: "[") {
                    // Legacy `curve "One" [4, 3, 5, 2]` form.
                    let head = String(part[..<bracket]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !head.isEmpty {
                        name = ExtraText.unquote(head.trimmingCharacters(in: .init(charactersIn: "\"")))
                    }
                    valuesText = String(part[part.index(after: bracket)...])
                    if valuesText.hasSuffix("]") { valuesText = String(valuesText.dropLast()) }
                } else {
                    continue
                }
                var values = [Double](repeating: 0, count: max(axes.count, 0))
                var positional: [Double] = []
                var detailed = false
                for piece in splitRadarEntries(valuesText) {
                    let entry = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !entry.isEmpty else { continue }
                    if let colon = entry.firstIndex(of: ":") {
                        detailed = true
                        let key = String(entry[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let number = String(entry[entry.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if let idx = axisIDs.firstIndex(of: key), let v = Double(number) {
                            while values.count <= idx { values.append(0) }
                            values[idx] = v
                        }
                    } else if let v = Double(entry) {
                        positional.append(v)
                    }
                }
                series.append(RadarSeries(name: name, values: detailed ? values : positional))
            }
            continue
        }
        for option in splitRadarEntries(trimmed) {
            let words = option.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                .map(String.init)
            guard words.count == 2 else { continue }
            switch words[0].lowercased() {
            case "max": maxValue = Double(words[1])
            case "min": if let v = Double(words[1]) { minValue = v }
            case "ticks": if let v = Int(words[1]) { ticks = min(max(v, 0), 32) }
            case "showlegend": showLegend = words[1].lowercased() == "true"
            case "graticule":
                let g = words[1].lowercased()
                if g == "circle" || g == "polygon" { graticule = g }
            default: break
            }
        }
    }
    if axes.isEmpty {
        let count = series.first?.values.count ?? 3
        axes = (0..<count).map { "A\($0 + 1)" }
        axisIDs = axes
    }
    return RadarChart(title: title, axes: axes, series: series,
                      max: maxValue, min: minValue, ticks: ticks, showLegend: showLegend, graticule: graticule)
}

// MARK: - Treemap

func parseTreemap(_ source: String) throws -> TreemapChart {
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
    func build(_ start: Int, _ minIndent: Int, _ depth: Int) throws -> (TreemapNode, Int) {
        if depth > LunaLimits.maxNesting {
            throw MermaidParserError.limit(
                "Treemap nesting exceeds the \(LunaLimits.maxNesting) limit.")
        }
        let item = items[start]
        var children: [TreemapNode] = []
        var i = start + 1
        while i < items.count, items[i].indent > minIndent {
            let (child, next) = try build(i, items[i].indent, depth + 1)
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
            let (node, next) = try build(i, items[i].indent, 0)
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

// MARK: - Block
//
// Line-based, lenient port of Pele's `src/diagrams/block` front end:
// `columns N|auto`, `space[:N]`, `id["label"]…` nodes in every bracket flavor,
// `:N` column spans, `A --> B` edge chains with labels, and nested
// `block[:id] … end` composites with per-container columns. Styling
// (`classDef`/`class`/`style`) is skipped. Re-declaring an id updates its
// label, as in Pele.

func parseBlock(_ lines: [String]) -> BlockChart {
    struct Frame {
        var header: BlockNode?
        var columns: Int
        var columnsSet: Bool
        var children: [BlockNode]
    }
    var stack: [Frame] = [Frame(header: nil, columns: -1, columnsSet: false, children: [])]
    var edges: [BlockEdge] = []
    var declared = Set<String>()
    /// Later explicit labels/shapes win (Pele `setHierarchy`).
    var overrides: [String: (label: String, shape: String, directions: [String])] = [:]
    var spaceCount = 0

    func isIDChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_"
    }

    func cleanLabel(_ raw: String) -> String {
        ExtraText.unquote(raw.trimmingCharacters(in: .whitespaces))
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .trimmingCharacters(in: .whitespaces)
    }

    // Maps an opening/closing bracket run to a Pele shape name.
    func shapeName(open: String, close: String) -> String {
        switch (open, close) {
        case ("[", "]"): return "square"
        case ("(", ")"): return "round"
        case ("((", "))"): return "circle"
        case ("(((", ")))"): return "doublecircle"
        case (">", "]"): return "rect_left_inv_arrow"
        case ("{", "}"): return "diamond"
        case ("{{", "}}"): return "hexagon"
        case ("([", "])"): return "stadium"
        case ("[[", "]]"): return "subroutine"
        case ("[(", ")]"): return "cylinder"
        case ("[/", "/]"): return "lean_right"
        case ("[/", "\\]"): return "trapezoid"
        case ("[\\", "\\]"): return "lean_left"
        case ("[\\", "/]"): return "inv_trapezoid"
        case ("<[", "]>"): return "block_arrow"
        default: return "square"
        }
    }

    // Parses one node at the head of the text: id, bracket label, directions
    // and `:span`. Returns the node and the unconsumed remainder.
    func parseNode(_ text: String) -> (node: BlockNode, explicit: Bool, rest: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var pos = trimmed.startIndex
        while pos < trimmed.endIndex, isIDChar(trimmed[pos]) { pos = trimmed.index(after: pos) }
        guard pos > trimmed.startIndex else { return nil }
        return parseNodeTrimmed(trimmed, idEnd: pos)
    }

    func parseNodeTrimmed(_ text: String, idEnd: String.Index) -> (node: BlockNode, explicit: Bool, rest: String)? {
        let id = String(text[..<idEnd])
        var rest = String(text[idEnd...])
        var label: String? = nil
        var shape = "na"
        var directions: [String] = []
        var explicit = false
        // Shape brackets only attach immediately after the id.
        if let open = rest.first, "([{<".contains(open) || open == ">" {
            let pairs: [(Character, Character)] = [("(", ")"), ("[", "]"), ("{", "}"), ("<", ">")]
            if open == ">" {
                // `id>"label"]`: scan to the closing bracket, quote-aware.
                var content = ""
                var quote: Character? = nil
                var j = rest.index(after: rest.startIndex)
                var closed = false
                while j < rest.endIndex {
                    let ch = rest[j]
                    if let q = quote {
                        content.append(ch)
                        if ch == q { quote = nil }
                    } else if ch == "\"" || ch == "'" {
                        quote = ch
                        content.append(ch)
                    } else if ch == "]" {
                        closed = true
                        j = rest.index(after: j)
                        break
                    } else {
                        content.append(ch)
                    }
                    j = rest.index(after: j)
                }
                guard closed else { return nil }
                label = cleanLabel(content)
                shape = "rect_left_inv_arrow"
                explicit = true
                rest = String(rest[j...])
            } else {
                let close = pairs.first { $0.0 == open }!.1
                // Bracket runs: `[[`, `((`, `(((`, `{{`, `([`, `[(`, `[/`, `[\\`, `<[`.
                var opener = String(open)
                var k = rest.index(after: rest.startIndex)
                if open == "(" {
                    while k < rest.endIndex, rest[k] == "(", opener.count < 3 {
                        opener.append(rest[k])
                        k = rest.index(after: k)
                    }
                    if opener.count == 1, k < rest.endIndex, rest[k] == "[" {
                        opener.append("[")
                        k = rest.index(after: k)
                    }
                } else if open == "[" || open == "{" {
                    if k < rest.endIndex, rest[k] == open
                        || (open == "[" && "([/\\".contains(rest[k])) {
                        opener.append(rest[k])
                        k = rest.index(after: k)
                    }
                } else if open == "<", k < rest.endIndex, rest[k] == "[" {
                    opener.append("[")
                    k = rest.index(after: k)
                }
                // Brackets nest (`((()))`, `<["x"]>`): the scan ends at the
                // closer that matches the opener.
                let matchCloser: [Character: Character] =
                    ["(": ")", "[": "]", "{": "}", "<": ">"]
                var stack: [Character] = []
                var quote: Character? = nil
                var j = k
                var content: String? = nil
                var closeRun = ""
                while j < rest.endIndex {
                    let ch = rest[j]
                    if let q = quote {
                        if ch == q { quote = nil }
                        j = rest.index(after: j)
                        continue
                    }
                    if ch == "\"" || ch == "'" {
                        quote = ch
                        j = rest.index(after: j)
                        continue
                    }
                    if let want = matchCloser[ch] {
                        stack.append(want)
                        j = rest.index(after: j)
                        continue
                    }
                    if ")]}>".contains(ch) {
                        if !stack.isEmpty, stack.last == ch {
                            stack.removeLast()
                            j = rest.index(after: j)
                            continue
                        }
                        if ch != close || !stack.isEmpty {
                            j = rest.index(after: j)
                            continue
                        }
                    }
                    if ch == close {
                        // A repeated closer pairs a repeated opener; mixed pairs
                        // close in both halves (`[)]`, `])`, `]>`).
                        var run = String(close)
                        var end = rest.index(after: j)
                        var innerEnd = j
                        if opener == "[(" || opener == "<[" {
                            // The partner sits before the bracket.
                            if innerEnd > k {
                                let prev = rest.index(before: innerEnd)
                                let partner: Character = opener == "[(" ? ")" : "]"
                                if rest[prev] == partner {
                                    innerEnd = prev
                                    run = String(partner) + run
                                }
                            }
                        } else if opener == "([" {
                            // The partner follows the bracket.
                            if end < rest.endIndex, rest[end] == "]" {
                                run.append(rest[end])
                                end = rest.index(after: end)
                            } else if end == rest.endIndex {
                                run.append("]")
                            }
                        } else if opener.allSatisfy({ $0 == open }), opener.count > 1 {
                            while end < rest.endIndex, rest[end] == close, run.count < opener.count {
                                run.append(rest[end])
                                end = rest.index(after: end)
                            }
                        }
                        content = String(rest[k..<innerEnd])
                        closeRun = run
                        j = end
                        break
                    }
                    j = rest.index(after: j)
                }
                guard var found = content else { return nil }
                // With a `[/` / `[\\` opener a trailing slash is lean and
                // trapezoid syntax, not label text.
                if opener.count == 2, opener.first == "[",
                   "/\\".contains(opener.last!),
                   let last = found.last, "/\\".contains(last) {
                    found.removeLast()
                    closeRun = String(last) + closeRun
                }
                // Stadium and cylinder wrap one more pair: `[("x")]`.
                if opener == "[(" || opener == "([", found.count >= 2 {
                    let innerOpen: Character = opener == "[(" ? "(" : "["
                    let innerClose: Character = opener == "[(" ? ")" : "]"
                    if found.first == innerOpen, found.last == innerClose {
                        found = String(found.dropFirst().dropLast())
                    }
                }
                label = cleanLabel(found)
                shape = shapeName(open: opener, close: closeRun)
                explicit = true
                rest = String(rest[j...])
                // `blockArrow` directions: `<["label"]>(right, down)`.
                if shape == "block_arrow" {
                    let tailRest = rest.trimmingCharacters(in: .whitespaces)
                    if tailRest.hasPrefix("("),
                       let end = tailRest.firstIndex(of: ")") {
                        directions = tailRest[tailRest.index(after: tailRest.startIndex)..<end]
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                            .filter { !$0.isEmpty }
                        rest = String(tailRest[tailRest.index(after: end)...])
                    }
                }
            }
        }
        var span = 1
        if rest.hasPrefix(":") {
            let digits = rest.dropFirst().prefix(while: { $0.isNumber })
            if let n = Int(digits), n > 0 { span = min(n, 1000) }
            rest = String(rest.dropFirst(digits.count + 1))
        }
        return (BlockNode(
            id: id, label: label ?? id, shape: shape, directions: directions,
            span: span, children: []
        ), explicit, rest)
    }

    // Finds the next edge operator outside quotes/brackets. Returns the
    // operator and the split point ranges.
    func edgeOp(in text: String, from start: String.Index) -> (op: String, at: String.Index, end: String.Index)? {
        var quote: Character? = nil
        var depth = 0
        var i = start
        while i < text.endIndex {
            let ch = text[i]
            if let q = quote {
                if ch == q { quote = nil }
                i = text.index(after: i)
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                i = text.index(after: i)
                continue
            }
            if "([{<".contains(ch) { depth += 1 }
            else if ")]}>".contains(ch) { depth = max(0, depth - 1) }
            if depth > 0 {
                i = text.index(after: i)
                continue
            }
            // A leading `o`/`x`/`<` marker only opens an edge before dashes
            // (`o--`, `<--`); otherwise the word is a block id.
            if ch == "-" || ch == "=" || ch == "o" || ch == "x" || ch == "<" {
                var j = i
                // Leading marker.
                if ch == "o" || ch == "x" || ch == "<" {
                    let nxt = text.index(after: j)
                    guard nxt < text.endIndex, text[nxt] == "-" || text[nxt] == "=" else {
                        i = text.index(after: i)
                        continue
                    }
                    j = nxt
                }
                var dashes = 0
                while j < text.endIndex, text[j] == "-" || text[j] == "=" || text[j] == "." {
                    dashes += 1
                    j = text.index(after: j)
                }
                guard dashes >= 2 else {
                    i = text.index(after: i)
                    continue
                }
                if j < text.endIndex, "ox<>".contains(text[j]) {
                    j = text.index(after: j)
                }
                return (String(text[i..<j]), i, j)
            }
            i = text.index(after: i)
        }
        return nil
    }

    func edgeMarkers(_ op: String) -> (start: String, end: String, thick: Bool, dotted: Bool) {
        let end: String
        switch op.last {
        case "x": end = "arrow_cross"
        case "o": end = "arrow_circle"
        case ">": end = "arrow_point"
        default: end = "arrow_open"
        }
        let start: String
        switch op.first {
        case "x": start = "arrow_cross"
        case "o": start = "arrow_circle"
        case "<": start = "arrow_point"
        default: start = "arrow_open"
        }
        return (start, end, op.contains("=="), op.contains(".-") || op.contains("-."))
    }

    func declare(_ node: BlockNode, explicit: Bool) {
        if declared.contains(node.id) {
            if explicit { overrides[node.id] = (node.label, node.shape, node.directions) }
            return
        }
        declared.insert(node.id)
        if explicit { overrides[node.id] = (node.label, node.shape, node.directions) }
        stack[stack.count - 1].children.append(node)
    }

    // Whether the operator can open an edge label (`-- label -->`, Pele
    // `START_LINK`).
    func opensLabel(_ op: String) -> Bool {
        !op.isEmpty && op.allSatisfy { $0 == "-" }
    }

    func addSpaces(_ width: Int) {
        for _ in 0..<max(width, 0) {
            spaceCount += 1
            stack[stack.count - 1].children.append(BlockNode(
                id: "space-\(spaceCount)", label: "", kind: "space", span: 1))
        }
    }

    // A `space` / `space:N` gap at the head of the text (Pele `SPACE_BLOCK`).
    func spaceHead(_ text: String) -> (width: Int, rest: String)? {
        guard text.lowercased().hasPrefix("space") else { return nil }
        let after = String(text.dropFirst(5))
        if after.isEmpty { return (1, "") }
        if after.hasPrefix(":") {
            let digits = after.dropFirst().prefix(while: { $0.isNumber })
            guard !digits.isEmpty else { return nil }
            return (min(Int(digits) ?? 1, 1000), String(after.dropFirst(digits.count + 1)))
        }
        guard let first = after.first, first.isWhitespace else { return nil }
        return (1, after.trimmingCharacters(in: .whitespaces))
    }

    // Parses a chain line: space-separated siblings with `A --> B --> C`
    // edge runs, each `--` link optionally carrying a `-- label -->` label.
    func parseChain(_ line: String) {
        guard let first = parseNode(line) else { return }
        declare(first.node, explicit: first.explicit)
        var prevID: String? = first.node.id
        var rest = first.rest.trimmingCharacters(in: .whitespaces)
        while !rest.isEmpty {
            if let gap = spaceHead(rest) {
                addSpaces(gap.width)
                rest = gap.rest.trimmingCharacters(in: .whitespaces)
            } else if let found = edgeOp(in: rest, from: rest.startIndex),
               found.at == rest.startIndex, let fromID = prevID {
                let afterOp = String(rest[found.end...]).trimmingCharacters(in: .whitespaces)
                var label = ""
                var targetText = afterOp
                // Pele reads the edge style off the closing operator, so a
                // `-- label -->` link keeps its arrowhead.
                var linkOp = found.op
                // A markerless opener may carry a label up to its closer.
                if opensLabel(found.op), !afterOp.isEmpty {
                    if afterOp.hasPrefix("\"") || afterOp.hasPrefix("'") {
                        let q = afterOp.first!
                        var j = afterOp.index(after: afterOp.startIndex)
                        while j < afterOp.endIndex, afterOp[j] != q {
                            j = afterOp.index(after: j)
                        }
                        if j < afterOp.endIndex {
                            let behind = String(afterOp[afterOp.index(after: j)...])
                                .trimmingCharacters(in: .whitespaces)
                            if let close = edgeOp(in: behind, from: behind.startIndex),
                               close.at == behind.startIndex {
                                label = cleanLabel(String(afterOp[...j]))
                                targetText = String(behind[close.end...])
                                    .trimmingCharacters(in: .whitespaces)
                                linkOp = close.op
                            }
                        }
                    } else if let close = edgeOp(in: afterOp, from: afterOp.startIndex),
                              close.at > afterOp.startIndex {
                        let raw = String(afterOp[..<close.at])
                            .trimmingCharacters(in: .whitespaces)
                        if !raw.isEmpty {
                            label = cleanLabel(raw)
                            targetText = String(afterOp[close.end...])
                                .trimmingCharacters(in: .whitespaces)
                            linkOp = close.op
                        }
                    }
                }
                guard let got = parseNode(targetText) else { return }
                declare(got.node, explicit: got.explicit)
                let marks = edgeMarkers(linkOp)
                edges.append(BlockEdge(
                    start: fromID, end: got.node.id, label: label,
                    startMarker: marks.start, endMarker: marks.end,
                    thick: marks.thick, dotted: marks.dotted))
                prevID = got.node.id
                rest = got.rest.trimmingCharacters(in: .whitespaces)
            } else if let next = parseNode(rest) {
                // A space-separated sibling, not an edge target.
                declare(next.node, explicit: next.explicit)
                prevID = next.node.id
                rest = next.rest.trimmingCharacters(in: .whitespaces)
            } else {
                return
            }
        }
    }

    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("block-beta") || lower == "block" { continue }
        if lower.hasPrefix("columns ") || lower == "columns" {
            let arg = line.dropFirst(7).trimmingCharacters(in: .whitespaces).lowercased()
            let value: Int
            if arg == "auto" || arg.isEmpty { value = -1 }
            else { value = Int(arg) ?? -1 }
            if !stack[stack.count - 1].columnsSet {
                stack[stack.count - 1].columns = value <= 0 ? -1 : value
                stack[stack.count - 1].columnsSet = true
            }
            continue
        }
        if lower.hasPrefix("classdef ") || lower.hasPrefix("class ") || lower.hasPrefix("style ") { continue }
        if lower == "end" {
            if stack.count > 1 {
                let frame = stack.removeLast()
                let header = frame.header
                // The header's id, label and span carry over to the composite.
                let composite = BlockNode(
                    id: header?.id ?? "block-\(stack.count)-\(frame.children.count)",
                    label: header?.label ?? "", kind: "composite",
                    span: header?.span ?? 1, columns: frame.columns,
                    children: frame.children)
                if header?.id != nil {
                    declared.insert(composite.id)
                }
                stack[stack.count - 1].children.append(composite)
            }
            continue
        }
        if lower == "block" || lower.hasPrefix("block:") || lower.hasPrefix("block ") {
            // `block`, `block:2`, `block:id…` (the header span applies to
            // the composite itself).
            var header: BlockNode? = nil
            if let colon = line.firstIndex(of: ":") {
                let headText = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                if let parsed = parseNode(headText) {
                    header = parsed.node
                }
            } else if lower.hasPrefix("block ") {
                let arg = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if arg.hasPrefix(":"),
                   let n = Int(arg.dropFirst().prefix(while: { $0.isNumber })), n > 0 {
                    header = BlockNode(id: "block", label: "", kind: "composite", span: min(n, 1000))
                }
            }
            stack.append(Frame(header: header, columns: -1, columnsSet: false, children: []))
            continue
        }
        if let gap = spaceHead(line) {
            // A leading `space[:N]` gap; anything behind it (`space:2 B`)
            // keeps parsing as a sibling chain.
            addSpaces(gap.width)
            if !gap.rest.isEmpty {
                parseChain(gap.rest)
            }
            continue
        }
        parseChain(line)
    }
    var root = BlockNode(
        id: "root", label: "", kind: "composite",
        columns: stack[0].columns, children: stack[0].children)
    // Unclosed composites flush into their parent, then the root.
    while stack.count > 1 {
        let frame = stack.removeLast()
        let header = frame.header
        stack[stack.count - 1].children.append(BlockNode(
            id: header?.id ?? "block-\(stack.count)-\(frame.children.count)",
            label: header?.label ?? "", kind: "composite",
            span: header?.span ?? 1, columns: frame.columns, children: frame.children))
    }
    root.children = stack[0].children
    // Apply later explicit declarations over earlier bare ones.
    func apply(_ node: inout BlockNode) {
        if let over = overrides[node.id], node.kind == "block" {
            node.label = over.label
            node.shape = over.shape
            node.directions = over.directions
        }
        for i in node.children.indices { apply(&node.children[i]) }
    }
    apply(&root)
    return BlockChart(root: root, edges: edges)
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
        // Field lines first: a detail like `text: this contains that`
        // must not parse as a relationship edge.
        if lower.hasPrefix("id:") { currentLabel = ExtraText.unquote(String(line.dropFirst(3))); continue }
        if lower.hasPrefix("text:") { currentDetail = ExtraText.unquote(String(line.dropFirst(5))); continue }
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
        if line.contains("}") { flush() }
    }
    flush()
    return RequirementChart(boxes: boxes, edges: edges)
}

/// Parses `architecture-beta`: `group id(icon)[Title] (in parent)?`,
/// `service id(icon)[Title] (in group)?`, `junction id (in group)?`,
/// port edges (`db:L -- R:server`, arrows `<--`/`-->`, `{group}` modifier)
/// and `align row|column …` directives.
func parseArchitecture(_ lines: [String]) -> ArchitectureChart {
    var title: String?
    var groups: [NamedBox] = []
    var services: [NamedBox] = []
    var edges: [NamedEdge] = []
    var alignments: [ArchitectureAlign] = []
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("architecture") { continue }
        if lower.hasPrefix("title ") {
            title = ExtraText.unquote(String(line.dropFirst(6)))
            continue
        }
        if lower.hasPrefix("group ") {
            let rest = String(line.dropFirst(6))
            guard let id = architectureID(rest) else { continue }
            services.removeAll { $0.id == id }
            groups.append(NamedBox(
                id: id,
                label: architectureLabel(rest) ?? id,
                detail: "",
                group: architectureParent(rest)
            ))
            continue
        }
        if lower.hasPrefix("service ") || lower.hasPrefix("junction ") {
            let isJunction = lower.hasPrefix("junction ")
            let rest = String(line.dropFirst(isJunction ? 9 : 8))
            guard let id = architectureID(rest) else { continue }
            groups.removeAll { $0.id == id }
            services.append(NamedBox(
                id: id,
                label: architectureLabel(rest) ?? id,
                detail: "",
                group: architectureParent(rest),
                shape: isJunction ? "junction" : "box"
            ))
            continue
        }
        if lower.hasPrefix("align ") {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if parts.count >= 3, parts[1].lowercased() == "row" || parts[1].lowercased() == "column" {
                alignments.append(ArchitectureAlign(
                    axis: parts[1].lowercased(),
                    members: Array(parts.dropFirst(2))
                ))
            }
            continue
        }
        if let edge = parseArchitectureEdge(line) {
            edges.append(edge)
        }
    }
    return ArchitectureChart(title: title, groups: groups, services: services, edges: edges, alignments: alignments)
}

/// Leading identifier: letters, digits, underscore.
private func architectureID(_ rest: String) -> String? {
    guard let match = rest.range(of: #"^[A-Za-z0-9_]+"#, options: .regularExpression) else { return nil }
    return String(rest[match])
}

/// First `[...]` title in the declaration.
private func architectureLabel(_ rest: String) -> String? {
    guard let start = rest.firstIndex(of: "["),
          let end = rest[start...].firstIndex(of: "]"),
          rest.index(after: start) < end
    else { return nil }
    return ExtraText.unquote(String(rest[rest.index(after: start)..<end]))
}

/// Trailing `in parent` clause.
private func architectureParent(_ rest: String) -> String? {
    guard let match = rest.range(of: #"\bin\s+([A-Za-z0-9_]+)\s*$"#, options: .regularExpression) else { return nil }
    let clause = String(rest[match])
    return clause.split(whereSeparator: { $0.isWhitespace }).last.map(String.init)
}

private struct ArchitectureEndpoint {
    var id: String
    var port: String?
    var inGroup: Bool
}

/// `db{group}:L`, `R:server`, `L:junctionCenter`, `server`.
private func architectureEndpoint(_ token: String) -> ArchitectureEndpoint? {
    let trimmed = token.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    if let match = trimmed.range(
        of: #"^([LRTB]):([A-Za-z0-9_]+)(\{group\})?$"#,
        options: .regularExpression
    ) {
        let parts = String(trimmed[match]).split(separator: ":").map(String.init)
        guard parts.count == 2 else { return nil }
        return ArchitectureEndpoint(
            id: parts[1].replacingOccurrences(of: "{group}", with: ""),
            port: parts[0],
            inGroup: parts[1].contains("{group}")
        )
    }
    if let match = trimmed.range(
        of: #"^([A-Za-z0-9_]+)(\{group\})?(?::([LRTB]))?$"#,
        options: .regularExpression
    ) {
        let body = String(trimmed[match])
        let inGroup = body.contains("{group}")
        let bare = body.replacingOccurrences(of: "{group}", with: "")
        let pieces = bare.split(separator: ":").map(String.init)
        guard let id = pieces.first, !id.isEmpty else { return nil }
        return ArchitectureEndpoint(
            id: id,
            port: pieces.count > 1 ? pieces[1] : nil,
            inGroup: inGroup
        )
    }
    return nil
}

/// `{id}{group}?:{port} {<}?--{>}? {port}:{id}{group}?`. Arrowheads come
/// from `<` / `>`; anything else on the line is dropped (never a label).
private func parseArchitectureEdge(_ line: String) -> NamedEdge? {
    guard let dash = line.range(of: "--") else { return nil }
    var left = String(line[..<dash.lowerBound])
    var right = String(line[dash.upperBound...])
    let startArrow = left.contains("<")
    let endArrow = right.contains(">")
    left = left.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
    right = right.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
    guard let from = architectureEndpoint(left), let to = architectureEndpoint(right) else { return nil }
    return NamedEdge(
        from: from.id, to: to.id, label: "",
        fromPort: from.port, toPort: to.port,
        fromGroup: from.inGroup, toGroup: to.inGroup,
        startArrow: startArrow, endArrow: endArrow
    )
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
            // Style/layout directives (UpdateRelStyle, UpdateLayoutConfig,
            // UpdateElementStyle, …) are not relationships: without this they
            // render as bogus edges labeled `$offsetX="…"` on top of the real
            // edge. Real relationship fns never start with "update".
            if fn.hasPrefix("update") { continue }
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

/// Splits `@{…}` metadata into key/value pairs (Pele reads it as YAML, but
/// kanban metadata is flat `key: value` with quoted strings).
func parseKanbanMetadata(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    var parts: [String] = []
    var depth = 0
    var quote: Character? = nil
    var current = ""
    for ch in text {
        if let q = quote {
            current.append(ch)
            if ch == q { quote = nil }
        } else if ch == "\"" || ch == "'" {
            quote = ch
            current.append(ch)
        } else if ch == "{" {
            depth += 1
            current.append(ch)
        } else if ch == "}" {
            depth = max(0, depth - 1)
            current.append(ch)
        } else if ch == ",", depth == 0 {
            parts.append(current)
            current = ""
        } else {
            current.append(ch)
        }
    }
    parts.append(current)
    for part in parts {
        guard let colon = part.firstIndex(of: ":") else { continue }
        let key = part[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = ExtraText.unquote(part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        if !key.isEmpty { result[key] = value }
    }
    return result
}

func parseKanban(_ source: String) -> KanbanChart {
    var title: String?
    var columns: [KanbanColumn] = []
    var current: String?
    var cards: [KanbanCard] = []
    func flush() {
        if let name = current {
            columns.append(KanbanColumn(name: name, cards: cards))
        }
        cards = []
    }
    // `id[label]`, `[label]` or a bare line, each with optional `@{…}` meta.
    func parseItem(_ text: String) -> KanbanCard {
        var rest = text
        var meta: [String: String] = [:]
        if let at = rest.range(of: "@{", options: .backwards),
           rest.hasSuffix("}") {
            meta = parseKanbanMetadata(String(rest[at.upperBound..<rest.index(before: rest.endIndex)]))
            rest = String(rest[..<at.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        var id: String? = nil
        var label = rest
        if let open = rest.firstIndex(of: "["), rest.hasSuffix("]") {
            let head = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { id = head }
            label = ExtraText.unquote(String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)]))
        } else {
            label = ExtraText.unquote(rest)
        }
        if let override = meta["label"], !override.isEmpty { label = override }
        return KanbanCard(
            id: id ?? label,
            label: label,
            ticket: meta["ticket"], assigned: meta["assigned"], priority: meta["priority"])
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
            // A column header never carries cards' metadata; keep it simple.
            current = parseItem(text).label
        } else {
            cards.append(parseItem(text))
        }
    }
    flush()
    return KanbanChart(title: title, columns: columns)
}

// MARK: - UseCase (`usecase-beta`)
//
// Line-based, lenient port of Pele's `src/diagrams/usecase` front end (which
// itself ports Mermaid's use-case grammar): `actor` declarations with `Id`,
// `Id(label)` and `"label"` forms, bare/`Id(label)`/`Id[label]` use-case
// declarations, `systemBoundary … end` groups, and `-->` / `<--` / `--` /
// `--o` / `o--` / `--x` / `x--` / `--|>` / `..> : include|extend` relationships.
// Styling (`classDef`/`class`/`style`), notes and JSON payloads are skipped.
// Endpoint semantics match Pele: an endpoint that declares a label becomes a
// use case on the spot, a bare endpoint mentioned nowhere else becomes one at
// the end, and only `actor` lines declare actors.

func parseUseCase(_ lines: [String]) -> UseCaseChart {
    var actors: [NamedBox] = []
    var cases: [NamedBox] = []
    var edges: [NamedEdge] = []
    var boundaries: [UseCaseBoundary] = []
    var actorIDs = Set<String>()
    var caseIDs = Set<String>()
    var boundaryIDs = Set<String>()
    var jsonIDs = Set<String>()
    var pendingEndpoints: [String] = []
    var openBoundary: Int? = nil
    var jsonDepth = 0

    // Pele derives an id from a bare label with `label.replace(/\W/g, '_')`.
    func generatedID(_ label: String) -> String {
        let mapped = label.unicodeScalars.map {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
                ? Character($0) : "_"
        }
        let id = String(mapped)
        return id.isEmpty ? "_" : id
    }

    func unquoteLabel(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count >= 2,
           (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("`") && t.hasSuffix("`")) {
            t = String(t.dropFirst().dropLast())
        }
        // Pele `#NN;` character references inside labels (e.g. `#40;` for `(`).
        if let refPattern = try? NSRegularExpression(pattern: #"#(\d+);"#) {
            let range = NSRange(t.startIndex..., in: t)
            var decoded = t
            for match in refPattern.matches(in: t, range: range).reversed() {
                if let numRange = Range(match.range(at: 1), in: t),
                   let code = UInt32(t[numRange]),
                   let scalar = UnicodeScalar(code),
                   let fullRange = Range(match.range, in: t) {
                    decoded.replaceSubrange(fullRange, with: String(scalar))
                }
            }
            t = decoded
        }
        return ExtraText.unquote(t.replacingOccurrences(of: "\\\"", with: "\""))
    }

    // Strips a trailing `@{…}` metadata block, `<<stereotype>>` and `:::classes`.
    func stripSuffixes(_ line: String) -> (core: String, hadMetadata: Bool) {
        var t = line
        var hadMetadata = false
        if let r = t.range(of: #"@\{[^{}]*\}"#, options: .regularExpression) {
            t.removeSubrange(r)
            hadMetadata = true
        }
        t = t.replacingOccurrences(of: "<<.*>>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: ":::.*$", with: "", options: .regularExpression)
        return (t.trimmingCharacters(in: .whitespaces), hadMetadata)
    }

    // Parses `Id`, `Id(label)`, `Id[label]`, `"label"` or `` `label` ``.
    func parseElement(_ text: String) -> (id: String, label: String, rect: Bool, bare: Bool)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        if let q = t.first, q == "\"" || q == "`", t.count >= 2, t.last == q {
            let label = unquoteLabel(t)
            return (generatedID(label), label, false, false)
        }
        let headEnd = t.firstIndex(where: { $0.isWhitespace || "(@[\"".contains($0) })
        let head = String(t[..<(headEnd ?? t.endIndex)])
        guard !head.isEmpty,
              head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        let rest = String(t[(headEnd ?? t.endIndex)...]).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { return (head, head, false, true) }
        guard let open = rest.first, open == "(" || open == "[",
              let close = rest.last, (open == "(" && close == ")") || (open == "[" && close == "]"),
              rest.count >= 2 else { return nil }
        let label = unquoteLabel(String(rest.dropFirst().dropLast()))
        return (head, label, open == "[", false)
    }

    func addMember(_ id: String) {
        guard let b = openBoundary, !boundaries[b].members.contains(id) else { return }
        boundaries[b].members.append(id)
    }

    func addActor(id: String, label: String) {
        guard !actorIDs.contains(id), !caseIDs.contains(id) else { return }
        actorIDs.insert(id)
        actors.append(NamedBox(id: id, label: label, detail: "", group: "actor"))
        addMember(id)
    }

    func addCase(id: String, label: String, rect: Bool) {
        guard !actorIDs.contains(id), !caseIDs.contains(id) else { return }
        caseIDs.insert(id)
        var box = NamedBox(id: id, label: label, detail: "", group: "case")
        if rect { box.shape = "rect" }
        cases.append(box)
        addMember(id)
    }

    // Splits on commas outside quotes, backticks and `(…)`/`[…]` groups.
    func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var depth = 0
        var quote: Character? = nil
        var current = ""
        for ch in text {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "`" {
                quote = ch
                current.append(ch)
            } else if ch == "(" || ch == "[" {
                depth += 1
                current.append(ch)
            } else if ch == ")" || ch == "]" {
                depth = max(0, depth - 1)
                current.append(ch)
            } else if ch == separator && depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    // Finds the first arrow operator outside quotes/backticks. Returns the
    // operator and the (left, right) remainder.
    func splitArrow(_ text: String) -> (op: String, left: String, right: String)? {
        let ops = ["..>", "--|>", "--o", "o--", "--x", "x--", "-->", "<--", "--"]
        var quote: Character? = nil
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if let q = quote {
                if ch == q { quote = nil }
                i += 1
                continue
            }
            if ch == "\"" || ch == "`" {
                quote = ch
                i += 1
                continue
            }
            var matched: String? = nil
            for op in ops where i + op.count <= chars.count {
                if String(chars[i..<(i + op.count)]) == op {
                    matched = op
                    break
                }
            }
            if let op = matched {
                return (op, String(chars[..<i]), String(chars[(i + op.count)...]))
            }
            i += 1
        }
        return nil
    }

    func parseEndpoint(_ text: String, declareLabeled: Bool) -> String? {
        guard let el = parseElement(text) else { return nil }
        if actorIDs.contains(el.id) { return el.id }
        if !el.bare {
            if declareLabeled { addCase(id: el.id, label: el.label, rect: el.rect) }
            return el.id
        }
        if !caseIDs.contains(el.id) && !boundaryIDs.contains(el.id)
            && !jsonIDs.contains(el.id) && !pendingEndpoints.contains(el.id) {
            pendingEndpoints.append(el.id)
        }
        return el.id
    }

    func addEdge(from: String, to: String, label: String, kind: String,
                 startMarker: String = "", endMarker: String = "") {
        edges.append(NamedEdge(
            from: from, to: to, label: label, kind: kind,
            startMarker: startMarker, endMarker: endMarker))
    }

    // Parses one `source <arrow> target` relationship. The source id is
    // already resolved; returns false when the line is not an edge.
    func parseEdge(sourceText: String?, line: String) -> Bool {
        guard let split = splitArrow(line) else { return false }
        let leftID: String? = if let sourceText {
            parseEndpoint(sourceText, declareLabeled: false)
        } else {
            parseEdgeSource(split.left)
        }
        guard let from = leftID else { return false }
        let right = split.right.trimmingCharacters(in: .whitespaces)
        switch split.op {
        case "..>":
            // Pele: `A ..> : include B` / `A ..> : extend B`.
            let tail = right
            guard tail.hasPrefix(":"),
                  let rest = Optional(tail.dropFirst().trimmingCharacters(in: .whitespaces)),
                  rest.hasPrefix("include ") || rest.hasPrefix("extend ") || rest == "include" || rest == "extend"
            else { return false }
            let kind = rest.hasPrefix("extend") ? "extend" : "include"
            let targetText = rest.dropFirst(kind.count).trimmingCharacters(in: .whitespaces)
            if targetText.isEmpty { return false }
            guard let to = parseEndpoint(String(targetText), declareLabeled: true) else { return false }
            addEdge(from: from, to: to, label: kind, kind: kind)
            return true
        case "<--":
            // `A <-- B` draws the head at A; `A <-- label -- B` carries a label.
            let label = ""
            let targetText = right
            if let inner = splitArrow(right), inner.op == "--",
               let to = parseEndpoint(inner.right, declareLabeled: true) {
                let innerLabel = unquoteLabel(inner.left)
                addEdge(from: to, to: from, label: innerLabel, kind: "association", startMarker: "arrow")
                return true
            }
            guard let to = parseEndpoint(targetText, declareLabeled: true) else { return false }
            addEdge(from: to, to: from, label: label, kind: "association", startMarker: "arrow")
            return true
        case "--":
            // Markerless `A -- B`, optionally `A -- label --> B` / `--` / `--o` / `--x`.
            if let inner = splitArrow(right), ["-->", "--", "--o", "--x"].contains(inner.op),
               let to = parseEndpoint(inner.right, declareLabeled: true) {
                let label = unquoteLabel(inner.left)
                switch inner.op {
                case "-->": addEdge(from: from, to: to, label: label, kind: "association", endMarker: "arrow")
                case "--o": addEdge(from: from, to: to, label: label, kind: "association", endMarker: "circle")
                case "--x": addEdge(from: from, to: to, label: label, kind: "association", endMarker: "cross")
                default: addEdge(from: from, to: to, label: label, kind: "association")
                }
                return true
            }
            guard let to = parseEndpoint(right, declareLabeled: true) else { return false }
            addEdge(from: from, to: to, label: "", kind: "association")
            return true
        case "-->":
            guard let to = parseEndpoint(right, declareLabeled: true) else { return false }
            addEdge(from: from, to: to, label: "", kind: "association", endMarker: "arrow")
            return true
        case "--|>":
            guard let to = parseEndpoint(right, declareLabeled: true) else { return false }
            addEdge(from: from, to: to, label: "", kind: "generalization", endMarker: "arrow")
            return true
        case "--o":
            guard let to = parseEndpoint(right, declareLabeled: true) else { return false }
            addEdge(from: from, to: to, label: "", kind: "association", endMarker: "circle")
            return true
        case "o--":
            guard let to = parseEndpoint(right, declareLabeled: true) else { return false }
            addEdge(from: from, to: to, label: "", kind: "association", startMarker: "circle")
            return true
        case "--x":
            guard let to = parseEndpoint(right, declareLabeled: true) else { return false }
            addEdge(from: from, to: to, label: "", kind: "association", endMarker: "cross")
            return true
        case "x--":
            guard let to = parseEndpoint(right, declareLabeled: true) else { return false }
            addEdge(from: from, to: to, label: "", kind: "association", startMarker: "cross")
            return true
        default:
            return false
        }
    }

    // The left side of an edge: an optional `edgeId@` prefix plus an endpoint.
    func parseEdgeSource(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespaces)
        if let at = t.firstIndex(of: "@") {
            let id = String(t[..<at]).trimmingCharacters(in: .whitespaces)
            if !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                t = String(t[t.index(after: at)...])
            }
        }
        return parseEndpoint(t, declareLabeled: false)
    }

    for line in lines {
        if jsonDepth > 0 {
            jsonDepth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            continue
        }
        let lower = line.lowercased()
        if lower.hasPrefix("usecase") || lower.hasPrefix("direction")
            || lower.hasPrefix("acctitle") || lower.hasPrefix("accdescr")
            || lower == "---" || lower.hasPrefix("config") { continue }
        if lower.hasPrefix("note ") || lower == "note" { continue }
        if lower.hasPrefix("classdef ") || lower.hasPrefix("class ") || lower.hasPrefix("style ") { continue }
        if lower == "json" || lower.hasPrefix("json ") {
            var id = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            if let at = id.firstIndex(of: "@") { id = String(id[..<at]) }
            id = id.trimmingCharacters(in: .whitespaces)
            if !id.isEmpty { jsonIDs.insert(id) }
            jsonDepth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            continue
        }
        if lower.hasPrefix("systemboundary") {
            let rest = String(line.dropFirst("systemboundary".count))
            let (core, _) = stripSuffixes(rest)
            if let el = parseElement(core) {
                boundaryIDs.insert(el.id)
                boundaries.append(UseCaseBoundary(id: el.id, label: el.label, members: []))
                openBoundary = boundaries.count - 1
            }
            continue
        }
        if lower == "end" {
            openBoundary = nil
            continue
        }
        if lower.hasPrefix("actor") && (line.count == 5 || line[line.index(line.startIndex, offsetBy: 5)].isWhitespace) {
            let rest = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            // `actor A --> B` declares A and relates it (Pele `actors(top)`).
            var edgeRest: String? = nil
            var firstText = rest
            if let split = splitArrow(rest), !split.left.contains(",") {
                firstText = split.left
                edgeRest = split.op + split.right
            }
            var first = true
            for part in splitTopLevel(firstText, separator: ",") {
                let (core, _) = stripSuffixes(part)
                if let el = parseElement(core) {
                    addActor(id: el.id, label: el.label)
                    if first, let tail = edgeRest {
                        _ = parseEdge(sourceText: el.id, line: tail)
                    }
                }
                first = false
            }
            continue
        }
        let (core, hadMetadata) = stripSuffixes(line)
        if parseEdge(sourceText: nil, line: core) { continue }
        guard let el = parseElement(core) else { continue }
        if el.bare && hadMetadata {
            // `Id@{…}` with no label or shape is a metadata statement on an
            // existing node or edge (Pele), not a new declaration.
            continue
        }
        addCase(id: el.id, label: el.label, rect: el.rect)
    }
    // Endpoints mentioned only in edges become use cases (Pele `endpoint()`);
    // JSON payloads referenced by edges render as rect nodes.
    for id in pendingEndpoints {
        if actorIDs.contains(id) || caseIDs.contains(id) || boundaryIDs.contains(id) { continue }
        addCase(id: id, label: id, rect: jsonIDs.contains(id))
    }
    return UseCaseChart(actors: actors, cases: cases, edges: edges, boundaries: boundaries)
}

/// Parses `ishikawa-beta` from raw source lines because the hierarchy is
/// indentation-defined (`diagramLines` trims that away). Per the Mermaid docs
/// the first top-level item is the effect (the fish head); deeper-indented
/// lines are causes of the current category bone. An explicit `effect X`
/// line overrides the positional effect.
func parseIshikawa(_ source: String) -> IshikawaChart {
    var effect: String?
    var bones: [(name: String, causes: [String])] = []
    var baseIndent: Int?
    let raw = DiagramKindDetector.stripFrontmatter(source)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    for rawLine in raw {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("%%") { continue }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("ishikawa") { continue }
        if lower.hasPrefix("effect ") || lower.hasPrefix("title ") {
            effect = ExtraText.unquote(
                String(trimmed.split(whereSeparator: { $0.isWhitespace }).dropFirst().joined(separator: " ")))
            continue
        }
        let indent = rawLine.prefix { $0 == " " || $0 == "\t" }
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        if baseIndent == nil { baseIndent = indent }
        let base = baseIndent ?? 0
        if effect == nil, indent <= base, bones.isEmpty {
            effect = ExtraText.unquote(trimmed)
            continue
        }
        if indent <= base {
            bones.append((ExtraText.unquote(trimmed), []))
        } else if bones.isEmpty {
            bones.append((ExtraText.unquote(trimmed), []))
        } else {
            bones[bones.count - 1].causes.append(ExtraText.unquote(trimmed))
        }
    }
    if bones.isEmpty {
        bones = [("Cause", ["factor"])]
    }
    return IshikawaChart(effect: effect ?? "Effect", bones: bones)
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

/// Parses the `eventmodeling` DSL: `tf|timeframe <num> <type> <Entity>
/// [{inline}] [[data]] [->> nn …]` and `rf|resetframe` variants, plus
/// multi-line `data Name { … }` blocks (skipped). Frames group into the three
/// default swimlanes (UI/Automation, Command/Read model, Events), split by
/// namespace (`Cart.InventoryChanged` → its own lane). When the source has
/// no time frames at all, legacy `lane X` headers with bare event lines are
/// honored so old diagrams keep rendering.
func parseEventModel(_ lines: [String]) -> EventModelChart {
    var frames: [EventModelFrame] = []
    var inDataBlock = false
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("eventmodeling") { continue }
        if inDataBlock {
            if line.contains("}") { inDataBlock = false }
            continue
        }
        if lower.hasPrefix("data ") || line.trimmingCharacters(in: .whitespaces) == "{" || line == "}" {
            if line.contains("{") { inDataBlock = true }
            continue
        }
        guard let frame = parseEventModelFrame(line) else { continue }
        frames.append(frame)
    }
    if frames.isEmpty {
        return parseEventModelLegacy(lines)
    }
    return groupEventModelFrames(frames)
}

private func parseEventModelFrame(_ line: String) -> EventModelFrame? {
    guard let match = line.range(
        of: #"^(tf|timeframe|rf|resetframe)\s+(\S+)\s+(\S+)\s*(.*)$"#,
        options: [.regularExpression, .caseInsensitive]
    ) else { return nil }
    let parts = String(line[match]).split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        .map(String.init)
    guard parts.count >= 3 else { return nil }
    let head = parts[0].lowercased()
    let number = parts[1]
    let typeToken = parts[2].lowercased()
    var rest = parts.count > 3 ? parts[3] : ""
    rest = rest.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
    rest = rest.replacingOccurrences(of: #"\[\[[^\]]*\]\]"#, with: "", options: .regularExpression)
    let segments = rest.components(separatedBy: "->>")
    let nameToken = segments.first?.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
    guard !nameToken.isEmpty else { return nil }
    let refs = segments.dropFirst().compactMap {
        $0.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    }
    let (kind, band): (String, String)
    switch typeToken {
    case "ui", "scn": (kind, band) = ("UI", "UI / Automation")
    case "pcr", "processor": (kind, band) = ("Processor", "UI / Automation")
    case "cmd", "command": (kind, band) = ("Command", "Command / Read model")
    case "rmo", "readmodel": (kind, band) = ("Read model", "Command / Read model")
    case "evt", "event": (kind, band) = ("Event", "Events")
    default: (kind, band) = (typeToken.uppercased(), "Other")
    }
    let nameParts = nameToken.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    let lane: String
    let name: String
    if nameParts.count == 2 {
        lane = "\(nameParts[0]) · \(band)"
        name = String(nameParts[1])
    } else {
        lane = band
        name = nameToken
    }
    return EventModelFrame(
        number: number, kind: kind, name: ExtraText.unquote(name), lane: lane,
        refs: refs, isReset: head == "rf" || head == "resetframe"
    )
}

private func groupEventModelFrames(_ frames: [EventModelFrame]) -> EventModelChart {
    var order: [String] = []
    var byLane: [String: [EventModelFrame]] = [:]
    for frame in frames {
        if byLane[frame.lane] == nil {
            order.append(frame.lane)
            byLane[frame.lane] = []
        }
        byLane[frame.lane, default: []].append(frame)
    }
    let lanes = order.map { EventModelLane(name: $0, frames: byLane[$0] ?? []) }
    return EventModelChart(lanes: lanes, frames: frames)
}

/// Legacy fallback: `lane X` headers with bare event lines.
private func parseEventModelLegacy(_ lines: [String]) -> EventModelChart {
    var lanes: [EventModelLane] = []
    var current = "Lane"
    var events: [EventModelFrame] = []
    var counter = 0
    func flush() {
        if !events.isEmpty || lanes.isEmpty {
            let stamped = events.map { frame -> EventModelFrame in
                var copy = frame
                copy.lane = current
                return copy
            }
            lanes.append(EventModelLane(name: current, frames: stamped))
        }
        events = []
    }
    for line in lines {
        let lower = line.lowercased()
        if lower.hasPrefix("eventmodeling") { continue }
        if lower.hasPrefix("lane ") || lower.hasPrefix("actor ") || lower.hasPrefix("stream ") {
            flush()
            current = ExtraText.unquote(
                String(line.split(whereSeparator: { $0.isWhitespace }).dropFirst().joined(separator: " ")))
            if current.isEmpty { current = "Lane" }
            continue
        }
        if line == "}" || line == "{" { continue }
        counter += 1
        events.append(EventModelFrame(number: "\(counter)", kind: "", name: ExtraText.unquote(line)))
    }
    flush()
    return EventModelChart(
        lanes: lanes,
        frames: lanes.flatMap(\.frames)
    )
}

// MARK: - Railroad
//
// Port of Pele's `src/diagrams/railroad` front ends: `railroad-beta`
// constructor calls plus the EBNF, ABNF and PEG notations, all producing the
// shared rule model. Lenient where Pele is strict (empty groups, trailing
// text), strict where structure is required (a rule needs `name = … ;`).

enum RRKind: Equatable {
    case name
    case string
    case number
    case numval
    case ch
}

struct RRToken {
    var kind: RRKind
    var text: String
    /// Character offset of the token in the source, for slicing raw spans.
    var offset: Int
    /// End offset (exclusive) in the source.
    var end: Int
    /// 0-based line number, for `title`/`accDescr` spans and ABNF `;`.
    var line: Int
    /// Whether whitespace or a comment precedes the token (ABNF repeats).
    var spaced: Bool
}

/// Splits railroad source into names, strings, numbers, `%` numvals and
/// single characters. `escapes` enables `\n`-style unescaping in strings
/// (every notation but ABNF).
func tokenizeRailroad(_ source: String, escapes: Bool) -> [RRToken] {
    var out: [RRToken] = []
    let chars = Array(source)
    var i = 0
    var line = 0
    var spaced = true
    func push(_ kind: RRKind, _ text: String, _ offset: Int, _ end: Int) {
        out.append(RRToken(kind: kind, text: text, offset: offset, end: end, line: line, spaced: spaced))
        spaced = false
    }
    while i < chars.count {
        let ch = chars[i]
        if ch == "\n" {
            line += 1
            spaced = true
            i += 1
            continue
        }
        if ch.isWhitespace {
            spaced = true
            i += 1
            continue
        }
        // `%%` and `#` line comments, `/* */` and `(* *)` block comments.
        if ch == "%", i + 1 < chars.count, chars[i + 1] == "%" {
            while i < chars.count, chars[i] != "\n" { i += 1 }
            spaced = true
            continue
        }
        if ch == "#" {
            while i < chars.count, chars[i] != "\n" { i += 1 }
            spaced = true
            continue
        }
        if ch == "/", i + 1 < chars.count, chars[i + 1] == "*" {
            i += 2
            while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") {
                if chars[i] == "\n" { line += 1 }
                i += 1
            }
            i = min(i + 2, chars.count)
            spaced = true
            continue
        }
        if ch == "(", i + 1 < chars.count, chars[i + 1] == "*" {
            i += 2
            while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == ")") {
                if chars[i] == "\n" { line += 1 }
                i += 1
            }
            i = min(i + 2, chars.count)
            spaced = true
            continue
        }
        if ch == "\"" || ch == "'" {
            let quote = ch
            let start = i
            i += 1
            var value = ""
            var closed = false
            while i < chars.count {
                let c = chars[i]
                if c == "\n" { line += 1 }
                if escapes, c == "\\", i + 1 < chars.count {
                    let e = chars[i + 1]
                    value.append(e == "n" ? "\n" : e == "r" ? "\r" : e == "t" ? "\t" : e)
                    i += 2
                    continue
                }
                if c == quote {
                    closed = true
                    i += 1
                    break
                }
                value.append(c)
                i += 1
            }
            _ = closed
            push(.string, value, start, i)
            continue
        }
        // ABNF `%x41`, `%d65-90`, `%b1.0` numvals.
        if ch == "%", i + 1 < chars.count, "xXdDbB".contains(chars[i + 1]) {
            let start = i
            i += 2
            while i < chars.count, chars[i].isHexDigit { i += 1 }
            while i < chars.count, (chars[i] == "-" || chars[i] == "."),
                  i + 1 < chars.count, chars[i + 1].isHexDigit {
                i += 2
                while i < chars.count, chars[i].isHexDigit { i += 1 }
            }
            push(.numval, String(chars[start..<i]), start, i)
            continue
        }
        if ch.isLetter || ch == "_" {
            let start = i
            while i < chars.count, chars[i].isLetter || chars[i].isNumber
                || chars[i] == "_" || chars[i] == "-" { i += 1 }
            push(.name, String(chars[start..<i]), start, i)
            continue
        }
        if ch.isNumber {
            let start = i
            while i < chars.count, chars[i].isNumber { i += 1 }
            push(.number, String(chars[start..<i]), start, i)
            continue
        }
        push(.ch, String(ch), i, i + 1)
        i += 1
    }
    return out
}

/// Recursive descent over railroad tokens. One parser per notation, all
/// building the shared `RailroadNode` model directly.
struct RailroadParser {
    var source: String
    var tokens: [RRToken]
    var pos = 0
    var depth = 0

    func peek(_ ahead: Int = 0) -> RRToken? {
        let i = pos + ahead
        return i < tokens.count ? tokens[i] : nil
    }

    func isCh(_ text: String, at ahead: Int = 0) -> Bool {
        guard let t = peek(ahead) else { return false }
        return t.kind == .ch && t.text == text
    }

    func isName(_ text: String, at ahead: Int = 0) -> Bool {
        guard let t = peek(ahead) else { return false }
        return t.kind == .name && t.text.lowercased() == text
    }

    mutating func advance() {
        pos += 1
    }

    mutating func enter() throws {
        depth += 1
        if depth > 500 {
            throw MermaidParserError.limit("Railroad nesting exceeds the 500 limit.")
        }
    }

    mutating func fail(_ what: String) throws -> Never {
        let line = peek()?.line ?? 0
        throw MermaidParserError.syntax(
            message: "Error parsing railroad diagram: expecting \(what)",
            line: line + 1, column: 1, snippet: peek()?.text ?? "")
    }

    // MARK: shared atoms

    // A sequence or a choice of one is that one, in every notation.
    func sequence(_ elements: [RailroadNode]) -> RailroadNode {
        elements.count == 1 ? elements[0] : .sequence(elements)
    }

    func choice(_ alternatives: [RailroadNode]) -> RailroadNode {
        alternatives.count == 1 ? alternatives[0] : .choice(alternatives)
    }

    // MARK: EBNF (`railroad-ebnf-beta`)

    mutating func ebnfChoice() throws -> RailroadNode {
        try enter()
        defer { depth -= 1 }
        var alts = [try ebnfSequence()]
        while isCh("|") {
            advance()
            alts.append(try ebnfSequence())
        }
        return choice(alts)
    }

    mutating func ebnfSequence() throws -> RailroadNode {
        try enter()
        defer { depth -= 1 }
        var elements: [RailroadNode] = []
        while true {
            if isCh(",") {
                advance()
                continue
            }
            guard ebnfStartsPrimary() else { break }
            elements.append(try ebnfTerm())
        }
        if elements.isEmpty { try fail("a terminal, a name, or an opening bracket") }
        return sequence(elements)
    }

    func ebnfStartsPrimary() -> Bool {
        guard let t = peek() else { return false }
        switch t.kind {
        case .string, .name: return true
        case .ch: return "([{?".contains(t.text)
        default: return false
        }
    }

    mutating func ebnfTerm() throws -> RailroadNode {
        try enter()
        defer { depth -= 1 }
        var result = try ebnfPrimary()
        while true {
            if isCh("?"), !specialAhead() {
                advance()
                result = .optional(result)
            } else if isCh("*") {
                advance()
                result = .repetition(result, min: 0, max: nil)
            } else if isCh("+") {
                advance()
                result = .repetition(result, min: 1, max: nil)
            } else if isCh("-") {
                // `a - b` excepts: a sequence of the term, `-`, the operand.
                // Further postfixes attach outside it, as in Pele.
                advance()
                result = .sequence([result, .terminal("-"), try ebnfPrimary()])
            } else {
                break
            }
        }
        return result
    }

    mutating func ebnfPrimary() throws -> RailroadNode {
        try enter()
        defer { depth -= 1 }
        guard let t = peek() else { try fail("a terminal, a name, or an opening bracket") }
        switch t.kind {
        case .string:
            advance()
            return .terminal(t.text)
        case .name:
            advance()
            return .nonterminal(t.text)
        case .ch where t.text == "(" || t.text == "[" || t.text == "{":
            let open = t.text
            advance()
            let inner = try ebnfChoice()
            guard isCh(open == "(" ? ")" : open == "[" ? "]" : "}") else {
                try fail("token of type '\(open == "(" ? "groupEnd" : open == "[" ? "optionEnd" : "repeatEnd")'")
            }
            advance()
            if open == "(" { return inner }
            if open == "[" { return .optional(inner) }
            return .repetition(inner, min: 0, max: nil)
        case .ch where t.text == "?":
            if let special = ebnfSpecial() { return special }
            try fail("a terminal, a name, or an opening bracket")
        default:
            try fail("a terminal, a name, or an opening bracket")
        }
    }

    /// Whether a `? … ?` special sequence starts here.
    func specialAhead() -> Bool {
        guard let t = peek(), t.kind == .ch, t.text == "?" else { return false }
        var j = pos + 1
        var solid = false
        while j < tokens.count {
            let u = tokens[j]
            if u.kind == .ch, u.text == ";" { return false }
            if u.kind == .ch, u.text == "?" { return solid }
            if u.kind != .ch || !u.text.trimmingCharacters(in: .whitespaces).isEmpty {
                solid = true
            }
            j += 1
        }
        return false
    }

    /// `? … ?` special sequences: some non-blank text without `;`.
    mutating func ebnfSpecial() -> RailroadNode? {
        guard specialAhead() else { return nil }
        var j = pos + 1
        while j < tokens.count {
            let u = tokens[j]
            if u.kind == .ch, u.text == "?" {
                let node = RailroadNode.special(sliceRaw(from: pos + 1, to: j))
                pos = j + 1
                return node
            }
            j += 1
        }
        return nil
    }

    /// Raw source slice between two tokens, trimmed (for `? … ?` text).
    func sliceRaw(from: Int, to: Int) -> String {
        guard from < to, to <= tokens.count else { return "" }
        let lo = source.index(source.startIndex, offsetBy: tokens[from].offset)
        let hi = source.index(source.startIndex, offsetBy: tokens[to - 1].end)
        return String(source[lo..<hi]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: ABNF (`railroad-abnf-beta`)

    mutating func abnfAlternation() throws -> RailroadNode {
        try enter()
        defer { depth -= 1 }
        var alts = [try abnfConcatenation()]
        while isCh("/") {
            advance()
            alts.append(try abnfConcatenation())
        }
        return choice(alts)
    }

    mutating func abnfConcatenation() throws -> RailroadNode {
        try enter()
        defer { depth -= 1 }
        var elements: [RailroadNode] = []
        while abnfStartsElement() {
            elements.append(try abnfElement())
        }
        if elements.isEmpty { try fail("a string, a number, a name, or an opening bracket") }
        return sequence(elements)
    }

    func abnfStartsElement() -> Bool {
        guard let t = peek() else { return false }
        switch t.kind {
        case .string, .numval, .name: return true
        case .number: return true
        case .ch: return t.text == "(" || t.text == "[" || t.text == "*"
        }
    }

    /// `[0-9]*[*][0-9]*` repeats, glued without spaces like Pele's lexer.
    mutating func abnfRepeat() -> String? {
        guard let t = peek() else { return nil }
        if t.kind == .number, let star = peek(1),
           star.kind == .ch, star.text == "*", !star.spaced {
            advance()
            advance()
            if let n = peek(), n.kind == .number, !n.spaced {
                advance()
                return "\(t.text)*\(n.text)"
            }
            return "\(t.text)*"
        }
        if t.kind == .ch, t.text == "*" {
            advance()
            if let n = peek(), n.kind == .number, !n.spaced {
                advance()
                return "*\(n.text)"
            }
            return "*"
        }
        if t.kind == .number {
            advance()
            return t.text
        }
        return nil
    }

    mutating func abnfElement() throws -> RailroadNode {
        try enter()
        defer { depth -= 1 }
        let rep = abnfRepeat()
        let primary = try abnfPrimary()
        guard let rep else { return primary }
        let star = rep.firstIndex(of: "*")
        let exact = star == nil
        let min = star.map { $0 == rep.startIndex ? 0 : Int(rep[..<$0]) ?? 0 } ?? Int(rep) ?? 0
        let max: Int? = if exact {
            min
        } else if let s = star, rep.index(after: s) < rep.endIndex {
            Int(rep[rep.index(after: s)...])
        } else {
            nil
        }
        if min == 0, max == 1 { return .optional(primary) }
        return .repetition(primary, min: min, max: max)
    }

    mutating func abnfPrimary() throws -> RailroadNode {
        try enter()
        defer { depth -= 1 }
        guard let t = peek() else { try fail("a string, a number, a name, or an opening bracket") }
        switch t.kind {
        case .string, .numval:
            advance()
            return .terminal(t.text)
        case .name:
            advance()
            return .nonterminal(t.text)
        case .ch where t.text == "(" || t.text == "[":
            let open = t.text
            advance()
            let inner = try abnfAlternation()
            guard isCh(open == "(" ? ")" : "]") else {
                try fail("token of type '\(open == "(" ? "groupEnd" : "optionEnd")'")
            }
            advance()
            if open == "(" { return inner }
            return .optional(inner)
        default:
            try fail("a string, a number, a name, or an opening bracket")
        }
    }

    // MARK: PEG (`railroad-peg-beta`)

    mutating func pegChoice() throws -> RailroadNode {
        try enter()
        defer { depth -= 1 }
        var alts = [try pegSequence()]
        while isCh("/") {
            advance()
            alts.append(try pegSequence())
        }
        return choice(alts)
    }

    mutating func pegSequence() throws -> RailroadNode {
        try enter()
        defer { depth -= 1 }
        var elements: [RailroadNode] = []
        while pegStartsPrimary() {
            elements.append(try pegPrefix())
        }
        if elements.isEmpty { try fail("a literal, a name, a dot, or an opening parenthesis") }
        return sequence(elements)
    }

    func pegStartsPrimary() -> Bool {
        guard let t = peek() else { return false }
        switch t.kind {
        case .string, .name: return true
        case .ch: return t.text == "(" || t.text == "." || t.text == "&" || t.text == "!"
        default: return false
        }
    }

    mutating func pegPrefix() throws -> RailroadNode {
        try enter()
        defer { depth -= 1 }
        var op: String? = nil
        if let t = peek(), t.kind == .ch, t.text == "&" || t.text == "!" {
            op = t.text
            advance()
        }
        let suffix = try pegSuffix()
        guard let op else { return suffix }
        return .special(op + pegLabel(suffix))
    }

    /// What a predicate shows of the expression it looks ahead for.
    func pegLabel(_ node: RailroadNode) -> String {
        switch node {
        case .terminal(let v): return "\"\(v)\""
        case .nonterminal(let n): return n
        case .special(let s): return s
        default: return "(...)"
        }
    }

    mutating func pegSuffix() throws -> RailroadNode {
        try enter()
        defer { depth -= 1 }
        let primary = try pegPrimary()
        if isCh("?") {
            advance()
            return .optional(primary)
        }
        if isCh("*") {
            advance()
            return .repetition(primary, min: 0, max: nil)
        }
        if isCh("+") {
            advance()
            return .repetition(primary, min: 1, max: nil)
        }
        return primary
    }

    mutating func pegPrimary() throws -> RailroadNode {
        try enter()
        defer { depth -= 1 }
        guard let t = peek() else { try fail("a literal, a name, a dot, or an opening parenthesis") }
        switch t.kind {
        case .string:
            advance()
            return .terminal(t.text)
        case .name:
            advance()
            return .nonterminal(t.text)
        case .ch where t.text == ".":
            advance()
            return .special(".")
        case .ch where t.text == "(":
            advance()
            let inner = try pegChoice()
            guard isCh(")") else { try fail("token of type ')'") }
            advance()
            return inner
        default:
            try fail("a literal, a name, a dot, or an opening parenthesis")
        }
    }

    // MARK: constructor calls (`railroad-beta`)

    static let irWords: Set<String> = [
        "terminal", "nonterminal", "special", "sequence", "choice",
        "optional", "zeroOrMore", "oneOrMore",
    ]

    mutating func irExpr() throws -> RailroadNode {
        try enter()
        defer { depth -= 1 }
        guard let t = peek(), t.kind == .name, Self.irWords.contains(t.text) else {
            try fail("an expression")
        }
        let word = t.text
        advance()
        guard isCh("(") else { try fail("'('") }
        advance()
        if word == "terminal" || word == "nonterminal" || word == "special" {
            guard let s = peek(), s.kind == .string else { try fail("a string") }
            advance()
            guard isCh(")") else { try fail("')'") }
            advance()
            if word == "terminal" { return .terminal(s.text) }
            if word == "nonterminal" { return .nonterminal(s.text) }
            return .special(s.text)
        }
        var kids: [RailroadNode] = []
        if !isCh(")") {
            kids.append(try irExpr())
            while isCh(",") {
                advance()
                kids.append(try irExpr())
            }
        }
        guard isCh(")") else { try fail("')'") }
        advance()
        switch word {
        case "sequence": return kids.count == 1 ? kids[0] : .sequence(kids)
        case "choice": return kids.count == 1 ? kids[0] : .choice(kids)
        case "optional": return .optional(kids[0])
        default: return .repetition(kids[0], min: word == "oneOrMore" ? 1 : 0, max: nil)
        }
    }
}

/// Parses a whole railroad diagram in any of the four notations.
func parseRailroad(_ source: String) throws -> RailroadChart {
    // ABNF strings take no escapes; every other notation unescapes them.
    let prelim = tokenizeRailroad(source, escapes: true)
    guard let first = prelim.first, first.kind == .name else {
        throw MermaidParserError.syntax(
            message: "Error parsing railroad diagram: expecting a railroad keyword",
            line: 1, column: 1, snippet: "")
    }
    let keyword = first.text.lowercased()
    let notation: String
    if keyword == "railroad-ebnf-beta" { notation = "ebnf" }
    else if keyword == "railroad-abnf-beta" { notation = "abnf" }
    else if keyword == "railroad-peg-beta" { notation = "peg" }
    else if keyword == "railroad-beta" { notation = "railroad" }
    else {
        throw MermaidParserError.syntax(
            message: "Error parsing railroad diagram: expecting a railroad keyword, got '\(first.text)'",
            line: first.line + 1, column: 1, snippet: first.text)
    }
    let tokens = tokenizeRailroad(source, escapes: notation != "abnf")
    var parser = RailroadParser(source: source, tokens: tokens)
    parser.pos = 1
    var title: String? = nil
    var rules: [RailroadRule] = []

    // A `title` line runs to the end of its line; quoted titles unquote.
    func takeTitle() {
        let line = parser.peek()?.line ?? 0
        var parts: [String] = []
        while let t = parser.peek(), t.line == line {
            parts.append(t.text)
            parser.advance()
        }
        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        title = joined.isEmpty ? nil : ExtraText.unquote(joined)
    }

    // Accessibility statements are accepted and skipped.
    func skipMeta() {
        let line = parser.peek()?.line ?? 0
        if parser.isName("accdescr"), let next = parser.peek(1),
           next.kind == .ch, next.text == "{" {
            parser.advance()
            parser.advance()
            while let t = parser.peek(), !(t.kind == .ch && t.text == "}") {
                parser.advance()
            }
            if parser.peek() != nil { parser.advance() }
            return
        }
        while let t = parser.peek(), t.line == line {
            parser.advance()
        }
    }

    func takeRuleName() throws -> String {
        guard let t = parser.peek(), t.kind == .name,
              t.text.lowercased() != "title",
              t.text.lowercased() != "acctitle",
              t.text.lowercased() != "accdescr" else {
            try parser.fail("a rule name")
        }
        parser.advance()
        return t.text
    }

    // `=` / `::=` / `<-` rule openers.
    func takeOpener(peg: Bool) throws {
        if peg {
            guard parser.isCh("<"), parser.peek(1)?.kind == .ch,
                  parser.peek(1)?.text == "-" else {
                try parser.fail("' <-'")
            }
            parser.advance()
            parser.advance()
            return
        }
        if parser.isCh("=") {
            parser.advance()
            return
        }
        guard parser.isCh(":"), parser.peek(1)?.kind == .ch,
              parser.peek(1)?.text == ":",
              parser.peek(2)?.kind == .ch, parser.peek(2)?.text == "=" else {
            try parser.fail("'='")
        }
        parser.advance()
        parser.advance()
        parser.advance()
    }

    while let t = parser.peek() {
        if t.kind == .name, t.text.lowercased() == "title" {
            parser.advance()
            takeTitle()
        } else if t.kind == .name,
                  t.text.lowercased() == "acctitle" || t.text.lowercased() == "accdescr" {
            parser.advance()
            skipMeta()
        } else {
            let name = try takeRuleName()
            try takeOpener(peg: notation == "peg")
            let definition: RailroadNode
            switch notation {
            case "ebnf": definition = try parser.ebnfChoice()
            case "abnf": definition = try parser.abnfAlternation()
            case "peg": definition = try parser.pegChoice()
            default: definition = try parser.irExpr()
            }
            // A rule closes with `;`. In ABNF a `;` with text behind it on
            // the line starts a comment instead; anything else trailing is
            // skipped leniently.
            if notation == "abnf" {
                guard let semi = parser.peek(), semi.kind == .ch, semi.text == ";" else {
                    try parser.fail("';'")
                }
                let after = parser.tokens[(parser.pos + 1)...].first
                if let after, after.line == semi.line {
                    // A `;` with text behind it starts a comment; the rule
                    // still needs its end.
                    while let u = parser.peek(), u.line == semi.line {
                        parser.advance()
                    }
                    try parser.fail("';'")
                }
                parser.advance()
            } else {
                guard parser.isCh(";") else {
                    try parser.fail("';'")
                }
                parser.advance()
            }
            rules.append(RailroadRule(name: name, definition: definition))
        }
    }
    if rules.isEmpty {
        throw MermaidParserError.syntax(
            message: "Error parsing railroad diagram: expecting a rule",
            line: 1, column: 1, snippet: "")
    }
    return RailroadChart(title: title, notation: notation, rules: rules)
}
