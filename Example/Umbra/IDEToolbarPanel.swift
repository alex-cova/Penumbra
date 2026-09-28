import EditorIntelligence
import SwiftUI

/// The window's titlebar row, drawn on the window frame above the floating panels. Leading: the
/// traffic-light gutter (`Spacing.trafficLightsInset`, reserved only here), the left / bottom /
/// right panel toggles and a path-and-symbol breadcrumb for the active document. Center: the
/// project name and git branch. Trailing: document actions (build, run, preview) and the global
/// ones (Go to File, Actions, Settings). The two sides share the width equally so the title
/// stays centered in the window; the breadcrumb truncates first.
struct IDEToolbarPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                IDETitlebarPanelToggles(
                    hasContent: workspace.hasOpenProject || workspace.hasOpenDocuments,
                    isLeftPanelOpen: workspace.showsSidebar,
                    isBottomPanelOpen: workspace.isTerminalVisible,
                    hasRightPanel: workspace.javaSupport.isGradleProject,
                    isRightPanelOpen: workspace.showsGradleSidebar,
                    toggleLeftPanel: workspace.toggleSidebar,
                    toggleBottomPanel: workspace.toggleTerminal,
                    toggleRightPanel: workspace.toggleGradleSidebar
                )

                IDETitlebarSeparator()

                IDEToolbarBreadcrumb(
                    headerContext: workspace.headerContext,
                    onSelect: workspace.selectBreadcrumb
                )
                .padding(.leading, IDEAppearance.Spacing.xs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            IDETitlebarProjectTitle(
                title: workspace.project.rootURL?.lastPathComponent ?? "Umbra",
                branch: workspace.gitStatus.currentBranch,
                showSourceControl: workspace.showSourceControl
            )
            .fixedSize()

            HStack(spacing: 2) {
                IDEToolbarActionCluster(
                    showsCloseGroup: workspace.tabsByPane.count > 1,
                    isMarkdownFile: workspace.statusLanguage == "markdown",
                    isMarkdownPreviewVisible: workspace.isMarkdownPreviewVisible,
                    isGradleProject: workspace.javaSupport.isGradleProject,
                    isJavaRunnable: workspace.javaFileCanRun,
                    isJavaTestable: workspace.javaFileCanTest,
                    javaRunHelp: workspace.javaRunHelp,
                    isHTTPFile: workspace.statusLanguage == "http",
                    isHTTPSendable: workspace.httpFileCanSend,
                    toggleMarkdownPreview: workspace.toggleMarkdownPreview,
                    buildGradle: workspace.buildGradleProject,
                    runJava: workspace.runActiveJava,
                    runJavaTests: workspace.runActiveJavaTests,
                    sendHTTPRequest: workspace.sendActiveHTTPRequest,
                    exportMarkdownPreviewToPDF: workspace.exportMarkdownPreviewToPDF,
                    closeActivePane: workspace.closeActivePane
                )

                IDETitlebarGlobalActions(
                    showsGoToFile: workspace.hasOpenProject || workspace.hasOpenDocuments,
                    showQuickOpen: workspace.showQuickOpen,
                    showCommandPalette: workspace.showCommandPalette
                )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.leading, IDEAppearance.Spacing.trafficLightsInset)
        .padding(.trailing, IDEAppearance.Spacing.sm)
        .frame(maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        // No fill: the row sits over the traffic lights (SwiftUI's hosting view is above the
        // titlebar), so the frame color comes from `NSWindow.backgroundColor` underneath.
        .focusable(false)
    }
}

/// Layout toggles for the three panel areas around the editor, drawn as the panel they toggle.
private struct IDETitlebarPanelToggles: View {
    let hasContent: Bool
    let isLeftPanelOpen: Bool
    let isBottomPanelOpen: Bool
    let hasRightPanel: Bool
    let isRightPanelOpen: Bool
    let toggleLeftPanel: () -> Void
    let toggleBottomPanel: () -> Void
    let toggleRightPanel: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            IDEToolbarIconButton(
                systemName: "sidebar.left",
                isActive: isLeftPanelOpen,
                help: isLeftPanelOpen ? "Hide Left Panel" : "Show Left Panel",
                action: toggleLeftPanel
            )
            .disabled(!hasContent)

            IDEToolbarIconButton(
                systemName: "rectangle.bottomthird.inset.filled",
                isActive: isBottomPanelOpen,
                help: isBottomPanelOpen ? "Hide Bottom Panel" : "Show Bottom Panel",
                action: toggleBottomPanel
            )

            IDEToolbarIconButton(
                systemName: "sidebar.right",
                isActive: isRightPanelOpen,
                help: isRightPanelOpen ? "Hide Right Panel" : "Show Right Panel",
                action: toggleRightPanel
            )
            .disabled(!hasRightPanel)
        }
    }
}

private struct IDETitlebarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(IDEAppearance.ColorToken.border)
            .frame(width: 1, height: 16)
            .padding(.horizontal, IDEAppearance.Spacing.xs)
            .accessibilityHidden(true)
    }
}

/// Centered `project ⑂ branch` title; the branch opens Source Control.
private struct IDETitlebarProjectTitle: View {
    let title: String
    let branch: String?
    let showSourceControl: () -> Void

    @State private var isHoveringBranch = false

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Text(title)
                .font(IDEAppearance.Typography.titlebarTitle)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)

            if let branch {
                Button(action: showSourceControl) {
                    HStack(spacing: IDEAppearance.Spacing.xs + 2) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: IDEAppearance.IconSize.toolbarGlyph, weight: .medium))
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                        Text(branch)
                            .font(IDEAppearance.Typography.titlebarTitle)
                            .foregroundStyle(isHoveringBranch ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.foreground.opacity(0.85))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, IDEAppearance.Spacing.xs)
                    .padding(.vertical, 3)
                    .background(isHoveringBranch ? IDEAppearance.ColorToken.controlHover : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHoveringBranch = $0 }
                .help("Show Source Control")
                .accessibilityLabel("Git branch \(branch)")
                .accessibilityHint("Show Source Control")
                .focusable(false)
            }
        }
    }
}

/// The always-available actions at the trailing end of the titlebar.
private struct IDETitlebarGlobalActions: View {
    let showsGoToFile: Bool
    let showQuickOpen: () -> Void
    let showCommandPalette: () -> Void

    @State private var isHoveringSettings = false

    var body: some View {
        HStack(spacing: 2) {
            IDEToolbarIconButton(
                systemName: "bolt",
                help: "Actions…",
                action: showCommandPalette
            )

            if showsGoToFile {
                IDEToolbarIconButton(
                    systemName: "magnifyingglass",
                    help: "Go to File…",
                    action: showQuickOpen
                )
            }

            SettingsLink {
                IDEToolbarIconLabel(systemName: "gearshape", isHighlighted: isHoveringSettings)
            }
            .buttonStyle(.plain)
            .onHover { isHoveringSettings = $0 }
            .help("Settings")
            .accessibilityLabel("Settings")
            .focusable(false)
        }
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
    let isJavaTestable: Bool
    let javaRunHelp: String
    let isHTTPFile: Bool
    let isHTTPSendable: Bool
    let toggleMarkdownPreview: () -> Void
    let buildGradle: () -> Void
    let runJava: () -> Void
    let runJavaTests: () -> Void
    let sendHTTPRequest: () -> Void
    let exportMarkdownPreviewToPDF: () -> Void
    let closeActivePane: () -> Void

    var body: some View {
        HStack(spacing: 2) {
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

            IDERunConfigurationMenu()

            if isJavaRunnable {
                IDEToolbarIconButton(
                    systemName: "play.fill",
                    tint: IDEAppearance.ColorToken.run,
                    help: javaRunHelp,
                    action: runJava
                )
            }

            if isJavaTestable {
                IDEToolbarIconButton(
                    systemName: "flask",
                    help: "Run Tests",
                    action: runJavaTests
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

/// Shared glyph-button chrome for the titlebar: a fixed square hit target, muted by default,
/// brightening on hover (and filled while its panel is open) so every action reads as one family.
private struct IDEToolbarIconButton: View {
    let systemName: String
    var isActive = false
    var tint: Color? = nil
    let help: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            IDEToolbarIconLabel(
                systemName: systemName,
                isActive: isActive,
                isHighlighted: isHovering && isEnabled,
                tint: tint
            )
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .focusable(false)
    }
}

private struct IDEToolbarIconLabel: View {
    let systemName: String
    var isActive = false
    var isHighlighted = false
    var tint: Color? = nil

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: IDEAppearance.IconSize.titlebarGlyph, weight: .regular))
            .foregroundStyle(tint ?? (isActive || isHighlighted ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted))
            .frame(width: IDEAppearance.Spacing.titlebarButton, height: IDEAppearance.Spacing.titlebarButton)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
            .contentShape(Rectangle())
    }

    private var background: Color {
        if isActive { return IDEAppearance.ColorToken.card }
        return isHighlighted ? IDEAppearance.ColorToken.controlHover : Color.clear
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
        .frame(width: 720, height: IDEAppearance.Spacing.titlebarMinHeight)
        .preferredColorScheme(.dark)
}
