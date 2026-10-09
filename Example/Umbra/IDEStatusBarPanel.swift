import Penumbra
import SwiftUI

struct IDEStatusBarPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        let _ = workspace.uiColorSchemeEpoch
        HStack(spacing: IDEAppearance.Spacing.sm) {
            IDEStatusBarBreadcrumb(
                headerContext: workspace.headerContext,
                makeMenu: workspace.breadcrumbMenu,
                onSelect: workspace.selectBreadcrumb
            )
            // Takes whatever the row has left, so the trailing items never truncate.
            .layoutPriority(-1)
            Spacer(minLength: IDEAppearance.Spacing.md)
            moduleItems(.leading)
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
            moduleItems(.trailing)
            if !workspace.showsWelcome {
                syntaxPicker
                Text("·")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            encodingPicker
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

    /// The file's encoding. Clicking it reads the file again in another encoding ("Reopen") or
    /// converts the file as it is saved ("Save with Encoding").
    @ViewBuilder
    private var encodingPicker: some View {
        let current = workspace.statusEncoding
        let label = Text(current.shortName)
            .font(IDEAppearance.Typography.monoSmall)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
        if workspace.canChangeActiveEncoding {
            Menu {
                Menu("Reopen with Encoding") {
                    ForEach(TextFileEncoding.all) { encoding in
                        Toggle(encoding.displayName, isOn: Binding(
                            get: { encoding == current },
                            set: { _ in workspace.reopenActiveDocument(with: encoding) }
                        ))
                    }
                }
                .disabled(!workspace.canReopenActiveWithEncoding)
                Menu("Save with Encoding") {
                    ForEach(TextFileEncoding.all) { encoding in
                        Toggle(encoding.displayName, isOn: Binding(
                            get: { encoding == current },
                            set: { _ in Task { await workspace.saveActiveDocument(with: encoding) } }
                        ))
                    }
                }
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Change the file encoding")
            .accessibilityLabel("File encoding \(current.displayName)")
        } else {
            label
                .fixedSize()
        }
        Text("·")
            .font(IDEAppearance.Typography.monoSmall)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
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

    /// What the language modules put in the bar (`IDELanguageModule.statusItems`), each followed by
    /// the bar's separator.
    @ViewBuilder
    private func moduleItems(_ placement: IDEStatusItem.Placement) -> some View {
        ForEach(workspace.statusItems(placement)) { item in
            item.content
            Text("·")
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
    }

    private var leadingSummary: String {
        "Ln \(workspace.statusLine)  ·  Col \(workspace.statusColumn)"
    }

    private var trailingSummary: String {
        var parts = ["LF"]
        if workspace.isTerminalVisible {
            parts.append("Terminal")
        }
        return parts.joined(separator: "  ·  ")
    }
}

private struct IDEStatusBarBreadcrumb: View {
    let headerContext: IDEHeaderContext
    let makeMenu: (IDEBreadcrumbItem) async -> NSMenu?
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
                        makeMenu: makeMenu,
                        onSelect: onSelect
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
    let makeMenu: (IDEBreadcrumbItem) async -> NSMenu?
    let onSelect: (IDEBreadcrumbItem) -> Void

    @State private var isHovering = false
    @State private var isMenuOpen = false
    @State private var anchor = IDEMenuAnchor()

    var body: some View {
        Button(action: openMenu) {
            Text(item.title)
                .font(isLast ? IDEAppearance.Typography.tabLabel.weight(.medium) : IDEAppearance.Typography.tabLabel)
                .foregroundStyle(isLast || isHovering || isMenuOpen ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .padding(.horizontal, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isMenuOpen || isHovering ? IDEAppearance.ColorToken.controlHover : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .background(IDEMenuAnchorView(anchor: anchor))
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(item.title)
        .accessibilityHint(help)
        .accessibilityAddTraits(.isButton)
        .focusable(false)
    }

    private func openMenu() {
        Task { @MainActor in
            guard let menu = await makeMenu(item) else {
                onSelect(item)
                return
            }
            isMenuOpen = true
            // Returns once the menu closes.
            anchor.popUp(menu)
            isMenuOpen = false
        }
    }

    private var help: String {
        switch item.target {
        case .folder:
            "Show the contents of \(item.title)"
        case .file:
            "Switch to another file in this folder"
        case .symbol:
            "Show the members around \(item.title)"
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
        .preferredColorScheme(IDEAppearance.preferredColorScheme)
}
