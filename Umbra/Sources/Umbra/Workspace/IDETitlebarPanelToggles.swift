import SwiftUI

/// Layout toggles for the three panel areas around the editor, drawn as the panel they toggle.
struct IDETitlebarPanelToggles: View {
    let hasContent: Bool
    let isLeftPanelOpen: Bool
    let isBottomPanelOpen: Bool
    let hasRightPanel: Bool
    let isRightPanelOpen: Bool
    let toggleLeftPanel: () -> Void
    let toggleBottomPanel: () -> Void
    let toggleRightPanel: () -> Void

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xxs) {
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
