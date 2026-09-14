import SwiftUI

struct IDEStatusBarPanel: View {
    @EnvironmentObject private var workspace: IDEWorkspace

    var body: some View {
        HStack(spacing: 0) {
            Text(statusSummary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Spacer()
            Text("UTF-8  ·  LF  ·  \(workspace.statusRenderer)  ·  Runestone")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .frame(height: IDEAppearance.Spacing.statusBarHeight)
        .background(IDEAppearance.ColorToken.statusBar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)
        }
        .focusable(false)
    }

    private var statusSummary: String {
        var parts = [
            "Ln \(workspace.statusLine)",
            "Col \(workspace.statusColumn)"
        ]
        if !workspace.statusLanguage.isEmpty {
            parts.append(workspace.statusLanguage.capitalized)
        }
        if workspace.statusSelectionLength > 0 {
            parts.append("\(workspace.statusSelectionLength) selected")
        }
        return parts.joined(separator: "  ·  ")
    }
}

#Preview {
    IDEStatusBarPanel()
        .environmentObject({
            let workspace = IDEWorkspace()
            workspace.statusLine = 12
            workspace.statusColumn = 4
            workspace.statusLanguage = "javascript"
            return workspace
        }())
        .preferredColorScheme(.dark)
}
