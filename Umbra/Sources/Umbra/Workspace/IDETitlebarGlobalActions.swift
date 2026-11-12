import SwiftUI

/// The always-available actions at the trailing end of the titlebar.
struct IDETitlebarGlobalActions: View {
    let showsGoToFile: Bool
    let notificationSymbol: String
    let unseenNotifications: Int
    let isNotificationsOpen: Bool
    let showQuickOpen: () -> Void
    let showCommandPalette: () -> Void
    let toggleNotifications: () -> Void

    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xxs) {
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
                systemImage: notificationSymbol,
                help: "Notifications",
                tint: unseenNotifications > 0 && !isNotificationsOpen ? IDEAppearance.ColorToken.accent : nil,
                isActive: isNotificationsOpen,
                badge: unseenNotifications,
                action: toggleNotifications
            )

            IDEIconButton(
                systemImage: "brain",
                help: workspace.hasOpenProject ? "Agent" : "Open a folder to use the agent",
                isActive: workspace.agent.isPanelVisible && workspace.hasOpenProject,
                action: workspace.toggleAgentPanel
            )
            .disabled(!workspace.hasOpenProject)
            .accessibilityIdentifier(IDEACPAccessibility.agentToggle)

            IDEIconButton(
                systemImage: "sparkles",
                help: "AI Mode",
                action: { workspace.showAIMode() }
            )

            IDEIconButton(
                systemImage: "gearshape",
                help: "Settings",
                isActive: workspace.isSettingsVisible,
                action: workspace.showSettings
            )
            .accessibilityIdentifier(IDEACPAccessibility.settingsOpen)
        }
    }
}
