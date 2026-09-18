import SwiftUI

struct IDESidebarPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Explorer")
                .font(IDEAppearance.Typography.sidebarHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .padding(.leading, IDEAppearance.Spacing.lg)
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
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IDEAppearance.ColorToken.sidebar)
        .focusable(false)
    }
}

#Preview {
    IDESidebarPanel()
        .environment({
            let workspace = IDEWorkspace()
            workspace.project.setRoot(URL(fileURLWithPath: #filePath).deletingLastPathComponent())
            return workspace
        }())
        .frame(width: 240, height: 480)
        .preferredColorScheme(.dark)
}
