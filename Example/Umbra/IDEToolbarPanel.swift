import SwiftUI

/// Full-width chrome row above the sidebar/editor split. Owns the traffic-light gutter, the
/// sidebar toggle, a breadcrumb for the active document, the Goto Anything field, and pane
/// actions (split/preview/close) — the one place in the window that reserves
/// `Spacing.trafficLightsInset`, so nothing below it needs to.
struct IDEToolbarPanel: View {
    @EnvironmentObject private var workspace: IDEWorkspace

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Spacer()
                .frame(width: IDEAppearance.Spacing.trafficLightsInset)

            sidebarToggleButton

            breadcrumb
                .padding(.leading, IDEAppearance.Spacing.xs)

            Spacer(minLength: IDEAppearance.Spacing.sm)

            paletteField

            Spacer(minLength: IDEAppearance.Spacing.sm)

            actionCluster
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

    private var sidebarToggleButton: some View {
        IDEToolbarIconButton(
            systemName: "sidebar.leading",
            isActive: workspace.isSidebarVisible,
            help: workspace.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
            action: workspace.toggleSidebar
        )
    }

    @ViewBuilder
    private var breadcrumb: some View {
        let components = workspace.headerContext.components
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
                if workspace.headerContext.isDirty {
                    Circle()
                        .fill(IDEAppearance.ColorToken.accent)
                        .frame(width: IDEAppearance.Spacing.dirtyDotSize, height: IDEAppearance.Spacing.dirtyDotSize)
                        .accessibilityHidden(true)
                }
            }
            .lineLimit(1)
            .truncationMode(.head)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(breadcrumbAccessibilityLabel(components: components, isDirty: workspace.headerContext.isDirty))
        }
    }

    private func breadcrumbAccessibilityLabel(components: [String], isDirty: Bool) -> String {
        let path = components.joined(separator: ", ")
        return isDirty ? "\(path), edited" : path
    }

    private var paletteField: some View {
        Button(action: workspace.showQuickOpen) {
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
            .background(IDEAppearance.ColorToken.controlHover)
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous)
                    .strokeBorder(IDEAppearance.ColorToken.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("Go to File")
        .accessibilityLabel("Search")
    }

    private var actionCluster: some View {
        HStack(spacing: 2) {
            IDEToolbarIconButton(
                systemName: "doc.richtext",
                help: "Toggle Markdown Preview",
                action: workspace.toggleMarkdownPreview
            )
            IDEToolbarIconButton(
                systemName: "rectangle.split.2x1",
                help: "Split Editor Right",
                action: workspace.splitRight
            )
            IDEToolbarIconButton(
                systemName: "rectangle.split.1x2",
                help: "Split Editor Down",
                action: workspace.splitDown
            )
            if workspace.tabsByPane.count > 1 {
                IDEToolbarIconButton(
                    systemName: "rectangle.slash",
                    help: "Close Editor Group",
                    action: workspace.closeActivePane
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
        .environmentObject({
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
