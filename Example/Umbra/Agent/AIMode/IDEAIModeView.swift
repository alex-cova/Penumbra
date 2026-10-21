import SwiftUI

/// AI mode: the window's whole content while `IDEWorkspace.windowMode == .ai`. A list on the left
/// (Chat and Code switch at its top) and the conversation on the right. The editor stays mounted
/// underneath, hidden, so switching back finds it as it was.
struct IDEAIModeView: View {
    @Environment(IDEWorkspace.self) private var workspace
    @Binding var sidebarWidth: Double

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: IDEAppearance.Spacing.panelGap)
            if workspace.showsAISidebar {
                IDEAISidebar()
                    .frame(width: sidebarWidth)
                    .idePanel()
                IDESidebarResizeHandle(width: $sidebarWidth, edge: .leading)
            }
            IDEAIMainView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .idePanel()
            Color.clear.frame(width: IDEAppearance.Spacing.panelGap)
        }
        // No status bar in this mode, so the cards need their own gap at the bottom.
        .padding(.bottom, IDEAppearance.Spacing.panelGap)
        .sheet(isPresented: Bindable(workspace).isAIModelsPresented) {
            IDEAIModelsSheet(settings: workspace.agent.settings)
                .preferredColorScheme(IDEAppearance.preferredColorScheme)
        }
        .sheet(item: Bindable(workspace).aiModelSetup) { tab in
            IDEAIModelSetupSheet(
                settings: workspace.agent.settings, mode: tab == .code ? .code : .chat,
                onUse: { workspace.selectAIModel($0, for: tab) })
                .preferredColorScheme(IDEAppearance.preferredColorScheme)
        }
    }
}

/// The right-hand card: Chat or Code.
struct IDEAIMainView: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        Group {
            switch workspace.aiTab {
            case .chat: IDEAIChatView()
            case .code: IDEAICodeView()
            }
        }
        // The first time a tab shows with no usable model, the setup sheet opens by itself.
        .task(id: workspace.aiTab) { await workspace.offerAIModelSetupIfNeeded() }
    }
}
