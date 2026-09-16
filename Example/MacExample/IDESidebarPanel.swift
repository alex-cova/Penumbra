import SwiftUI

struct IDESidebarPanel: View {
    var leadingInset: CGFloat = 0
    @EnvironmentObject private var workspace: IDEWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Explorer")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .padding(.leading, leadingInset + IDEAppearance.Spacing.lg)
                .padding(.trailing, IDEAppearance.Spacing.lg)
                .frame(height: IDEAppearance.Spacing.tabHeight, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)

            IDEFileTreeView(
                project: workspace.project,
                onOpenFile: { url in
                    Task { await workspace.openDocument(from: url) }
                },
                onOpenFolder: workspace.openFolder
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IDEAppearance.ColorToken.sidebar)
        .focusable(false)
    }
}
