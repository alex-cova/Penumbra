import EditorIntelligence
import SwiftUI

/// The bottom panel's Problems tab: diagnostics grouped by file, errors first. Clicking a row opens
/// the file at the problem.
struct IDEProblemsPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var collapsedFiles: Set<URL> = []

    var body: some View {
        let files = workspace.problems.files
        Group {
            if files.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(files) { file in
                            fileHeader(file)
                            if !collapsedFiles.contains(file.url) {
                                ForEach(file.rows) { row in
                                    IDEProblemRowView(row: row) { workspace.openProblem(row) }
                                }
                            }
                        }
                    }
                    .padding(.vertical, IDEAppearance.Spacing.xs)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 18))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text(workspace.problems.isEmpty ? "No problems" : "No problems match the filter")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func fileHeader(_ file: ProblemFile) -> some View {
        let isCollapsed = collapsedFiles.contains(file.url)
        return Button {
            if isCollapsed {
                collapsedFiles.remove(file.url)
            } else {
                collapsedFiles.insert(file.url)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                Text(file.url.lastPathComponent)
                    .font(IDEAppearance.Typography.sidebarHeader)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                Text(workspace.displayDirectory(of: file.url))
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 8)
                Text("\(file.rows.count)")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(file.url.lastPathComponent), \(file.rows.count) problems")
        .accessibilityHint(isCollapsed ? "Expand" : "Collapse")
    }
}

private struct IDEProblemRowView: View {
    let row: ProblemRow
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: IDEProblemStyle.symbol(for: row.diagnostic.severity))
                    .font(.system(size: 11))
                    .foregroundStyle(IDEProblemStyle.color(for: row.diagnostic.severity))
                    .frame(width: 14)
                Text(row.diagnostic.message)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Text(row.diagnostic.source)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Text("\(row.diagnostic.range.start.line + 1):\(row.diagnostic.range.start.column + 1)")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .padding(.leading, IDEAppearance.Spacing.xl)
            .padding(.trailing, IDEAppearance.Spacing.md)
            .padding(.vertical, 3)
            .background(isHovering ? IDEAppearance.ColorToken.controlHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(row.diagnostic.severity) at line \(row.diagnostic.range.start.line + 1): \(row.diagnostic.message)")
    }
}

enum IDEProblemStyle {
    static func symbol(for severity: DiagnosticSeverity) -> String {
        switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .information: "info.circle.fill"
        case .hint: "lightbulb.fill"
        }
    }

    static func color(for severity: DiagnosticSeverity) -> Color {
        switch severity {
        case .error: IDEAppearance.ColorToken.error
        case .warning: IDEAppearance.ColorToken.gitModified
        case .information: IDEAppearance.ColorToken.accent
        case .hint: IDEAppearance.ColorToken.muted
        }
    }
}

/// Header controls shown in place of the shell's restart button while the Problems tab is selected.
struct IDEProblemsControls: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            filterToggle(.error, count: workspace.problems.errorCount, label: "Errors")
            filterToggle(.warning, count: workspace.problems.warningCount, label: "Warnings")
        }
    }

    private func filterToggle(_ severity: DiagnosticSeverity, count: Int, label: String) -> some View {
        let isOn = workspace.problems.visibleSeverities.contains(severity)
        return Button {
            workspace.problems.toggleSeverity(severity)
            if severity == .warning {
                // Informational and hint rows ride along with the warning filter.
                workspace.problems.toggleSeverity(.information)
                workspace.problems.toggleSeverity(.hint)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: IDEProblemStyle.symbol(for: severity))
                    .font(.system(size: 10))
                Text("\(count)")
                    .font(IDEAppearance.Typography.monoSmall)
            }
            .foregroundStyle(isOn ? IDEProblemStyle.color(for: severity) : IDEAppearance.ColorToken.muted.opacity(0.6))
        }
        .buttonStyle(.borderless)
        .help("\(isOn ? "Hide" : "Show") \(label)")
        .accessibilityLabel("\(label): \(count)")
        .accessibilityValue(isOn ? "shown" : "hidden")
    }
}

/// Tab-strip item for the Problems tab, with an error/warning badge.
struct IDEProblemsTabItem: View {
    let isSelected: Bool
    let errorCount: Int
    let warningCount: Int
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: errorCount > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(errorCount > 0 ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
                .frame(width: 12)
            Text(title)
                .foregroundStyle(isSelected ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .font(IDEAppearance.Typography.tabLabel.weight(isSelected ? .medium : .regular))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        .overlay(alignment: .top) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(IDEAppearance.ColorToken.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Problems, \(errorCount) errors, \(warningCount) warnings")
        .accessibilityAddTraits(.isButton)
        .focusable(false)
    }

    private var title: String {
        let total = errorCount + warningCount
        return total > 0 ? "Problems · \(total)" : "Problems"
    }

    private var backgroundColor: Color {
        if isSelected { return IDEAppearance.ColorToken.tabActive }
        if isHovering { return IDEAppearance.ColorToken.tabHover }
        return IDEAppearance.ColorToken.tabInactive
    }
}
