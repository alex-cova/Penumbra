import JavaIntelligence
import SwiftUI

/// The bottom panel's Coverage tab: the report's packages and classes with line, branch and
/// method percentages, a filter, and the actions that belong to the last run.
struct IDECoveragePanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var collapsedPackages: Set<String> = []
    @State private var selectedID: String?
    @State private var typeahead = IDETypeaheadBuffer()
    @FocusState private var isFilterFocused: Bool
    @FocusState private var isListFocused: Bool

    var body: some View {
        let controller = workspace.coverage
        VStack(spacing: 0) {
            toolbar(controller)
            Divider()
            if controller.snapshot == nil {
                placeholder(controller)
            } else {
                list(controller)
            }
        }
    }

    private func toolbar(_ controller: IDECoverageController) -> some View {
        @Bindable var controller = controller
        return HStack(spacing: IDEAppearance.Spacing.xs) {
            IDEIconButton(systemImage: "arrow.up.circle", help: "Previous Uncovered Line") {
                workspace.goToUncoveredLine(forward: false)
            }
            .disabled(!controller.hasLiveCoverage(forFile: workspace.runEligibility.runFileURL))
            IDEIconButton(systemImage: "arrow.down.circle", help: "Next Uncovered Line") {
                workspace.goToUncoveredLine(forward: true)
            }
            .disabled(!controller.hasLiveCoverage(forFile: workspace.runEligibility.runFileURL))
            Divider().frame(height: 14)
            IDEIconMenu(
                systemImage: controller.maximumPercent == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill",
                help: "Filter by Coverage",
                isActive: controller.maximumPercent != nil
            ) {
                Button("Show All Classes") { controller.maximumPercent = nil }
                Divider()
                ForEach([50, 80, 100], id: \.self) { limit in
                    Button("Only Below \(limit)%") { controller.maximumPercent = limit }
                }
            }
            TextField("Filter", text: $controller.filterText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 180)
                .focused($isFilterFocused)
                .onKeyPress(.downArrow) {
                    isListFocused = true
                    return .handled
                }
                .onKeyPress(.escape) {
                    if controller.filterText.isEmpty { return .ignored }
                    controller.filterText = ""
                    return .handled
                }
            IDEIconMenu(systemImage: "ellipsis.circle", help: "Coverage Actions") {
                Button("Export HTML Report…") { workspace.exportCoverageHTML() }
                    .disabled(workspace.coverage.snapshot?.supportsJaCoCoExports != true)
                Button("Export XML Report…") { workspace.exportCoverageXML() }
                    .disabled(workspace.coverage.snapshot?.supportsJaCoCoExports != true)
                Divider()
                Button("Clear Coverage") { workspace.clearCoverage() }
            }
            .disabled(controller.snapshot == nil)
            if controller.isBuilding {
                ProgressView().controlSize(.mini)
            }
            if let summary = controller.summary {
                Text(summary)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let snapshot = controller.snapshot {
                Text(snapshot.label)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
            }
        }
        .ideIconButtonSize(.compact)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .frame(height: IDEAppearance.Spacing.iconButton + 4)
    }

    private func placeholder(_ controller: IDECoverageController) -> some View {
        VStack(spacing: IDEAppearance.Spacing.xs) {
            if controller.isBuilding { ProgressView().controlSize(.small) }
            Text(controller.progressMessage ?? controller.failureMessage ?? "No coverage yet. Use Run ▸ Run with Coverage.")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(controller.failureMessage == nil ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.error)
                .multilineTextAlignment(.center)
                .padding(.horizontal, IDEAppearance.Spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(_ controller: IDECoverageController) -> some View {
        let packages = controller.packageRows
        let rows = IDECoverageTree.flatten(packages: packages, collapsed: collapsedPackages)
        return Group {
            if packages.isEmpty {
                Text("No classes match.")
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusable()
                    .focused($isListFocused)
                    .focusEffectDisabled()
                    .onKeyPress(.escape) {
                        workspace.focusActiveEditor()
                        return .handled
                    }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                IDECoverageTreeRow(
                                    row: row,
                                    isSelected: selectedID == row.id,
                                    onSelect: { select(row, toggling: row.canDisclose) },
                                    onActivate: { activate(row) },
                                    menu: { coverageMenu(row) }
                                )
                                .id(row.id)
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
                    .onChange(of: selectedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func coverageMenu(_ row: IDECoverageTree.Row) -> some View {
        if case .klass = row.kind {
            Button("Open Source") {
                if let url = row.sourceURL { workspace.openCoverageSource(url, line: 1) }
            }
            .disabled(row.sourceURL == nil)
            Button("Go to First Uncovered Line") {
                if let url = row.sourceURL { workspace.openCoverageSource(url, line: row.firstMissedLine ?? 1) }
            }
            .disabled(row.sourceURL == nil || row.firstMissedLine == nil)
        }
    }

    private func handleKey(_ press: KeyPress, rows: [IDECoverageTree.Row]) -> KeyPress.Result {
        let current = rows.first { $0.id == selectedID }
        switch press.key {
        case .upArrow:
            typeahead.reset()
            if let id = IDEListNeighbor.move(selectedID, in: rows.map(\.id), by: -1) {
                selectedID = id
                isListFocused = true
            }
            return .handled
        case .downArrow:
            typeahead.reset()
            if let id = IDEListNeighbor.move(selectedID, in: rows.map(\.id), by: 1) {
                selectedID = id
                isListFocused = true
            }
            return .handled
        case .rightArrow:
            typeahead.reset()
            guard let current, current.canDisclose, !current.isExpanded else { return .ignored }
            toggle(current)
            return .handled
        case .leftArrow:
            typeahead.reset()
            guard let current else { return .ignored }
            if current.canDisclose, current.isExpanded {
                toggle(current)
            } else if let index = rows.firstIndex(where: { $0.id == current.id }),
                      let parent = rows[..<index].last(where: { $0.depth < current.depth }) {
                selectedID = parent.id
            }
            return .handled
        case .return:
            typeahead.reset()
            guard let current else { return .ignored }
            activate(current)
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
            if let row = IDEListTypeahead.match(
                query: typeahead.typed(character), in: rows, selected: current, title: \.title
            ) {
                selectedID = row.id
                isListFocused = true
            }
            return .handled
        }
    }

    private func select(_ row: IDECoverageTree.Row, toggling: Bool) {
        selectedID = row.id
        isListFocused = true
        if toggling { toggle(row) }
    }

    private func toggle(_ row: IDECoverageTree.Row) {
        guard case .package(let name) = row.kind else { return }
        if collapsedPackages.contains(name) {
            collapsedPackages.remove(name)
        } else {
            collapsedPackages.insert(name)
        }
    }

    private func activate(_ row: IDECoverageTree.Row) {
        select(row, toggling: false)
        switch row.kind {
        case .package:
            toggle(row)
        case .klass:
            guard let url = row.sourceURL else { return }
            workspace.openCoverageSource(url, line: row.firstMissedLine ?? 1)
        }
    }

}

private struct IDECoverageTreeRow<Menu: View>: View {
    let row: IDECoverageTree.Row
    let isSelected: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void
    @ViewBuilder let menu: () -> Menu

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            if row.canDisclose {
                IDEDisclosureChevron(isExpanded: row.isExpanded, size: 10, width: 12)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else {
                Spacer().frame(width: 12)
            }
            Image(systemName: row.depth == 0 ? "shippingbox" : "c.square")
                .font(.system(size: 11))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text(row.title)
                .font(row.depth == 0 ? IDEAppearance.Typography.body.weight(.medium) : IDEAppearance.Typography.body)
                .lineLimit(1)
            Spacer(minLength: 0)
            if row.depth == 1 {
                percentText(row.branchPercent, label: "branches")
                percentText(row.methodPercent, label: "methods")
            }
            IDECoverageBar(percent: row.linePercent)
        }
        .padding(.leading, CGFloat(row.depth) * 14 + CGFloat(IDEAppearance.Spacing.sm))
        .padding(.trailing, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.tight)
        .background(isSelected ? IDEAppearance.ColorToken.selection : (isHovering ? IDEAppearance.ColorToken.controlHover : Color.clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onActivate)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .contextMenu { menu() }
        .help(row.depth == 1 ? "\(row.linesCovered) of \(row.linesTotal) lines covered" : row.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.title)
        .accessibilityValue(row.canDisclose ? (row.isExpanded ? "Expanded" : "Collapsed") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func percentText(_ percent: Int?, label: String) -> some View {
        Text(percent.map { "\($0)%" } ?? "–")
            .font(IDEAppearance.Typography.monoSmall)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .frame(width: 44, alignment: .trailing)
            .help("\(label)")
    }
}

/// `73%` and a bar, green from 80, yellow from 50, red below.
struct IDECoverageBar: View {
    let percent: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(percent.map { "\($0)%" } ?? "–")
                .font(IDEAppearance.Typography.monoSmall)
                .frame(width: 40, alignment: .trailing)
            ZStack(alignment: .leading) {
                Capsule().fill(IDEAppearance.ColorToken.muted.opacity(IDEAppearance.Opacity.tintWash))
                if let percent {
                    Capsule().fill(color(percent)).frame(width: 60 * CGFloat(percent) / 100)
                }
            }
            .frame(width: 60, height: 6)
        }
    }

    private func color(_ percent: Int) -> Color {
        percent >= 80 ? .green : (percent >= 50 ? .yellow : .red)
    }
}

/// Tab-strip item for the Coverage tab.
struct IDECoverageTabItem: View {
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        IDEChromeTabItem(title: title, isSelected: isSelected, onSelect: onSelect) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        } trailing: {
            EmptyView()
        }
    }
}
