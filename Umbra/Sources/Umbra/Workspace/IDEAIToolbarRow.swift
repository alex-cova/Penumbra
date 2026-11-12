import SwiftUI

/// The titlebar row in AI mode: the list toggle and Chat / Code at the leading end, the global actions
/// and the way back to the editor at the trailing end.
struct IDEAIToolbarRow: View {
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

            HStack(spacing: IDEAppearance.Spacing.xxs) {
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
                    systemImage: workspace.notifications.bellSymbol,
                    help: "Notifications",
                    tint: workspace.notifications.unseenCount > 0 && !workspace.notifications.isPanelPresented
                        ? IDEAppearance.ColorToken.accent : nil,
                    isActive: workspace.notifications.isPanelPresented,
                    badge: workspace.notifications.unseenCount,
                    action: workspace.notifications.togglePanel
                )
                IDEIconButton(
                    systemImage: "curlybraces",
                    help: "Back to the Editor",
                    isActive: true,
                    action: workspace.showEditorMode
                )
                IDEIconButton(
                    systemImage: "gearshape",
                    help: "Settings",
                    action: workspace.showSettings
                )
                .accessibilityIdentifier(IDEACPAccessibility.settingsOpen)
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
