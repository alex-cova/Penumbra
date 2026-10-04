import SwiftUI

/// The agent chat, opened over the editor area the way Settings is: a tab-style header with a close
/// button, and the conversation centered at a readable width. The editor underneath stays mounted.
struct IDEAgentPage: View {
    let agent: IDEAgentController
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            IDESettingsTabHeader(title: "Agent", systemImage: "brain", onClose: onClose)
            IDEAgentPanel(agent: agent)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IDEAppearance.ColorToken.workbench)
    }
}
