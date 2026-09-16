import EditorIntelligence
import SwiftUI

struct FindInFilesPanel: View {
    @EnvironmentObject private var workspace: IDEWorkspace
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Text("Find in Files")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .fixedSize()
                TextField("Search project files", text: $workspace.findInFilesQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($queryFocused)
                    .onSubmit { workspace.runFindInFiles() }
                Button("Find") { workspace.runFindInFiles() }
                Button {
                    workspace.hideFindInFiles()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, IDEAppearance.Spacing.sm)

            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)

            HStack {
                Text(workspace.findInFilesStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Spacer()
            }
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, 4)

            if workspace.findInFilesHits.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, IDEAppearance.Spacing.md)
                    .padding(.top, IDEAppearance.Spacing.sm)
            } else {
                List(workspace.findInFilesHits) { hit in
                    Button {
                        workspace.openFindInFilesHit(hit)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hitLabel(hit))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                                .lineLimit(1)
                            Text(hit.preview.trimmingCharacters(in: .whitespaces))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(height: 220)
        .background(IDEAppearance.ColorToken.sidebar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)
        }
        .onAppear { queryFocused = true }
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
        // `line` is 0-based (matching WorkspaceSearchResult); display 1-based like an editor gutter.
        return "\(path):\(hit.line + 1)"
    }
}
