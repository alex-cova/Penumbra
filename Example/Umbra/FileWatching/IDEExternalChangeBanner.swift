import Penumbra
import SwiftUI

/// The strip above a text tab whose file changed or went away on disk. Same look and words as the
/// hex tab's banner.
struct IDEExternalChangeBanner: View {
    @Environment(IDEWorkspace.self) private var workspace
    let paneID: UUID

    var body: some View {
        // Reading the tab rows re-renders this when the pane's selection changes.
        let selectedID = workspace.tabsByPane[paneID]?.first(where: \.isSelected)?.id
        let document = workspace.workbench.layout.findPane(id: paneID)?.documents.first { $0.id == selectedID }
        if let document {
            switch workspace.externalChangeState(of: document) {
            case .none:
                EmptyView()
            case .changedOnDisk:
                strip {
                    Text("Changed on disk")
                    Button("Reload") { workspace.reloadFromBanner(document) }
                    Button("Keep Mine") { workspace.keepMineFromBanner(document) }
                    Button("Compare") { workspace.compareWithDisk(document) }
                }
            case .deletedOnDisk:
                strip {
                    Text("Deleted on disk")
                    Button("Close Tab") { workspace.closeDeleted(document) }
                    Button("Keep Editing") { workspace.keepEditingDeleted(document) }
                }
            }
        }
    }

    private func strip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
            Spacer()
        }
        .font(.caption)
        .padding(6)
        .background(IDEAppearance.ColorToken.gitModified.opacity(0.25))
    }
}
