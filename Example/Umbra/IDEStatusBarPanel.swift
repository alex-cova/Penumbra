import SwiftUI

struct IDEStatusBarPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: 0) {
            Text(statusSummary)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Spacer()
            Text(trailingSummary)
                .font(IDEAppearance.Typography.monoSmall)
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

    private var trailingSummary: String {
        "UTF-8  ·  LF  ·  \(workspace.statusRenderer)  ·  Umbra"
    }
}

#Preview {
    IDEStatusBarPanel()
        .environment({
            let workspace = IDEWorkspace()
            workspace.statusLine = 12
            workspace.statusColumn = 4
            workspace.statusLanguage = "javascript"
            return workspace
        }())
        .preferredColorScheme(.dark)
}
