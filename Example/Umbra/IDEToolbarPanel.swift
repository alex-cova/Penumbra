import EditorIntelligence
import SwiftUI

/// Full-width chrome row above the sidebar/editor split. Owns the traffic-light gutter, the
/// sidebar toggle, a path-and-symbol breadcrumb for the active document (the tab already shows
/// the filename), and pane actions (search, preview, close; split lives in the tab's right-click
/// menu) — the one place in the window that reserves `Spacing.trafficLightsInset`, so nothing
/// below it needs to.
struct IDEToolbarPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            IDEToolbarSidebarToggle(
                isSidebarVisible: workspace.isSidebarVisible,
                action: workspace.toggleSidebar
            )

            if workspace.javaSupport.isGradleProject {
                IDEToolbarGradleSidebarToggle(
                    isSidebarVisible: workspace.isGradleSidebarVisible,
                    action: workspace.toggleGradleSidebar
                )
            }

            IDEToolbarBreadcrumb(
                headerContext: workspace.headerContext,
                onSelect: workspace.selectBreadcrumb
            )
            .padding(.leading, IDEAppearance.Spacing.xs)

            Spacer(minLength: IDEAppearance.Spacing.sm)

            IDEToolbarActionCluster(
                showsCloseGroup: workspace.tabsByPane.count > 1,
                isMarkdownFile: workspace.statusLanguage == "markdown",
                isMarkdownPreviewVisible: workspace.isMarkdownPreviewVisible,
                isGradleProject: workspace.javaSupport.isGradleProject,
                isJavaRunnable: workspace.javaFileCanRun,
                javaRunHelp: workspace.javaRunHelp,
                isHTTPFile: workspace.statusLanguage == "http",
                isHTTPSendable: workspace.httpFileCanSend,
                isTerminalVisible: workspace.isTerminalVisible,
                showQuickOpen: workspace.showQuickOpen,
                toggleMarkdownPreview: workspace.toggleMarkdownPreview,
                buildGradle: workspace.buildGradleProject,
                runJava: workspace.runActiveJava,
                sendHTTPRequest: workspace.sendActiveHTTPRequest,
                toggleTerminal: workspace.toggleTerminal,
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

private struct IDEToolbarGradleSidebarToggle: View {
    let isSidebarVisible: Bool
    let action: () -> Void

    var body: some View {
        IDEToolbarIconButton(
            systemName: "sidebar.trailing",
            isActive: isSidebarVisible,
            help: isSidebarVisible ? "Hide Gradle Sidebar" : "Show Gradle Sidebar",
            action: action
        )
    }
}

private struct IDEToolbarBreadcrumb: View {
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
                    IDEToolbarBreadcrumbSegment(
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

private struct IDEToolbarBreadcrumbSegment: View {
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

private struct IDEToolbarActionCluster: View {
    let showsCloseGroup: Bool
    let isMarkdownFile: Bool
    let isMarkdownPreviewVisible: Bool
    let isGradleProject: Bool
    let isJavaRunnable: Bool
    let javaRunHelp: String
    let isHTTPFile: Bool
    let isHTTPSendable: Bool
    let isTerminalVisible: Bool
    let showQuickOpen: () -> Void
    let toggleMarkdownPreview: () -> Void
    let buildGradle: () -> Void
    let runJava: () -> Void
    let sendHTTPRequest: () -> Void
    let toggleTerminal: () -> Void
    let exportMarkdownPreviewToPDF: () -> Void
    let closeActivePane: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            IDEToolbarIconButton(
                systemName: "magnifyingglass",
                help: "Go to File",
                action: showQuickOpen
            )
            IDEToolbarIconButton(
                systemName: "terminal",
                isActive: isTerminalVisible,
                help: "Toggle Terminal",
                action: toggleTerminal
            )
            
            if showsCloseGroup {
                IDEToolbarIconButton(
                    systemName: "rectangle.slash",
                    help: "Close Editor Group",
                    action: closeActivePane
                )
            }
            
            if isGradleProject {
                IDEToolbarIconButton(
                    systemName: "hammer",
                    help: "Build Project",
                    action: buildGradle
                )
            }

            if isJavaRunnable {
                IDEToolbarIconButton(
                    systemName: "play.fill",
                    tint: IDEAppearance.ColorToken.run,
                    help: javaRunHelp,
                    action: runJava
                )
            }

            if isHTTPFile && isHTTPSendable {
                IDEToolbarIconButton(
                    systemName: "paperplane.fill",
                    tint: IDEAppearance.ColorToken.accent,
                    help: "Send HTTP Request",
                    action: sendHTTPRequest
                )
            }

            if isMarkdownFile {
                if isMarkdownPreviewVisible {
                    IDEToolbarIconButton(
                        systemName: "square.and.arrow.down",
                        help: "Export Markdown Preview to PDF",
                        action: exportMarkdownPreviewToPDF
                    )
                }
                IDEToolbarIconButton(
                    systemName: isMarkdownPreviewVisible ? "stop.fill" : "play.fill",
                    isActive: isMarkdownPreviewVisible,
                    help: "Toggle Markdown Preview",
                    action: toggleMarkdownPreview
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
    var tint: Color? = nil
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: IDEAppearance.IconSize.toolbarGlyph, weight: .medium))
                .foregroundStyle(tint ?? (isActive || isHovering ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted))
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
                pathItems: [
                    IDEBreadcrumbItem(id: "folder:src", title: "src", target: .folder(URL(fileURLWithPath: "/src"))),
                    IDEBreadcrumbItem(id: "folder:ui", title: "ui", target: .folder(URL(fileURLWithPath: "/src/ui")))
                ],
                symbolItems: [
                    IDEBreadcrumbItem(
                        id: "symbol:Editor",
                        title: "IDEToolbarPanel",
                        target: .symbol(EditorIntelligence.TextRange(
                            start: EditorIntelligence.TextPosition(line: 0, column: 0, utf16Offset: 0),
                            end: EditorIntelligence.TextPosition(line: 0, column: 0, utf16Offset: 0)
                        ))
                    )
                ],
                isDirty: true
            )
            return workspace
        }())
        .frame(width: 720)
        .preferredColorScheme(.dark)
}
