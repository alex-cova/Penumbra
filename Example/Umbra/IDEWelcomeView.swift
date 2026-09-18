import SwiftUI

struct IDEWelcomeView: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: IDEAppearance.Spacing.xxl)

            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xl) {
                IDEWelcomeBrandHeader()
                IDEWelcomeActionList(
                    openFile: workspace.openFile,
                    openFolder: workspace.openFolder,
                    newFile: workspace.newFile
                )
                if !workspace.recentFileURLs.isEmpty {
                    IDEWelcomeRecentFilesSection(
                        urls: Array(workspace.recentFileURLs.prefix(8)),
                        onOpen: workspace.openRecentFile
                    )
                }
                IDEWelcomeShortcutsGrid()
            }
            .frame(maxWidth: IDEAppearance.Spacing.welcomeMaxWidth, alignment: .leading)

            Spacer(minLength: IDEAppearance.Spacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.editor)
    }
}

private struct IDEWelcomeBrandHeader: View {
    var body: some View {
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
}

private struct IDEWelcomeActionList: View {
    let openFile: () -> Void
    let openFolder: () -> Void
    let newFile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            IDEWelcomeActionRow(title: "Open File…", systemImage: "doc", shortcut: "⌘O", action: openFile)
            IDEWelcomeActionRow(title: "Open Folder…", systemImage: "folder", shortcut: "⌘⇧O", action: openFolder)
            IDEWelcomeActionRow(title: "New File", systemImage: "doc.badge.plus", shortcut: "⌘N", action: newFile)
        }
    }
}

private struct IDEWelcomeActionRow: View {
    let title: String
    let systemImage: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
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
}

private struct IDEWelcomeRecentFilesSection: View {
    let urls: [URL]
    let onOpen: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Text("Recent")
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(urls, id: \.path) { url in
                    Button(url.lastPathComponent, systemImage: "doc.text", action: { onOpen(url) })
                        .buttonStyle(IDEWelcomeLinkButtonStyle())
                        .help(url.path)
                }
            }
        }
    }
}

private struct IDEWelcomeShortcutsGrid: View {
    var body: some View {
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
                IDEWelcomeShortcutCell(keys: "⌘P", action: "Go to File")
                IDEWelcomeShortcutCell(keys: "⌘⇧P", action: "Command Palette")
                IDEWelcomeShortcutCell(keys: "⌘L", action: "Go to Line")
                IDEWelcomeShortcutCell(keys: "⌘R", action: "Go to Symbol")
                IDEWelcomeShortcutCell(keys: "⌘F", action: "Find")
                IDEWelcomeShortcutCell(keys: "⌘⇧F", action: "Find in Files")
            }
        }
    }
}

private struct IDEWelcomeShortcutCell: View {
    let keys: String
    let action: String

    var body: some View {
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
