import AppKit
import EditorIntelligence
import JavaIntelligence
import SwiftUI

/// One Inspect Code run's tab in Problems: a grouped tree (inspection › file › problem), a
/// toolbar and, beside it, what the selection is and what can be done about it.
struct IDEInspectionResultsView: View {
    @Environment(IDEWorkspace.self) private var workspace
    let run: IDEInspectionRun

    @State private var grouping: IDEInspectionResultsTree.Grouping = .inspection
    @State private var hidesResolved = false
    @State private var showsExcluded = false
    @State private var filter = ""
    @State private var collapsed: Set<String> = []
    @State private var selection: String?

    private var options: IDEInspectionResultsTree.Options {
        IDEInspectionResultsTree.Options(
            grouping: grouping, hidesResolved: hidesResolved, showsExcluded: showsExcluded, filter: filter,
            projectRoot: workspace.project.rootURL
        )
    }

    private var tree: [IDEInspectionResultsTree.Node] {
        IDEInspectionResultsTree.build(
            entries: run.entries, resolved: run.resolved, excluded: run.excludedKeys, options: options
        )
    }

    var body: some View {
        let nodes = tree
        let rows = IDEInspectionResultsTree.flatten(nodes, collapsed: collapsed)
        VStack(spacing: 0) {
            toolbar(nodes: nodes)
            Divider()
            if rows.isEmpty {
                emptyState
            } else {
                SplitPanes(minPrimary: 260, minSecondary: 220, storageKey: "umbra.inspections.split") {
                    list(rows)
                } secondary: {
                    detail(nodes: nodes)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Toolbar

    private func toolbar(nodes: [IDEInspectionResultsTree.Node]) -> some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            if run.state == .running {
                ProgressView().controlSize(.small)
                Text("Analyzing \(run.done) of \(run.total)")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Button { run.cancel() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.borderless)
                    .help("Stop")
            } else {
                Button { workspace.rerunInspection(run) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Rerun inspection")
                Text(summary)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            Divider().frame(height: 14)
            Button { move(-1, in: nodes) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.upArrow, modifiers: [.control, .option])
                .help("Previous problem")
            Button { move(1, in: nodes) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.downArrow, modifiers: [.control, .option])
                .help("Next problem")
            Spacer(minLength: IDEAppearance.Spacing.sm)
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
            Menu {
                Picker("Group by", selection: $grouping) {
                    ForEach(IDEInspectionResultsTree.Grouping.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Hide Resolved", isOn: $hidesResolved)
                Toggle("Show Excluded", isOn: $showsExcluded)
                Divider()
                Button("Expand All") { collapsed = [] }
                Button("Collapse All") { collapsed = Set(allGroupIDs(nodes)) }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("View options")
            Menu {
                Button("SARIF…") { workspace.exportInspectionRun(run, as: .sarif) }
                Button("HTML…") { workspace.exportInspectionRun(run, as: .html) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Export results")
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    private var summary: String {
        let count = run.entries.count
        let files = run.results.count
        let state = run.state == .cancelled ? " (stopped)" : ""
        if count == 0 { return "No problems found\(state)" }
        return "\(count) problem\(count == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")\(state)"
    }

    private var emptyState: some View {
        VStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: run.state == .running ? "magnifyingglass" : "checkmark.circle")
                .font(.system(size: 18))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text(run.state == .running ? "Analyzing…" : "No problems found")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func allGroupIDs(_ nodes: [IDEInspectionResultsTree.Node]) -> [String] {
        nodes.flatMap { node -> [String] in
            node.kind == .problem ? [] : [node.id] + allGroupIDs(node.children)
        }
    }

    private func move(_ delta: Int, in nodes: [IDEInspectionResultsTree.Node]) {
        let problems = IDEInspectionResultsTree.problems(in: nodes)
        guard !problems.isEmpty else { return }
        let current = problems.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : problems.count)
        let next = min(max(current + delta, 0), problems.count - 1)
        select(problems[next])
    }

    private func select(_ node: IDEInspectionResultsTree.Node) {
        selection = node.id
        if let entry = node.entry { workspace.openInspectionResult(entry) }
    }

    // MARK: List

    private func list(_ rows: [(node: IDEInspectionResultsTree.Node, depth: Int)]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.node.id) { row in
                    rowView(row.node, depth: row.depth)
                }
            }
            .padding(.vertical, IDEAppearance.Spacing.xs)
        }
    }

    private func rowView(_ node: IDEInspectionResultsTree.Node, depth: Int) -> some View {
        let isSelected = selection == node.id
        return HStack(spacing: 6) {
            if node.kind == .problem {
                Image(systemName: IDEProblemStyle.symbol(for: Self.diagnosticSeverity(node.severity)))
                    .font(.system(size: 11))
                    .foregroundStyle(IDEProblemStyle.color(for: Self.diagnosticSeverity(node.severity)))
                    .frame(width: 14)
            } else {
                Image(systemName: collapsed.contains(node.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 14)
                if node.kind == .file { Image(systemName: "doc.text").font(.system(size: 10)) }
            }
            Text(node.title)
                .font(node.kind == .problem ? IDEAppearance.Typography.body : IDEAppearance.Typography.sidebarHeader)
                .foregroundStyle(node.isExcluded || node.isResolved ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.foreground)
                .strikethrough(node.isExcluded || node.isResolved)
                .lineLimit(1)
            if let subtitle = node.subtitle, node.kind != .problem {
                Text(subtitle)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if node.kind == .problem {
                Text(node.subtitle ?? "")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else {
                Text("\(node.count)")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
        .padding(.leading, IDEAppearance.Spacing.md + CGFloat(depth) * 14)
        .padding(.trailing, IDEAppearance.Spacing.md)
        .padding(.vertical, 3)
        .background(isSelected ? IDEAppearance.ColorToken.controlHover : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if node.kind == .problem { select(node) } else { toggle(node) }
        }
        .accessibilityAddTraits(.isButton)
        .onTapGesture {
            if node.kind == .problem { select(node) } else {
                selection = node.id
                toggle(node)
            }
        }
        .contextMenu { contextMenu(for: node) }
        .accessibilityLabel(node.kind == .problem ? "Problem: \(node.title)" : "\(node.title), \(node.count) problems")
    }

    private func toggle(_ node: IDEInspectionResultsTree.Node) {
        if collapsed.contains(node.id) { collapsed.remove(node.id) } else { collapsed.insert(node.id) }
    }

    private static func diagnosticSeverity(_ severity: JavaInspection.Severity?) -> DiagnosticSeverity {
        switch severity {
        case .error: .error
        case .warning: .warning
        case .weakWarning, .noHighlighting: .hint
        case .info: .information
        case nil: .information
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func contextMenu(for node: IDEInspectionResultsTree.Node) -> some View {
        if let entry = node.entry {
            Button("Jump to Source") { workspace.openInspectionResult(entry) }
            Button("Show Quick Fixes…") { showQuickFixes(for: entry) }
            Divider()
            if run.excludedKeys.contains(entry.key) {
                Button("Include") { run.include([entry.key]) }
            } else {
                Button("Exclude") { run.exclude([entry.key]) }
            }
            if let rule = JavaInspectionRule(code: entry.inspection.id) {
                Button("Disable Inspection \u{201C}\(rule.title)\u{201D}") { workspace.disableInspection(rule) }
                Button("Edit Inspection Settings…") { workspace.showInspectionSettings(for: rule) }
                Button("Run Inspection on…") { workspace.presentRunInspectionByName(rule: rule) }
            }
            Divider()
            Button("Copy Description") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.inspection.message, forType: .string)
            }
            Button("Fix with Agent", systemImage: "sparkles") {
                workspace.fixProblemWithAgent(ProblemRow(url: entry.url, diagnostic: entry.inspection.asDiagnostic()))
            }
        } else if node.kind == .group, let code = node.ruleCode, let rule = JavaInspectionRule(code: code) {
            if rule.hasQuickFix {
                Button("Apply Fix to \(node.count) Problem\(node.count == 1 ? "" : "s")") {
                    Task { await workspace.applyInspectionFixAll(rule: rule, in: run) }
                }
            }
            Button("Exclude All") { run.exclude(keys(in: node)) }
            Button("Include All") { run.include(keys(in: node)) }
            Divider()
            Button("Disable Inspection") { workspace.disableInspection(rule) }
            Button("Edit Inspection Settings…") { workspace.showInspectionSettings(for: rule) }
            Button("Run Inspection on…") { workspace.presentRunInspectionByName(rule: rule) }
        } else if node.kind == .file, let url = node.url {
            Button("Open File") { workspace.openInspectionResult(firstEntry(in: node) ?? fallbackEntry(url)) }
            Button("Exclude All") { run.exclude(keys(in: node)) }
            Button("Include All") { run.include(keys(in: node)) }
        }
    }

    private func keys(in node: IDEInspectionResultsTree.Node) -> [String] {
        IDEInspectionResultsTree.problems(in: [node]).compactMap { $0.entry?.key }
    }

    private func firstEntry(in node: IDEInspectionResultsTree.Node) -> IDEInspectionRun.Entry? {
        IDEInspectionResultsTree.problems(in: [node]).first?.entry
    }

    private func fallbackEntry(_ url: URL) -> IDEInspectionRun.Entry {
        let zero = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let inspection = JavaInspection(
            id: "", message: "", severity: .info, range: EditorIntelligence.TextRange(start: zero, end: zero)
        )
        return IDEInspectionRun.Entry(key: url.path, url: url, inspection: inspection)
    }

    /// Loads the fixes of a result (they need its file's text) and shows them as a menu at the pointer.
    private func showQuickFixes(for entry: IDEInspectionRun.Entry) {
        Task {
            let actions = await workspace.quickFixes(for: entry)
            workspace.popUpQuickFixMenu(actions) { [workspace, run] action in
                Task { await workspace.applyInspectionFix(action, to: entry, in: run) }
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(nodes: [IDEInspectionResultsTree.Node]) -> some View {
        let selected = selection.flatMap { id in find(id, in: nodes) }
        ScrollView {
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
                if let selected, let code = selected.ruleCode, let rule = JavaInspectionRule(code: code) {
                    Text(rule.title).font(IDEAppearance.Typography.sidebarHeader)
                    Text(rule.group.title).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted)
                    Text(rule.summary).font(IDEAppearance.Typography.body)
                    if let entry = selected.entry {
                        Text(entry.inspection.message).font(IDEAppearance.Typography.body)
                        Text(entry.url.lastPathComponent + ":" + (selected.subtitle ?? ""))
                            .font(IDEAppearance.Typography.monoSmall)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                    }
                    actions(for: selected, rule: rule)
                } else {
                    Text("Select a problem or an inspection to see what can be done about it.")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(IDEAppearance.Spacing.md)
        }
    }

    @ViewBuilder
    private func actions(for node: IDEInspectionResultsTree.Node, rule: JavaInspectionRule) -> some View {
        let count = node.kind == .problem ? 1 : node.count
        VStack(alignment: .leading, spacing: 6) {
            if let entry = node.entry {
                Button("Show Quick Fixes…") { showQuickFixes(for: entry) }
            }
            if rule.hasQuickFix {
                Button("Apply Fix to All \(run.entries.filter { $0.inspection.id == rule.code }.count) Problems of This Kind") {
                    Task { await workspace.applyInspectionFixAll(rule: rule, in: run) }
                }
            }
            Button("Disable Inspection") { workspace.disableInspection(rule) }
            Button("Edit Inspection Settings…") { workspace.showInspectionSettings(for: rule) }
            Button("Run Inspection on…") { workspace.presentRunInspectionByName(rule: rule) }
            Text("\(count) problem\(count == 1 ? "" : "s") selected")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .buttonStyle(.link)
    }

    private func find(_ id: String, in nodes: [IDEInspectionResultsTree.Node]) -> IDEInspectionResultsTree.Node? {
        for node in nodes {
            if node.id == id { return node }
            if let found = find(id, in: node.children) { return found }
        }
        return nil
    }
}

/// Lets an `NSMenuItem` run a closure: the item holds it through `representedObject`.
final class IDEMenuClosure: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) { self.handler = handler }

    @objc func fire() { handler() }
}
