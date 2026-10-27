import Foundation

/// Turns a run's findings into the tree its tab shows. Pure: no view and no disk.
enum IDEInspectionResultsTree {
    enum Grouping: String, CaseIterable, Identifiable {
        case inspection = "Inspection"
        case severity = "Severity"
        case directory = "Directory"
        var id: String { rawValue }
    }

    struct Node: Identifiable, Hashable {
        enum Kind: Hashable {
            case group
            case file
            case problem
        }

        let id: String
        let kind: Kind
        let title: String
        let subtitle: String?
        /// Problems below (1 for a problem).
        let count: Int
        let severity: IDEInspectionSeverity?
        let ruleCode: String?
        let url: URL?
        let entry: IDEInspectionRun.Entry?
        let isResolved: Bool
        let isExcluded: Bool
        var children: [Node]
    }

    struct Options {
        var grouping: Grouping = .inspection
        var hidesResolved = false
        var showsExcluded = false
        var filter = ""
        var projectRoot: URL?
        var language: IDEInspectionLanguage = .java
    }

    static func severityRank(_ severity: IDEInspectionSeverity) -> Int {
        switch severity {
        case .error: 0
        case .warning: 1
        case .weakWarning: 2
        case .info: 3
        case .noHighlighting: 4
        }
    }

    static func severityTitle(_ severity: IDEInspectionSeverity) -> String {
        switch severity {
        case .error: "Errors"
        case .warning: "Warnings"
        case .weakWarning: "Weak warnings"
        case .info: "Considerations"
        case .noHighlighting: "No highlighting"
        }
    }

    static func build(
        entries: [IDEInspectionRun.Entry],
        resolved: [IDEInspectionRun.Entry],
        excluded: Set<String>,
        options: Options
    ) -> [Node] {
        var items: [(entry: IDEInspectionRun.Entry, isResolved: Bool)] = entries.map { ($0, false) }
        if !options.hidesResolved { items.append(contentsOf: resolved.map { ($0, true) }) }
        let query = options.filter.trimmingCharacters(in: .whitespaces)
        items = items.filter { item in
            if !options.showsExcluded, excluded.contains(item.entry.key) { return false }
            guard !query.isEmpty else { return true }
            let rule = options.language.rule(code: item.entry.inspection.id)?.title ?? item.entry.inspection.id
            return item.entry.inspection.message.localizedCaseInsensitiveContains(query)
                || rule.localizedCaseInsensitiveContains(query)
                || item.entry.url.lastPathComponent.localizedCaseInsensitiveContains(query)
        }
        guard !items.isEmpty else { return [] }

        func problemNode(_ item: (entry: IDEInspectionRun.Entry, isResolved: Bool), parent: String) -> Node {
            let inspection = item.entry.inspection
            return Node(
                id: "\(parent)/\(item.entry.key)", kind: .problem, title: inspection.message,
                subtitle: "\(inspection.range.start.line + 1):\(inspection.range.start.column + 1)",
                count: 1, severity: inspection.severity, ruleCode: inspection.id, url: item.entry.url, entry: item.entry,
                isResolved: item.isResolved, isExcluded: excluded.contains(item.entry.key), children: []
            )
        }

        func fileNodes(_ group: [(entry: IDEInspectionRun.Entry, isResolved: Bool)], parent: String) -> [Node] {
            let byFile = Dictionary(grouping: group, by: { $0.entry.url.standardizedFileURL })
            return byFile.keys.sorted { $0.path < $1.path }.map { url in
                let id = "\(parent)/\(url.path)"
                let sorted = byFile[url]!.sorted(by: position)
                return Node(
                    id: id, kind: .file, title: url.lastPathComponent, subtitle: relativeDirectory(of: url, root: options.projectRoot),
                    count: sorted.count, severity: nil, ruleCode: nil, url: url, entry: nil,
                    isResolved: false, isExcluded: false, children: sorted.map { problemNode($0, parent: id) }
                )
            }
        }

        func position(
            _ a: (entry: IDEInspectionRun.Entry, isResolved: Bool), _ b: (entry: IDEInspectionRun.Entry, isResolved: Bool)
        ) -> Bool {
            let (l, r) = (a.entry.inspection.range.start, b.entry.inspection.range.start)
            return (l.line, l.column) < (r.line, r.column)
        }

        func ruleNodes(_ group: [(entry: IDEInspectionRun.Entry, isResolved: Bool)], parent: String) -> [Node] {
            let byRule = Dictionary(grouping: group, by: { $0.entry.inspection.id })
            return byRule.keys.sorted { title(of: $0) < title(of: $1) }.map { code in
                let id = "\(parent)/rule:\(code)"
                let members = byRule[code]!
                return Node(
                    id: id, kind: .group, title: title(of: code), subtitle: options.language.rule(code: code)?.groupTitle,
                    count: members.count, severity: nil, ruleCode: code, url: nil, entry: nil,
                    isResolved: false, isExcluded: false, children: fileNodes(members, parent: id)
                )
            }
        }

        func title(of code: String) -> String { options.language.rule(code: code)?.title ?? code }

        switch options.grouping {
        case .inspection:
            return ruleNodes(items, parent: "i")
        case .severity:
            let bySeverity = Dictionary(grouping: items, by: { $0.entry.inspection.severity })
            return bySeverity.keys.sorted { severityRank($0) < severityRank($1) }.map { severity in
                let id = "s:\(severity.rawValue)"
                let members = bySeverity[severity]!
                return Node(
                    id: id, kind: .group, title: severityTitle(severity), subtitle: nil, count: members.count,
                    severity: severity, ruleCode: nil, url: nil, entry: nil, isResolved: false, isExcluded: false,
                    children: ruleNodes(members, parent: id)
                )
            }
        case .directory:
            let byDirectory = Dictionary(grouping: items, by: {
                relativeDirectory(of: $0.entry.url, root: options.projectRoot) ?? "/"
            })
            return byDirectory.keys.sorted().map { directory in
                let id = "d:\(directory)"
                let members = byDirectory[directory]!
                return Node(
                    id: id, kind: .group, title: directory.isEmpty ? "(project root)" : directory, subtitle: nil,
                    count: members.count, severity: nil, ruleCode: nil, url: nil, entry: nil,
                    isResolved: false, isExcluded: false, children: fileNodes(members, parent: id)
                )
            }
        }
    }

    private static func relativeDirectory(of url: URL, root: URL?) -> String? {
        let directory = url.standardizedFileURL.deletingLastPathComponent().path
        guard let root = root?.standardizedFileURL.path else { return directory }
        if directory == root { return "" }
        if directory.hasPrefix(root + "/") { return String(directory.dropFirst(root.count + 1)) }
        return directory
    }

    /// The visible rows: a node and how deep it sits, skipping what a collapsed group hides.
    static func flatten(_ nodes: [Node], collapsed: Set<String>) -> [(node: Node, depth: Int)] {
        var rows: [(Node, Int)] = []
        func visit(_ node: Node, depth: Int) {
            rows.append((node, depth))
            guard node.kind != .problem, !collapsed.contains(node.id) else { return }
            for child in node.children { visit(child, depth: depth + 1) }
        }
        for node in nodes { visit(node, depth: 0) }
        return rows.map { (node: $0.0, depth: $0.1) }
    }

    /// Every problem node, in display order (for Previous / Next).
    static func problems(in nodes: [Node]) -> [Node] {
        var result: [Node] = []
        func visit(_ node: Node) {
            if node.kind == .problem { result.append(node) } else { node.children.forEach(visit) }
        }
        nodes.forEach(visit)
        return result
    }
}
