import SwiftUI

struct IDEStatusBarPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            IDEStatusBarBreadcrumb(
                headerContext: workspace.headerContext,
                onSelect: workspace.selectBreadcrumb
            )
            // Takes whatever the row has left, so the trailing items never truncate.
            .layoutPriority(-1)
            Spacer(minLength: IDEAppearance.Spacing.md)
            httpStatus
            problemsStatus
            if workspace.statusSelectionLength > 0 {
                Text("\(workspace.statusSelectionLength) selected  ·")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            Text(leadingSummary)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text("·")
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            if workspace.showsJDKPicker {
                IDEJDKStatusItem()
                Text("·")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            if !workspace.showsWelcome {
                syntaxPicker
                Text("·")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            Text(trailingSummary)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .frame(height: IDEAppearance.Spacing.statusBarHeight)
        .background(IDEAppearance.ColorToken.window)
        .focusable(false)
    }

    /// Sublime-style clickable syntax name for untitled or extensionless files. Known file types
    /// (e.g. `.java`) show a read-only label instead.
    @ViewBuilder
    private var syntaxPicker: some View {
        let label = Text(
            IDELanguageSupport.displayName(
                forIdentifier: workspace.statusLanguage.isEmpty ? nil : workspace.statusLanguage
            )
        )
        .font(IDEAppearance.Typography.monoSmall)
        .foregroundStyle(IDEAppearance.ColorToken.muted)

        if workspace.canChangeActiveLanguage {
            Menu {
                ForEach(IDELanguageSupport.selectableSyntaxes) { option in
                    Button(option.displayName) {
                        workspace.setLanguage(identifier: option.id)
                    }
                }
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } else {
            label
                .fixedSize()
        }
    }

    /// Error and warning totals; clicking opens the Problems tab. Hidden while there is nothing to
    /// report so a clean project keeps a quiet status bar.
    @ViewBuilder
    private var problemsStatus: some View {
        let errors = workspace.problems.errorCount
        let warnings = workspace.problems.warningCount
        if errors > 0 || warnings > 0 {
            Button {
                workspace.showProblems()
            } label: {
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundStyle(errors > 0 ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
                        Text("\(errors)")
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(warnings > 0 ? IDEAppearance.ColorToken.gitModified : IDEAppearance.ColorToken.muted)
                        Text("\(warnings)")
                    }
                }
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            .buttonStyle(.borderless)
            .help("Show Problems")
            .accessibilityLabel("\(errors) errors, \(warnings) warnings")
            .accessibilityHint("Show Problems")
            Text("·")
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
    }

    @ViewBuilder
    private var httpStatus: some View {
        if workspace.statusLanguage == "http" {
            if workspace.httpSupport.isSending {
                Button("Sending HTTP request…") {
                    workspace.showHTTPResponse()
                }
                .buttonStyle(.borderless)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                Text("·")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else if let statusCode = workspace.httpSupport.lastStatusCode,
                      let duration = workspace.httpSupport.lastDuration {
                Button("HTTP \(statusCode) (\(Int(duration * 1000)) ms)") {
                    workspace.showHTTPResponse()
                }
                .buttonStyle(.borderless)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                Text("·")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
    }

    private var leadingSummary: String {
        "Ln \(workspace.statusLine)  ·  Col \(workspace.statusColumn)"
    }

    private var trailingSummary: String {
        var parts = ["UTF-8", "LF"]
        if workspace.isTerminalVisible {
            parts.append("Terminal")
        }
        return parts.joined(separator: "  ·  ")
    }
}

private struct IDEStatusBarBreadcrumb: View {
    let headerContext: IDEHeaderContext
    let onSelect: (IDEBreadcrumbItem) -> Void

    var body: some View {
        let items = headerContext.items
        if !items.isEmpty {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right")
                            .font(.system(size: IDEAppearance.IconSize.breadcrumbChevron, weight: .medium))
                            .foregroundStyle(IDEAppearance.ColorToken.muted.opacity(0.6))
                            .accessibilityHidden(true)
                    }
                    IDEStatusBarBreadcrumbSegment(
                        item: item,
                        isLast: index == items.count - 1,
                        action: { onSelect(item) }
                    )
                }
                if headerContext.isDirty {
                    Circle()
                        .fill(IDEAppearance.ColorToken.accent)
                        .frame(width: IDEAppearance.Spacing.dirtyDotSize, height: IDEAppearance.Spacing.dirtyDotSize)
                        .accessibilityHidden(true)
                }
            }
            .lineLimit(1)
            .truncationMode(.head)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Breadcrumb")
        }
    }
}

private struct IDEStatusBarBreadcrumbSegment: View {
    let item: IDEBreadcrumbItem
    let isLast: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(item.title)
                .font(isLast ? IDEAppearance.Typography.tabLabel.weight(.medium) : IDEAppearance.Typography.tabLabel)
                .foregroundStyle(isLast || isHovering ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(item.title)
        .accessibilityHint(help)
        .accessibilityAddTraits(.isButton)
        .focusable(false)
    }

    private var help: String {
        switch item.target {
        case .folder:
            "Reveal \(item.title) in Explorer"
        case .symbol:
            "Go to \(item.title)"
        }
    }
}

#Preview {
    IDEStatusBarPanel()
        .environment({
            let workspace = IDEWorkspace()
            workspace.statusLine = 12
            workspace.statusColumn = 4
            workspace.statusLanguage = "javascript"
            return workspace
        }())
        .preferredColorScheme(.dark)
}
