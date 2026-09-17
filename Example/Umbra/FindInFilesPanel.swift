import EditorIntelligence
import SwiftUI

/// Project-wide search drawer, docked to the top of the editor column (see `IDERootView`) so it
/// reads as part of the same "find" system as the in-editor bar rather than a separate bottom
/// panel. `leadingInset` mirrors `IDEEditorTabsBar`'s: only set when this is the top-leading
/// chrome row and needs to clear the window's traffic lights.
struct FindInFilesPanel: View {
    @EnvironmentObject private var workspace: IDEWorkspace
    var leadingInset: CGFloat = 0
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                FindInFilesSearchField(query: $workspace.findInFilesQuery, isFocused: $queryFocused) {
                    workspace.runFindInFiles()
                }

                Button(action: workspace.runFindInFiles) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(IDEAppearance.ColorToken.accent)
                .help("Search")
                .accessibilityLabel("Search")

                Button(action: workspace.hideFindInFiles) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .help("Close")
                .accessibilityLabel("Close")
            }
            .padding(.leading, leadingInset + IDEAppearance.Spacing.md)
            .padding(.trailing, IDEAppearance.Spacing.md)
            .padding(.vertical, IDEAppearance.Spacing.sm)

            HStack {
                Text(workspace.findInFilesStatus)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Spacer()
            }
            .padding(.leading, leadingInset + IDEAppearance.Spacing.md)
            .padding(.trailing, IDEAppearance.Spacing.md)
            .padding(.bottom, IDEAppearance.Spacing.xs)

            if workspace.findInFilesHits.isEmpty {
                FindInFilesEmptyState(message: emptyMessage)
            } else {
                List(workspace.findInFilesHits) { hit in
                    FindInFilesHitRow(hit: hit, label: hitLabel(hit)) {
                        workspace.openFindInFilesHit(hit)
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(height: 220)
        .background(IDEAppearance.ColorToken.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)
        }
        .task { queryFocused = true }
        .onExitCommand { workspace.hideFindInFiles() }
    }

    private var emptyMessage: String {
        if workspace.project.rootURL == nil {
            return "Open a folder to search files on disk."
        }
        if workspace.findInFilesQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Type a query and press Return."
        }
        return "No matches."
    }

    private func hitLabel(_ hit: ProjectSearchResult) -> String {
        let path: String
        if let root = workspace.project.rootURL {
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            if hit.url.path.hasPrefix(rootPath) {
                path = String(hit.url.path.dropFirst(rootPath.count))
            } else {
                path = hit.url.lastPathComponent
            }
        } else {
            path = hit.url.lastPathComponent
        }
        return "\(path):\(hit.line + 1)"
    }
}

/// Token-styled replacement for `.textFieldStyle(.roundedBorder)` — a leading magnifier glyph and
/// a rounded container that brightens to the accent color while focused, matching the in-editor
/// find bar's `FindPanelFieldContainer` (Penumbra's AppKit side) so both read as one system.
private struct FindInFilesSearchField: View {
    @Binding var query: String
    var isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            TextField("Search project files", text: $query)
                .textFieldStyle(.plain)
                .font(IDEAppearance.Typography.monoCaption)
                .focused(isFocused)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .frame(height: 24)
        .background(IDEAppearance.ColorToken.editor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: IDEAppearance.Radius.control)
                .strokeBorder(isFocused.wrappedValue ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.border, lineWidth: 1)
        }
    }
}

private struct FindInFilesHitRow: View {
    let hit: ProjectSearchResult
    let label: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: IDEAppearance.Spacing.xs) {
                Image(systemName: IDEFileIcon.systemName(forFilename: hit.url.lastPathComponent))
                    .font(.system(size: 11))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: 14)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(IDEAppearance.Typography.monoCaption)
                        .foregroundStyle(IDEAppearance.ColorToken.foreground)
                        .lineLimit(1)
                    Text(hit.preview.trimmingCharacters(in: .whitespaces))
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }
}

private struct FindInFilesEmptyState: View {
    let message: String

    var body: some View {
        VStack(spacing: IDEAppearance.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text(message)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, IDEAppearance.Spacing.md)
    }
}
