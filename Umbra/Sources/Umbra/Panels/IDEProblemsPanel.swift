import EditorIntelligence
import SwiftUI

/// The bottom panel's Problems tab: diagnostics grouped by file, errors first. Clicking a row opens
/// the file at the problem.
struct IDEProblemsPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var collapsedFiles: Set<URL> = []
    @State private var selectedRowID: String?
    @State private var typeahead = IDETypeaheadBuffer()
    @FocusState private var isListFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            IDEProblemsTabStrip(runs: runs)
            Divider()
            if let run = runs.selectedRun {
                IDEInspectionResultsView(run: run)
                    .id(run.id)
            } else {
                IDEProblemListView(
                    selectedRowID: $selectedRowID,
                    collapsedFiles: $collapsedFiles,
                    typeahead: $typeahead,
                    isListFocused: $isListFocused
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var runs: IDEInspectionRunsStore { workspace.inspectionRuns }
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

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            IDEProblemSeverityFilterToggle(severity: .error, count: workspace.problems.errorCount, label: "Errors")
            IDEProblemSeverityFilterToggle(severity: .warning, count: workspace.problems.warningCount, label: "Warnings")
            IDEProblemsCopyButton()
        }
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
                .font(.system(size: IDEAppearance.IconSize.smallGlyph))
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


