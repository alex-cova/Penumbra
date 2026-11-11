import SwiftUI

/// The strip above a text tab whose file is conflicted in the last git snapshot.
///
/// Same layout as the external-change banner. The condition is the snapshot's conflict set, not a
/// search of the buffer for conflict markers. Merge… opens the existing merge tool.
struct IDEGitConflictBanner: View {
    @Environment(IDEWorkspace.self) private var workspace
    let paneID: UUID

    var body: some View {
        let selectedID = workspace.tabsByPane[paneID]?.first(where: \.isSelected)?.id
        let document = workspace.workbench.layout.findPane(id: paneID)?.documents.first { $0.id == selectedID }
        if let document, document.contentKind == .text, let path = document.url?.standardizedFileURL.path,
           IDEGitConflictBannerPolicy.shows(conflicted: workspace.gitStatus.conflictedPaths.contains(path)) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(IDEAppearance.ColorToken.gitConflict)
                    .accessibilityHidden(true)
                Text("Conflict in \(document.displayName)")
                Button("Merge…") { workspace.openMergeTool(forPath: path) }
                Spacer()
            }
            .font(.caption)
            .padding(6)
            .background(IDEAppearance.ColorToken.gitConflict.opacity(0.12))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Conflict in \(document.displayName)")
        }
    }
}
