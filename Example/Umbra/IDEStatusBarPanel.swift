import SwiftUI

struct IDEStatusBarPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Text(leadingSummary)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text("·")
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            syntaxPicker
            javaStatus
            if workspace.statusSelectionLength > 0 {
                Text("·  \(workspace.statusSelectionLength) selected")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
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

    /// Sublime-style clickable syntax name — the only way to set a language on a document that
    /// doesn't have one yet (e.g. a freshly created "Untitled" file from Cmd+N).
    private var syntaxPicker: some View {
        Menu {
            ForEach(IDELanguageSupport.selectableSyntaxes) { option in
                Button(option.displayName) {
                    workspace.setLanguage(identifier: option.id)
                }
            }
        } label: {
            Text(IDELanguageSupport.displayName(forIdentifier: workspace.statusLanguage.isEmpty ? nil : workspace.statusLanguage))
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var javaStatus: some View {
        switch workspace.javaSupport.gradleSync {
        case .failed(let summary):
            Text("·")
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Button("Gradle sync failed") {
                workspace.showGradleOutput()
            }
            .buttonStyle(.borderless)
            .font(IDEAppearance.Typography.monoSmall)
            .foregroundStyle(Color(hex: 0xE5484D))
            .fixedSize()
            .help(summary)
            .accessibilityLabel("Gradle sync failed")
            .accessibilityHint(summary)
        default:
            if let message = workspace.javaSupport.statusMessage {
                Text("·")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text(message)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 280, alignment: .leading)
            }
        }
    }

    private var leadingSummary: String {
        "Ln \(workspace.statusLine)  ·  Col \(workspace.statusColumn)"
    }

    private var trailingSummary: String {
        var parts = ["UTF-8", "LF"]
        if workspace.isTerminalVisible {
            parts.append("Terminal")
        }
        parts.append(workspace.statusRenderer)
        parts.append("Umbra")
        return parts.joined(separator: "  ·  ")
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
