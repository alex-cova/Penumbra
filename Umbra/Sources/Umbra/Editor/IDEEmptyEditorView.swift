import SwiftUI

/// Which page fills the editor area when no document is open.
enum IDENoDocumentContent: Equatable {
    /// No folder either: the full welcome page, with its ways to open one.
    case welcome
    /// A folder is open and the last tab was closed: a quiet panel, not a landing page.
    case emptyEditor

    static func content(hasProject: Bool) -> IDENoDocumentContent {
        hasProject ? .emptyEditor : .welcome
    }
}

/// The editor area with nothing open. Chooses between the welcome page and the empty editor.
struct IDENoDocumentView: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        switch IDENoDocumentContent.content(hasProject: workspace.hasOpenProject) {
        case .welcome: IDEWelcomeView()
        case .emptyEditor: IDEEmptyEditorView()
        }
    }
}

/// The recent files that live inside a project folder.
enum IDEProjectRecentFiles {
    static func files(in root: URL, from recents: [URL], limit: Int) -> [URL] {
        let path = root.standardizedFileURL.path
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return recents
            .filter { $0.standardizedFileURL.path.hasPrefix(prefix) }
            .prefix(limit)
            .map { $0 }
    }
}

/// What a project window shows after its last tab is closed: the project, three ways to start
/// and the files last worked on, on the plain editor background. No animation, no backdrop.
struct IDEEmptyEditorView: View {
    @Environment(IDEWorkspace.self) private var workspace

    private static let recentLimit = 5

    private var recentFiles: [URL] {
        guard let root = workspace.project.rootURL else { return [] }
        return IDEProjectRecentFiles.files(in: root, from: workspace.recentFileURLs, limit: Self.recentLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.lg) {
            if let root = workspace.project.rootURL {
                header(root)
            }
            VStack(spacing: IDEAppearance.Spacing.xxs) {
                IDEEmptyEditorHint(title: "Go to File…", shortcut: "⌘P", action: workspace.showQuickOpen)
                IDEEmptyEditorHint(title: "Find in Files…", shortcut: "⌘⇧F", action: workspace.showFindInFiles)
                IDEEmptyEditorHint(title: "New File", shortcut: "⌘N", action: workspace.newFile)
            }
            if !recentFiles.isEmpty {
                VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xxs) {
                    Text("Recent")
                        .font(IDEAppearance.Typography.sidebarHeader)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .textCase(.uppercase)
                        .padding(.horizontal, IDEAppearance.Spacing.md)
                    ForEach(recentFiles, id: \.path) { url in
                        IDEEmptyEditorHint(title: url.lastPathComponent, shortcut: nil, help: url.path) {
                            workspace.openRecentFile(url)
                        }
                    }
                }
            }
        }
        .frame(width: IDEAppearance.Spacing.emptyEditorWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IDEAppearance.ColorToken.editor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("No file open")
    }

    private func header(_ root: URL) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xxs) {
            Text(root.lastPathComponent)
                .font(IDEAppearance.Typography.titlebarTitle)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            if let branch = workspace.gitStatus.currentBranch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .labelStyle(.titleAndIcon)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
    }
}

/// One line of the empty editor: a title, its shortcut when it has one, a hover fill and the
/// shared focus ring.
private struct IDEEmptyEditorHint: View {
    let title: String
    let shortcut: String?
    var help: String?
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: IDEAppearance.Spacing.md) {
                Text(title)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, IDEAppearance.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHovering ? IDEAppearance.ColorToken.controlHover : Color.clear,
                in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous)
                    .stroke(IDEAppearance.ColorToken.accent, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .onHover { isHovering = $0 }
        .help(help ?? title)
        .accessibilityHint(shortcut.map { "Keyboard shortcut \($0)" } ?? "")
    }
}
