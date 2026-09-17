import SwiftUI

struct IDEWelcomeView: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: IDEAppearance.Spacing.xxl)

            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xl) {
                brandHeader
                actionList
                if !workspace.recentFileURLs.isEmpty {
                    recentFilesSection
                }
                shortcutsGrid
            }
            .frame(maxWidth: IDEAppearance.Spacing.welcomeMaxWidth, alignment: .leading)

            Spacer(minLength: IDEAppearance.Spacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.editor)
    }

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Label {
                Text("Umbra")
                    .font(IDEAppearance.Typography.brandTitle)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
            } icon: {
                Image(systemName: "text.alignleft")
                    .font(.title2)
                    .foregroundStyle(IDEAppearance.ColorToken.accent)
            }
            .labelStyle(.titleAndIcon)

            Text("A lightweight code editor for macOS")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
    }

    private var actionList: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            welcomeAction("Open File…", systemImage: "doc", shortcut: "⌘O", action: workspace.openFile)
            welcomeAction("Open Folder…", systemImage: "folder", shortcut: "⌘⇧O", action: workspace.openFolder)
            welcomeAction("New File", systemImage: "doc.badge.plus", shortcut: "⌘N", action: workspace.newFile)
        }
    }

    private var recentFilesSection: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Text("Recent")
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(workspace.recentFileURLs.prefix(8), id: \.path) { url in
                    Button(url.lastPathComponent, systemImage: "doc.text", action: { workspace.openRecentFile(url) })
                        .buttonStyle(IDEWelcomeLinkButtonStyle())
                        .help(url.path)
                }
            }
        }
    }

    private var shortcutsGrid: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Text("Shortcuts")
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .textCase(.uppercase)

            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                alignment: .leading,
                spacing: IDEAppearance.Spacing.xs
            ) {
                shortcutCell("⌘P", "Go to File")
                shortcutCell("⌘⇧P", "Command Palette")
                shortcutCell("⌘G", "Go to Line")
                shortcutCell("⌘R", "Go to Symbol")
                shortcutCell("⌘F", "Find")
                shortcutCell("⌘⇧F", "Find in Files")
            }
        }
    }

    private func welcomeAction(
        _ title: String,
        systemImage: String,
        shortcut: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: IDEAppearance.Spacing.md) {
                Label(title, systemImage: systemImage)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                Spacer(minLength: 0)
                Text(shortcut)
                    .font(IDEAppearance.Typography.monoCaption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, IDEAppearance.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(IDEAppearance.ColorToken.tabActive)
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Keyboard shortcut \(shortcut)")
    }

    private func shortcutCell(_ keys: String, _ action: String) -> some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Text(keys)
                .font(IDEAppearance.Typography.monoCaption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 56, alignment: .trailing)
            Text(action)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
    }
}

private struct IDEWelcomeLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(
                configuration.isPressed
                    ? IDEAppearance.ColorToken.accent
                    : IDEAppearance.ColorToken.foreground
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
    }
}

#Preview {
    IDEWelcomeView()
        .environment(IDEWorkspace())
        .preferredColorScheme(.dark)
}
