import EditorIntelligence
import JavaIntelligence
import SwiftIntelligence
import SwiftUI

/// The bottom panel's Problems tab: diagnostics grouped by file, errors first. Clicking a row opens
/// the file at the problem.
struct IDEProblemsPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var collapsedFiles: Set<URL> = []

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            tabContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var runs: IDEInspectionRunsStore { workspace.inspectionRuns }

    @ViewBuilder
    private var tabContent: some View {
        if let run = runs.selectedRun {
            IDEInspectionResultsView(run: run)
                .id(run.id)
        } else {
            problemList
        }
    }

    /// File · Project Errors · one tab per Inspect Code run.
    private var tabStrip: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            stripButton("File", isSelected: runs.selection == .file) { runs.selection = .file }
            stripButton("Project Errors", isSelected: runs.selection == .project) { runs.selection = .project }
            ForEach(runs.runs) { run in
                HStack(spacing: 4) {
                    if run.state == .running { ProgressView().controlSize(.mini) }
                    Text(run.title)
                        .font(IDEAppearance.Typography.tabLabel)
                        .lineLimit(1)
                        .foregroundStyle(runs.selection == .run(run.id) ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                    Button { runs.close(run.id) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)) }
                        .buttonStyle(.borderless)
                        .help("Close results")
                }
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.vertical, 3)
                .background(runs.selection == .run(run.id) ? IDEAppearance.ColorToken.tabActive : .clear)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                .contentShape(Rectangle())
                .accessibilityAddTraits(.isButton)
                .onTapGesture { runs.selection = .run(run.id) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, 3)
    }

    private func stripButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(IDEAppearance.Typography.tabLabel.weight(isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.vertical, 3)
                .background(isSelected ? IDEAppearance.ColorToken.tabActive : .clear)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var problemList: some View {
        let (files, messages) = workspace.visibleProblems()
        return Group {
            if files.isEmpty && messages.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(messages) { message in
                            IDEBuildMessageRowView(message: message) { workspace.openBuildMessage(message) }
                        }
                        ForEach(files) { file in
                            fileHeader(file)
                            if !collapsedFiles.contains(file.url) {
                                ForEach(file.rows) { row in
                                    IDEProblemRowView(
                                        row: row,
                                        onOpen: { workspace.openProblem(row) },
                                        onFix: { workspace.fixProblemWithAgent(row) },
                                        onQuickFixes: [IDEProblemsStore.inspectionSource, SwiftInspection.diagnosticSource].contains(row.diagnostic.source) ? { showQuickFixes(for: row) } : nil,
                                        rule: inspectionRule(for: row),
                                        onDisableRule: { workspace.disableInspection(code: $0.code, language: $0.language) },
                                        onQuietRule: { info in
                                            if let rule = JavaInspectionRule(code: info.code) {
                                                workspace.inspections.edit { $0.setSeverity(.noHighlighting, for: rule) }
                                            }
                                        },
                                        onConfigureRule: { workspace.showInspectionSettings(code: $0.code, language: $0.language) }
                                    )
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

    /// The inspection behind a row, nil for compiler, editor and tool diagnostics.
    private func inspectionRule(for row: ProblemRow) -> IDEInspectionRuleInfo? {
        guard let code = row.diagnostic.code else { return nil }
        switch row.diagnostic.source {
        case IDEProblemsStore.inspectionSource: return IDEInspectionLanguage.java.rule(code: code)
        case SwiftInspection.diagnosticSource: return IDEInspectionLanguage.swift.rule(code: code)
        default: return nil
        }
    }

    private func showQuickFixes(for row: ProblemRow) {
        Task {
            let actions = await workspace.quickFixes(for: row)
            workspace.popUpQuickFixMenu(actions) { action in
                Task { await workspace.applyQuickFix(action, to: row.url) }
            }
        }
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
        return IDEFileGroupHeader(
            name: file.url.lastPathComponent, directory: workspace.displayDirectory(of: file.url),
            count: file.rows.count, noun: "problems", isCollapsed: isCollapsed
        ) {
            if isCollapsed { collapsedFiles.remove(file.url) } else { collapsedFiles.insert(file.url) }
        }
    }
}

/// A project-level Gradle message (failed task, dependency error, test summary).
private struct IDEBuildMessageRowView: View {
    let message: GradleProblem
    let onOpen: () -> Void

    @State private var isHovering = false

    private var severity: DiagnosticSeverity {
        switch message.severity {
        case .error: .error
        case .warning: .warning
        case .info: .information
        }
    }

    private var text: String {
        // Plain until the host wires `onShowTestResults`; the suffix names what a click does.
        message.kind == .testFailures ? "\(message.message) \u{2014} Show Test Results" : message.message
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: IDEProblemStyle.symbol(for: severity))
                    .font(.system(size: 11))
                    .foregroundStyle(IDEProblemStyle.color(for: severity))
                    .frame(width: 14)
                Text(text)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if let task = message.task {
                    Text(task)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, 3)
            .background(isHovering ? IDEAppearance.ColorToken.controlHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Build \(IDEProblemStyle.label(for: severity)): \(text)")
    }
}

private struct IDEProblemRowView: View {
    let row: ProblemRow
    let onOpen: () -> Void
    let onFix: () -> Void
    var onQuickFixes: (() -> Void)?
    var rule: IDEInspectionRuleInfo?
    var onDisableRule: ((IDEInspectionRuleInfo) -> Void)?
    var onQuietRule: ((IDEInspectionRuleInfo) -> Void)?
    var onConfigureRule: ((IDEInspectionRuleInfo) -> Void)?

    @State private var isHovering = false

    /// An inspection's readable name; the tool's id for everything else.
    private var origin: String { IDEProblemsMarkdown.origin(of: row.diagnostic) }

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
                Text(origin)
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
        .overlay(alignment: .trailing) {
            if isHovering {
                Button(action: onFix) {
                    Label("Fix with Agent", systemImage: "sparkles")
                        .font(IDEAppearance.Typography.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, IDEAppearance.Spacing.xxs)
                        .background(IDEAppearance.ColorToken.card, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .padding(.trailing, IDEAppearance.Spacing.md)
                .help("Ask the agent to fix this problem")
            }
        }
        .contextMenu {
            if let onQuickFixes { Button("Show Quick Fixes…", action: onQuickFixes) }
            Button("Fix with Agent", systemImage: "sparkles", action: onFix)
            if let rule {
                Divider()
                Button("Disable Inspection \u{201C}\(rule.title)\u{201D}") { onDisableRule?(rule) }
                // Swift has no "No highlighting" level yet.
                if rule.language == .java { Button("Turn Off Highlighting (Keep Fix)") { onQuietRule?(rule) } }
                Button("Edit Inspection Settings…") { onConfigureRule?(rule) }
            }
        }
        .accessibilityLabel("\(IDEProblemStyle.label(for: row.diagnostic.severity)) at line \(row.diagnostic.range.start.line + 1): \(row.diagnostic.message)")
    }
}

enum IDEProblemStyle {
    static func label(for severity: DiagnosticSeverity) -> String {
        switch severity {
        case .error: "Error"
        case .warning: "Warning"
        case .information: "Information"
        case .hint: "Hint"
        }
    }

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
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            filterToggle(.error, count: workspace.problems.errorCount, label: "Errors")
            filterToggle(.warning, count: workspace.problems.warningCount, label: "Warnings")
            copyButton
        }
    }

    /// Copies the list as shown; an Inspect Code run has its own results view, so it is not exported here.
    private var copyButton: some View {
        let visible = workspace.visibleProblems()
        let canCopy = workspace.inspectionRuns.selectedRun == nil && !(visible.files.isEmpty && visible.messages.isEmpty)
        return Button {
            workspace.copyProblemsAsMarkdown()
            didCopy = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                didCopy = false
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .buttonStyle(.borderless)
        .disabled(!canCopy)
        .help("Copy Problems as Markdown")
        .accessibilityLabel("Copy Problems as Markdown")
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
            .foregroundStyle(isOn ? IDEProblemStyle.color(for: severity) : IDEAppearance.ColorToken.muted.opacity(IDEAppearance.Opacity.dimmed))
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

    var body: some View {
        IDEChromeTabItem(
            title: title,
            isSelected: isSelected,
            accessibilityLabel: "Problems, \(errorCount) errors, \(warningCount) warnings",
            onSelect: onSelect
        ) {
            Image(systemName: errorCount > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(errorCount > 0 ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
        } trailing: {
            EmptyView()
        }
    }

    private var title: String {
        let total = errorCount + warningCount
        return total > 0 ? "Problems · \(total)" : "Problems"
    }
}
