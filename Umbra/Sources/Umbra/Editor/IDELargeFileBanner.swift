import Penumbra
import SwiftUI

/// The strip above a text tab that opened under a large-file tier: names what is off and, for a
/// clean tab, offers Enable Anyway (a reload with full service).
struct IDELargeFileBanner: View {
    @Environment(IDEWorkspace.self) private var workspace
    let paneID: UUID

    var body: some View {
        // Reading the tab rows re-renders this when the pane's selection changes.
        let selectedID = workspace.tabsByPane[paneID]?.first(where: \.isSelected)?.id
        let document = workspace.workbench.layout.findPane(id: paneID)?.documents.first { $0.id == selectedID }
        if let document, let notice = document.largeFileNotice {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                Text(notice.message)
                    .lineLimit(2)
                Button("Enable Anyway") { workspace.enableLargeFileFeatures(for: document) }
                    .disabled(document.isDirty)
                    .help(document.isDirty ? "Save your changes first: enabling reloads the file." : "Reload with highlighting, folding and code intelligence.")
                Spacer()
            }
            .font(.caption)
            .padding(6)
            .background(IDEAppearance.ColorToken.gitModified.opacity(0.25))
        }
    }
}
