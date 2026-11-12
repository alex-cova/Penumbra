import SwiftUI

/// The titlebar row in editor mode: panel toggles, project title, document and global actions.
/// Extracted from `IDEToolbarPanel`.
struct IDEToolbarEditorRow: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
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

            HStack(spacing: IDEAppearance.Spacing.xxs) {
                IDEToolbarActionCluster(
                    showsCloseGroup: workspace.hasMultiplePanes,
                    items: workspace.toolbarItems(),
                    closeActivePane: workspace.closeActivePane
                )

                IDETitlebarGlobalActions(
                    showsGoToFile: workspace.hasOpenProject || workspace.hasOpenDocuments,
                    notificationSymbol: workspace.notifications.bellSymbol,
                    unseenNotifications: workspace.notifications.unseenCount,
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
