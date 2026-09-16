import SwiftUI

struct IDEWelcomeView: View {
    @EnvironmentObject private var workspace: IDEWorkspace

    var body: some View {
        VStack(spacing: IDEAppearance.Spacing.lg) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 48))
                .foregroundStyle(IDEAppearance.ColorToken.accent)

            Text("Umbra")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(IDEAppearance.ColorToken.foreground)

            Text("A lightweight code editor for macOS")
                .font(.subheadline)
                .foregroundStyle(IDEAppearance.ColorToken.muted)

            HStack(spacing: IDEAppearance.Spacing.md) {
                Button("Open File…") { workspace.openFile() }
                    .keyboardShortcut("o")
                Button("Open Folder…") { workspace.openFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("New File") { workspace.newFile() }
                    .keyboardShortcut("n")
            }
            .buttonStyle(.borderedProminent)
            .tint(IDEAppearance.ColorToken.accent)

            VStack(alignment: .leading, spacing: 4) {
                Text("Shortcuts")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Group {
                    shortcutRow("⌘P", "Go to File")
                    shortcutRow("⌘⇧P", "Command Palette")
                    shortcutRow("⌘G", "Go to Line")
                    shortcutRow("⌘R", "Go to Symbol")
                    shortcutRow("⌘F", "Find")
                }
                .font(.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            .padding(.top, IDEAppearance.Spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IDEAppearance.ColorToken.editor)
    }

    private func shortcutRow(_ keys: String, _ action: String) -> some View {
        HStack {
            Text(keys)
                .font(.caption.monospaced())
                .frame(width: 56, alignment: .trailing)
            Text(action)
        }
    }
}
