import JavaIntelligence
import SwiftUI

/// The bottom panel's Coverage tab: the report's packages and classes with line, branch and
/// method percentages, a filter, and the actions that belong to the last run.
struct IDECoveragePanel: View {
    @Environment(IDEWorkspace.self) private var workspace

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
            .disabled(!controller.hasLiveCoverage(forFile: workspace.runFileURL))
            IDEIconButton(systemImage: "arrow.down.circle", help: "Next Uncovered Line") {
                workspace.goToUncoveredLine(forward: true)
            }
            .disabled(!controller.hasLiveCoverage(forFile: workspace.runFileURL))
            Divider().frame(height: 14)
            Menu {
                Button("Show All Classes") { controller.maximumPercent = nil }
                Divider()
                ForEach([50, 80, 100], id: \.self) { limit in
                    Button("Only Below \(limit)%") { controller.maximumPercent = limit }
                }
            } label: {
                Image(systemName: controller.maximumPercent == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Filter by Coverage")
            TextField("Filter", text: $controller.filterText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 180)
            Menu {
                Button("Export HTML Report…") { workspace.exportCoverageHTML() }
                    .disabled(workspace.coverage.snapshot?.supportsJaCoCoExports != true)
                Button("Export XML Report…") { workspace.exportCoverageXML() }
                    .disabled(workspace.coverage.snapshot?.supportsJaCoCoExports != true)
                Divider()
                Button("Clear Coverage") { workspace.clearCoverage() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
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
        let rows = controller.packageRows
        return List {
            ForEach(rows) { package in
                DisclosureGroup {
                    ForEach(package.classes) { item in
                        classRow(item)
                    }
                } label: {
                    HStack(spacing: IDEAppearance.Spacing.xs) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 11))
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                        Text(package.name).font(IDEAppearance.Typography.body.weight(.medium))
                        Spacer(minLength: 0)
                        IDECoverageBar(percent: package.linePercent)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if rows.isEmpty {
                Text("No classes match.")
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
    }

    private func classRow(_ item: IDECoverageController.ClassRow) -> some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "c.square")
                .font(.system(size: 11))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text(item.displayName)
                .font(IDEAppearance.Typography.body)
                .lineLimit(1)
            Spacer(minLength: 0)
            percentText(item.branchPercent, label: "branches")
            percentText(item.methodPercent, label: "methods")
            IDECoverageBar(percent: item.linePercent)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard let url = item.sourceURL else { return }
            workspace.openCoverageSource(url, line: item.firstMissedLine ?? 1)
        }
        .contextMenu {
            Button("Open Source") {
                if let url = item.sourceURL { workspace.openCoverageSource(url, line: 1) }
            }
            .disabled(item.sourceURL == nil)
            Button("Go to First Uncovered Line") {
                if let url = item.sourceURL { workspace.openCoverageSource(url, line: item.firstMissedLine ?? 1) }
            }
            .disabled(item.sourceURL == nil || item.firstMissedLine == nil)
        }
        .help("\(item.lines.covered) of \(item.lines.total) lines covered")
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
