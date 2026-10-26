import SwiftUI

/// The window's titlebar row, drawn on the window frame above the floating panels. Leading: the
/// traffic-light gutter (`Spacing.trafficLightsInset`, reserved only here), the left / bottom /
/// right panel toggles. Center: the project name and git branch. Trailing: document actions
/// (build, run, preview) and the global ones (Go to File, Actions, Settings). The two sides share
/// the width equally so the title stays centered in the window. The path-and-symbol breadcrumb
/// lives in the status bar.
struct IDEToolbarPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        if workspace.isAIMode {
            IDEAIToolbarRow()
        } else {
            editorRow
        }
    }

    private var editorRow: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                IDETitlebarPanelToggles(
                    hasContent: workspace.hasOpenProject || workspace.hasOpenDocuments,
                    isLeftPanelOpen: workspace.showsSidebar,
                    isBottomPanelOpen: workspace.isTerminalVisible,
                    hasRightPanel: workspace.projectSystems.active != nil,
                    isRightPanelOpen: workspace.showsProjectSidebar,
                    toggleLeftPanel: workspace.toggleSidebar,
                    toggleBottomPanel: workspace.toggleTerminal,
                    toggleRightPanel: workspace.toggleProjectSidebar
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            IDETitlebarProjectTitle(
                title: workspace.project.rootURL?.lastPathComponent ?? "Umbra",
                branch: workspace.gitStatus.currentBranch,
                operation: workspace.gitStatus.operationPresentation?.badge,
                showSourceControl: workspace.showSourceControl
            )
            .fixedSize()

            HStack(spacing: 2) {
                IDEToolbarActionCluster(
                    showsCloseGroup: workspace.tabsByPane.count > 1,
                    items: workspace.toolbarItems(),
                    closeActivePane: workspace.closeActivePane
                )

                IDETitlebarGlobalActions(
                    showsGoToFile: workspace.hasOpenProject || workspace.hasOpenDocuments,
                    hasNotifications: !workspace.notifications.items.isEmpty,
                    isNotificationsOpen: workspace.notifications.isPanelPresented,
                    showQuickOpen: workspace.showQuickOpen,
                    showCommandPalette: workspace.showCommandPalette,
                    toggleNotifications: workspace.notifications.togglePanel
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
        // Titlebar glyphs and targets; panel buttons keep the shared default size.
        .ideIconButtonSize(.titlebar)
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
            IDEIconButton(
                systemImage: "sidebar.left",
                help: isLeftPanelOpen ? "Hide Left Panel" : "Show Left Panel",
                isActive: isLeftPanelOpen,
                action: toggleLeftPanel
            )
            .disabled(!hasContent)

            IDEIconButton(
                systemImage: "rectangle.bottomthird.inset.filled",
                help: isBottomPanelOpen ? "Hide Bottom Panel" : "Show Bottom Panel",
                isActive: isBottomPanelOpen,
                action: toggleBottomPanel
            )

            IDEIconButton(
                systemImage: "sidebar.right",
                help: isRightPanelOpen ? "Hide Right Panel" : "Show Right Panel",
                isActive: isRightPanelOpen,
                action: toggleRightPanel
            )
            .disabled(!hasRightPanel)
        }
    }
}

/// Centered `project ⑂ branch` title; the branch opens the branch popup.
private struct IDETitlebarProjectTitle: View {
    let title: String
    let branch: String?
    /// "Merging", "Rebasing"…: shown beside the branch while one is in progress.
    var operation: String?
    let showSourceControl: () -> Void

    @State private var isHoveringBranch = false
    @State private var showsBranches = false

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Text(title)
                .font(IDEAppearance.Typography.titlebarTitle)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)

            if let branch {
                Button { showsBranches.toggle() } label: {
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
                .popover(isPresented: $showsBranches, arrowEdge: .bottom) {
                    IDEGitBranchPopup(isPresented: $showsBranches)
                }
                .help("Branches: switch, create, update and push")
                .accessibilityLabel("Git branch \(branch)")
                .accessibilityHint("Show branches")
                .focusable(false)
            }

            if let operation {
                Button(action: showSourceControl) {
                    Text(operation)
                        .font(IDEAppearance.Typography.caption.weight(.semibold))
                        .foregroundStyle(IDEAppearance.ColorToken.gitConflict)
                        .padding(.horizontal, IDEAppearance.Spacing.sm)
                        .padding(.vertical, IDEAppearance.Spacing.xxs)
                        .background(IDEAppearance.ColorToken.gitConflict.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("\(operation) is in progress: open Changes to continue or abort")
            }
        }
    }
}

/// The always-available actions at the trailing end of the titlebar.
private struct IDETitlebarGlobalActions: View {
    let showsGoToFile: Bool
    let hasNotifications: Bool
    let isNotificationsOpen: Bool
    let showQuickOpen: () -> Void
    let showCommandPalette: () -> Void
    let toggleNotifications: () -> Void

    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: 2) {
            IDEIconButton(
                systemImage: "bolt",
                help: "Actions…",
                action: showCommandPalette
            )

            if showsGoToFile {
                IDEIconButton(
                    systemImage: "magnifyingglass",
                    help: "Go to File…",
                    action: showQuickOpen
                )
            }

            IDEIconButton(
                systemImage: hasNotifications ? "bell.badge" : "bell",
                help: "Notifications",
                tint: hasNotifications && !isNotificationsOpen ? IDEAppearance.ColorToken.accent : nil,
                isActive: isNotificationsOpen,
                action: toggleNotifications
            )

            IDEIconButton(
                systemImage: "brain",
                help: workspace.hasOpenProject ? "Agent" : "Open a folder to use the agent",
                isActive: workspace.agent.isPanelVisible && workspace.hasOpenProject,
                action: workspace.toggleAgentPanel
            )
            .disabled(!workspace.hasOpenProject)

            IDEIconButton(
                systemImage: "bubbles.and.sparkles",
                help: "AI Mode",
                action: { workspace.showAIMode() }
            )

            IDEIconButton(
                systemImage: "gearshape",
                help: "Settings",
                isActive: workspace.isSettingsVisible,
                action: workspace.showSettings
            )
        }
    }
}

/// Close Editor Group, then the buttons language modules and the project system contribute
/// (`IDELanguageModule.toolbarItems`), in their order.
private struct IDEToolbarActionCluster: View {
    let showsCloseGroup: Bool
    let items: [IDEToolbarItem]
    let closeActivePane: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            if showsCloseGroup {
                IDEIconButton(
                    systemImage: "rectangle.slash",
                    help: "Close Editor Group",
                    action: closeActivePane
                )
            }

            ForEach(items) { item in
                switch item.content {
                case .button(let button):
                    IDEIconButton(
                        systemImage: button.systemImage,
                        help: button.help,
                        tint: button.tint,
                        isActive: button.isActive,
                        action: button.action
                    )
                    .disabled(!button.isEnabled)
                case .custom(let view):
                    view
                }
            }
        }
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
            return workspace
        }())
        .frame(width: 720, height: IDEAppearance.Spacing.titlebarMinHeight)
        .preferredColorScheme(IDEAppearance.preferredColorScheme)
}

/// The titlebar row in AI mode: the list toggle and Chat / Code at the leading end, the global actions
/// and the way back to the editor at the trailing end.
private struct IDEAIToolbarRow: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                IDEIconButton(
                    systemImage: "sidebar.left",
                    help: workspace.showsAISidebar ? "Hide Chats" : "Show Chats",
                    isActive: workspace.showsAISidebar,
                    action: { workspace.showsAISidebar.toggle() }
                )
                ForEach(IDEAITab.allCases) { tab in
                    IDEIconButton(
                        systemImage: tab.symbolName,
                        help: tab == .chat ? "Chat: talk to any model, no project" : "Code: an agent working in a project",
                        isActive: workspace.aiTab == tab,
                        action: { workspace.aiTab = tab }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                // Changes, Plan and Browser belong to Code: Chat has no project, files or plan.
                if workspace.aiTab == .code {
                    IDEIconButton(
                        systemImage: "sidebar.right",
                        help: workspace.showsAIInspector ? "Hide Changes, Plan and Browser" : "Show Changes, Plan and Browser",
                        isActive: workspace.showsAIInspector,
                        action: { workspace.toggleAIInspector() }
                    )
                }
                IDEIconButton(systemImage: "bolt", help: "Actions…", action: workspace.showCommandPalette)
                IDEIconButton(
                    systemImage: workspace.notifications.items.isEmpty ? "bell" : "bell.badge",
                    help: "Notifications",
                    tint: !workspace.notifications.items.isEmpty && !workspace.notifications.isPanelPresented
                        ? IDEAppearance.ColorToken.accent : nil,
                    isActive: workspace.notifications.isPanelPresented,
                    action: workspace.notifications.togglePanel
                )
                IDEIconButton(
                    systemImage: "bubbles.and.sparkles",
                    help: "Back to the Editor",
                    isActive: true,
                    action: workspace.showEditorMode
                )
                IDEIconButton(
                    systemImage: "gearshape",
                    help: "Settings",
                    action: workspace.showSettings
                )
            }
        }
        .padding(.leading, IDEAppearance.Spacing.trafficLightsInset)
        .padding(.trailing, IDEAppearance.Spacing.sm)
        .frame(maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .focusable(false)
        .ideIconButtonSize(.titlebar)
    }
}
