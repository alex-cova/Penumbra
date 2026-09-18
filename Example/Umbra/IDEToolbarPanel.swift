import SwiftUI

/// Full-width chrome row above the sidebar/editor split. Owns the traffic-light gutter, the
/// sidebar toggle, a breadcrumb for the active document, the Goto Anything field, and pane
/// actions (preview/close; split lives in the tab's right-click menu) — the one place in the
/// window that reserves `Spacing.trafficLightsInset`, so nothing below it needs to.
struct IDEToolbarPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            IDEToolbarSidebarToggle(
                isSidebarVisible: workspace.isSidebarVisible,
                action: workspace.toggleSidebar
            )

            IDEToolbarBreadcrumb(headerContext: workspace.headerContext)
                .padding(.leading, IDEAppearance.Spacing.xs)

            Spacer(minLength: IDEAppearance.Spacing.sm)

            IDEToolbarPaletteField(action: workspace.showQuickOpen)

            Spacer(minLength: IDEAppearance.Spacing.sm)

            IDEToolbarActionCluster(
                showsCloseGroup: workspace.tabsByPane.count > 1,
                isMarkdownFile: workspace.statusLanguage == "markdown",
                isMarkdownPreviewVisible: workspace.isMarkdownPreviewVisible,
                toggleMarkdownPreview: workspace.toggleMarkdownPreview,
                exportMarkdownPreviewToPDF: workspace.exportMarkdownPreviewToPDF,
                closeActivePane: workspace.closeActivePane
            )
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .frame(height: IDEAppearance.Spacing.toolbarHeight)
        .frame(maxWidth: .infinity)
        .background(IDEAppearance.ColorToken.toolbar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)
        }
        .focusable(false)
    }
}

private struct IDEToolbarSidebarToggle: View {
    let isSidebarVisible: Bool
    let action: () -> Void

    var body: some View {
        IDEToolbarIconButton(
            systemName: "sidebar.leading",
            isActive: isSidebarVisible,
            help: isSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
            action: action
        )
    }
}

private struct IDEToolbarBreadcrumb: View {
    let headerContext: IDEHeaderContext

    var body: some View {
        let components = headerContext.components
        if !components.isEmpty {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    let isLast = index == components.count - 1
                    if index > 0 {
                        Image(systemName: "chevron.compact.right")
                            .font(.system(size: IDEAppearance.IconSize.breadcrumbChevron, weight: .medium))
                            .foregroundStyle(IDEAppearance.ColorToken.muted.opacity(0.6))
                            .accessibilityHidden(true)
                    }
                    Text(component)
                        .font(isLast ? IDEAppearance.Typography.tabLabel.weight(.medium) : IDEAppearance.Typography.tabLabel)
                        .foregroundStyle(isLast ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    private var accessibilityLabel: String {
        let path = headerContext.components.joined(separator: ", ")
        return headerContext.isDirty ? "\(path), edited" : path
    }
}

private struct IDEToolbarPaletteField: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: IDEAppearance.IconSize.searchGlyph))
                Text("Search")
                    .font(IDEAppearance.Typography.caption)
                Spacer()
                Text("⌘P")
                    .font(IDEAppearance.Typography.caption)
            }
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .frame(width: IDEAppearance.Spacing.searchFieldWidth, height: IDEAppearance.Spacing.searchFieldHeight)
            .background {
                RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous)
                    .fill(IDEAppearance.ColorToken.controlHover)
                    .stroke(IDEAppearance.ColorToken.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("Go to File")
        .accessibilityLabel("Search")
    }
}

private struct IDEToolbarActionCluster: View {
    let showsCloseGroup: Bool
    let isMarkdownFile: Bool
    let isMarkdownPreviewVisible: Bool
    let toggleMarkdownPreview: () -> Void
    let exportMarkdownPreviewToPDF: () -> Void
    let closeActivePane: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            if isMarkdownFile {
                IDEToolbarIconButton(
                    systemName: "play.fill",
                    help: "Toggle Markdown Preview",
                    action: toggleMarkdownPreview
                )
                if isMarkdownPreviewVisible {
                    IDEToolbarIconButton(
                        systemName: "square.and.arrow.down",
                        help: "Export Markdown Preview to PDF",
                        action: exportMarkdownPreviewToPDF
                    )
                }
            }
            if showsCloseGroup {
                IDEToolbarIconButton(
                    systemName: "rectangle.slash",
                    help: "Close Editor Group",
                    action: closeActivePane
                )
            }
        }
    }
}

/// Shared glyph-button chrome for the toolbar row: a fixed square hit target, muted by default,
/// brightening on hover so every action in the row reads as one family.
private struct IDEToolbarIconButton: View {
    let systemName: String
    var isActive = false
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: IDEAppearance.IconSize.toolbarGlyph, weight: .medium))
                .foregroundStyle(isActive || isHovering ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .frame(width: IDEAppearance.Spacing.iconButton, height: IDEAppearance.Spacing.iconButton)
                .background(isHovering ? IDEAppearance.ColorToken.controlHover : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(.isButton)
        .focusable(false)
    }
}

#Preview {
    IDEToolbarPanel()
        .environment({
            let workspace = IDEWorkspace()
            let paneID = UUID()
            workspace.tabsByPane = [
                paneID: [
                    IDETabRow(id: UUID(), title: "Editor.swift", isDirty: true, isSelected: true)
                ]
            ]
            workspace.headerContext = IDEHeaderContext(
                components: ["src", "ui", "Editor.swift"],
                isDirty: true
            )
            return workspace
        }())
        .frame(width: 720)
        .preferredColorScheme(.dark)
}
