import AppKit
import EditorIntelligence
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
    @State private var typeahead = IDETypeaheadBuffer()
    @FocusState private var isFilterFocused: Bool
    @FocusState private var isListFocused: Bool

    private var options: IDEInspectionResultsTree.Options {
        IDEInspectionResultsTree.Options(
            grouping: grouping, hidesResolved: hidesResolved, showsExcluded: showsExcluded, filter: filter,
            projectRoot: workspace.project.rootURL, language: run.language
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
        HStack(spacing: IDEAppearance.Spacing.xs) {
            if run.state == .running {
                ProgressView().controlSize(.small)
                Text("Analyzing \(run.done) of \(run.total)")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                IDEIconButton(systemImage: "stop.fill", help: "Stop", tint: .red) { run.cancel() }
            } else {
                IDEIconButton(systemImage: "arrow.clockwise", help: "Rerun inspection") {
                    workspace.rerunInspection(run)
                }
                .keyboardShortcut("r", modifiers: .command)
                Text(summary)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            Divider().frame(height: 14)
            IDEIconButton(systemImage: "chevron.up", help: "Previous problem") { move(-1, in: nodes) }
                .keyboardShortcut(.upArrow, modifiers: [.control, .option])
            IDEIconButton(systemImage: "chevron.down", help: "Next problem") { move(1, in: nodes) }
                .keyboardShortcut(.downArrow, modifiers: [.control, .option])
            Spacer(minLength: IDEAppearance.Spacing.sm)
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 140)
                .focused($isFilterFocused)
                .onKeyPress(.downArrow) {
                    isListFocused = true
                    return .handled
                }
                .onKeyPress(.escape) {
                    if filter.isEmpty { return .ignored }
                    filter = ""
                    return .handled
                }
            IDEIconMenu(systemImage: "line.3.horizontal.decrease.circle", help: "View options") {
                Picker("Group by", selection: $grouping) {
                    ForEach(IDEInspectionResultsTree.Grouping.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Hide Resolved", isOn: $hidesResolved)
                Toggle("Show Excluded", isOn: $showsExcluded)
                Divider()
                Button("Expand All") { collapsed = [] }
                Button("Collapse All") { collapsed = Set(allGroupIDs(nodes)) }
            }
            IDEIconMenu(systemImage: "square.and.arrow.up", help: "Export results") {
                Button("SARIF…") { workspace.exportInspectionRun(run, as: .sarif) }
                Button("HTML…") { workspace.exportInspectionRun(run, as: .html) }
            }
        }
        .ideIconButtonSize(.compact)
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
        IDEEmptyState(
            symbol: run.state == .running ? "magnifyingglass" : "checkmark.circle",
            title: run.state == .running ? "Analyzing…" : "No problems found"
        )
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.node.id) { row in
                        rowView(row.node, depth: row.depth)
                            .id(row.node.id)
                    }
                }
                .padding(.vertical, IDEAppearance.Spacing.xs)
            }
            .focusable()
            .focused($isListFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in
                handleKey(press, rows: rows)
            }
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func handleKey(
        _ press: KeyPress, rows: [(node: IDEInspectionResultsTree.Node, depth: Int)]
    ) -> KeyPress.Result {
        let current = rows.first { $0.node.id == selection }
        switch press.key {
        case .upArrow, .downArrow:
            typeahead.reset()
            let delta = press.key == .downArrow ? 1 : -1
            if let id = IDEListNeighbor.move(selection, in: rows.map(\.node.id), by: delta) {
                highlight(id)
            }
            return .handled
        case .rightArrow:
            typeahead.reset()
            guard let current, current.node.kind != .problem, collapsed.contains(current.node.id) else { return .ignored }
            toggle(current.node)
            return .handled
        case .leftArrow:
            typeahead.reset()
            guard let current else { return .ignored }
            if current.node.kind != .problem, !collapsed.contains(current.node.id) {
                toggle(current.node)
            } else if let index = rows.firstIndex(where: { $0.node.id == current.node.id }),
                      let parent = rows[..<index].last(where: { $0.depth < current.depth }) {
                highlight(parent.node.id)
            }
            return .handled
        case .return:
            typeahead.reset()
            guard let current else { return .ignored }
            activate(current.node)
            return .handled
        case .escape:
            typeahead.reset()
            if isFilterFocused {
                isFilterFocused = false
                return .handled
            }
            workspace.focusActiveEditor()
            return .handled
        default:
            guard let character = IDEListTypeahead.character(from: press) else { return .ignored }
            if let node = IDEListTypeahead.match(
                query: typeahead.typed(character), in: rows.map(\.node), selected: current?.node, title: \.title
            ) {
                highlight(node.id)
            }
            return .handled
        }
    }

    private func highlight(_ id: String) {
        selection = id
        isListFocused = true
    }

    private func activate(_ node: IDEInspectionResultsTree.Node) {
        if node.kind == .problem {
            select(node)
        } else {
            highlight(node.id)
            toggle(node)
        }
        isListFocused = true
    }

    private func rowView(_ node: IDEInspectionResultsTree.Node, depth: Int) -> some View {
        IDEInspectionResultRow(
            node: node,
            depth: depth,
            isSelected: selection == node.id,
            isExpanded: !collapsed.contains(node.id),
            onSelect: {
                if node.kind == .problem {
                    select(node)
                } else {
                    highlight(node.id)
                    toggle(node)
                }
            },
            onActivate: { activate(node) },
            menu: { contextMenu(for: node) }
        )
    }

    private func toggle(_ node: IDEInspectionResultsTree.Node) {
        if collapsed.contains(node.id) { collapsed.remove(node.id) } else { collapsed.insert(node.id) }
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
            if let rule = run.language.rule(code: entry.inspection.id) {
                Button("Disable Inspection \u{201C}\(rule.title)\u{201D}") { workspace.disableInspection(code: rule.code, language: rule.language) }
                Button("Edit Inspection Settings…") { workspace.showInspectionSettings(code: rule.code, language: rule.language) }
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
        } else if node.kind == .group, let code = node.ruleCode, let rule = run.language.rule(code: code) {
            if rule.hasQuickFix {
                Button("Apply Fix to \(node.count) Problem\(node.count == 1 ? "" : "s")") {
                    Task { await workspace.applyInspectionFixAll(ruleCode: rule.code, in: run) }
                }
            }
            Button("Exclude All") { run.exclude(keys(in: node)) }
            Button("Include All") { run.include(keys(in: node)) }
            Divider()
            Button("Disable Inspection") { workspace.disableInspection(code: rule.code, language: rule.language) }
            Button("Edit Inspection Settings…") { workspace.showInspectionSettings(code: rule.code, language: rule.language) }
            Button("Run Inspection on…") { workspace.presentRunInspectionByName(rule: rule) }
        } else if node.kind == .file, let url = node.url {
            Button("Open File") {
                if let entry = firstEntry(in: node) { workspace.openInspectionResult(entry) } else { workspace.openInspectionFile(url) }
            }
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
                if let selected, let code = selected.ruleCode, let rule = run.language.rule(code: code) {
                    Text(rule.title).font(IDEAppearance.Typography.sidebarHeader)
                    Text(rule.groupTitle).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted)
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
    private func actions(for node: IDEInspectionResultsTree.Node, rule: IDEInspectionRuleInfo) -> some View {
        let count = node.kind == .problem ? 1 : node.count
        VStack(alignment: .leading, spacing: 6) {
            if let entry = node.entry {
                Button("Show Quick Fixes…") { showQuickFixes(for: entry) }
            }
            if rule.hasQuickFix {
                Button("Apply Fix to All \(run.entries.filter { $0.inspection.id == rule.code }.count) Problems of This Kind") {
                    Task { await workspace.applyInspectionFixAll(ruleCode: rule.code, in: run) }
                }
            }
            Button("Disable Inspection") { workspace.disableInspection(code: rule.code, language: rule.language) }
            Button("Edit Inspection Settings…") { workspace.showInspectionSettings(code: rule.code, language: rule.language) }
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

private struct IDEInspectionResultRow<Menu: View>: View {
    let node: IDEInspectionResultsTree.Node
    let depth: Int
    let isSelected: Bool
    let isExpanded: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void
    @ViewBuilder let menu: () -> Menu

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            if node.kind == .problem {
                Image(systemName: IDEProblemStyle.symbol(for: Self.diagnosticSeverity(node.severity)))
                    .font(.system(size: 11))
                    .foregroundStyle(IDEProblemStyle.color(for: Self.diagnosticSeverity(node.severity)))
                    .frame(width: 14)
            } else {
                IDEDisclosureChevron(isExpanded: isExpanded, width: 14)
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
        .background(isSelected ? IDEAppearance.ColorToken.selection : (isHovering ? IDEAppearance.ColorToken.controlHover : Color.clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onActivate)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .contextMenu { menu() }
        .accessibilityLabel(node.kind == .problem ? "Problem: \(node.title)" : "\(node.title), \(node.count) problems")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private static func diagnosticSeverity(_ severity: IDEInspectionSeverity?) -> DiagnosticSeverity {
        switch severity {
        case .error: .error
        case .warning: .warning
        case .weakWarning, .noHighlighting: .hint
        case .info: .information
        case nil: .information
        }
    }
}

/// Lets an `NSMenuItem` run a closure: the item holds it through `representedObject`.
final class IDEMenuClosure: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) { self.handler = handler }

    @objc func fire() { handler() }
}
