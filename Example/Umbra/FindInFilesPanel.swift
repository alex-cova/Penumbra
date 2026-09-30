import EditorIntelligence
import SwiftUI

/// Which files Find and Replace in Files looks at, on top of the file mask.
enum IDEFindInFilesScope: Equatable {
    case project
    case directory(URL)
    case openFiles
    case changedFiles
}

/// Project-wide search drawer, docked to the top of the editor column (see `IDERootView`) so it
/// reads as part of the same "find" system as the in-editor bar rather than a separate bottom
/// panel.
struct FindInFilesPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @FocusState private var queryFocused: Bool
    @FocusState private var replacementFocused: Bool
    @State private var maskRerun: Task<Void, Never>?

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                FindInFilesSearchField(query: $workspace.findInFilesQuery, isFocused: $queryFocused) {
                    workspace.runFindInFiles()
                }

                FindInFilesOptionToggle(label: "Aa", help: "Match Case", isOn: $workspace.findInFilesCaseSensitive)
                FindInFilesOptionToggle(label: "W", help: "Whole Word", isOn: $workspace.findInFilesWholeWord)
                FindInFilesOptionToggle(label: ".*", help: "Regular Expression", isOn: $workspace.findInFilesRegex)

                Button(action: workspace.runFindInFiles) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(IDEAppearance.ColorToken.accent)
                .help("Search")
                .accessibilityLabel("Search")

                Button {
                    workspace.isFindInFilesReplaceVisible.toggle()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(workspace.isFindInFilesReplaceVisible ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.muted)
                .help("Replace")
                .accessibilityLabel("Show Replace")

                Button(action: workspace.hideFindInFiles) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .help("Close")
                .accessibilityLabel("Close")
            }
            .padding(.leading, IDEAppearance.Spacing.md)
            .padding(.trailing, IDEAppearance.Spacing.md)
            .padding(.vertical, IDEAppearance.Spacing.sm)

            if workspace.isFindInFilesReplaceVisible {
                HStack(spacing: IDEAppearance.Spacing.sm) {
                    FindInFilesSearchField(
                        query: $workspace.findInFilesReplacement,
                        isFocused: $replacementFocused,
                        placeholder: "Replace with",
                        symbol: "arrow.left.arrow.right"
                    ) {
                        workspace.replaceInFiles()
                    }
                    Button("Replace All…", action: workspace.replaceInFiles)
                        .controlSize(.small)
                        .disabled(workspace.findInFilesQuery.isEmpty)
                        .help("Preview the changes before anything is edited")
                }
                .padding(.leading, IDEAppearance.Spacing.md)
                .padding(.trailing, IDEAppearance.Spacing.md)
                .padding(.bottom, IDEAppearance.Spacing.sm)
            }

            HStack(spacing: IDEAppearance.Spacing.sm) {
                FindInFilesMaskField(mask: $workspace.findInFilesMask)
                Menu {
                    scopeButton("Project", scope: .project)
                    Button("Directory…", action: chooseScopeDirectory)
                    scopeButton("Open Files", scope: .openFiles)
                    scopeButton("Changed Files (git)", scope: .changedFiles)
                } label: {
                    Text(scopeTitle)
                        .font(IDEAppearance.Typography.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Where to search")
            }
            .padding(.leading, IDEAppearance.Spacing.md)
            .padding(.trailing, IDEAppearance.Spacing.md)
            .padding(.bottom, IDEAppearance.Spacing.sm)

            HStack {
                Text(workspace.findInFilesMaskProblem ?? workspace.findInFilesStatus)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Spacer()
            }
            .padding(.leading, IDEAppearance.Spacing.md)
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
        .frame(height: workspace.isFindInFilesReplaceVisible ? 292 : 256)
        .background(IDEAppearance.ColorToken.sidebar)
        .task { queryFocused = true }
        .onExitCommand { workspace.hideFindInFiles() }
        // Results shown for one set of options would be wrong for another.
        .onChange(of: workspace.findInFilesCaseSensitive) { rerunIfSearching() }
        .onChange(of: workspace.findInFilesWholeWord) { rerunIfSearching() }
        .onChange(of: workspace.findInFilesRegex) { rerunIfSearching() }
        .onChange(of: workspace.findInFilesScope) { rerunIfSearching() }
        .onChange(of: workspace.findInFilesMask) { scheduleMaskRerun() }
    }

    /// Typing a mask re-runs the search once the typing pauses, not on every character.
    private func scheduleMaskRerun() {
        maskRerun?.cancel()
        maskRerun = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            rerunIfSearching()
        }
    }

    private func scopeButton(_ title: String, scope: IDEFindInFilesScope) -> some View {
        Button {
            workspace.findInFilesScope = scope
        } label: {
            if workspace.findInFilesScope == scope { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private var scopeTitle: String {
        switch workspace.findInFilesScope {
        case .project: "Project"
        case .directory(let url): "Folder: \(url.lastPathComponent)"
        case .openFiles: "Open Files"
        case .changedFiles: "Changed Files"
        }
    }

    private func chooseScopeDirectory() {
        guard let root = workspace.project.rootURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.prompt = "Search Here"
        panel.message = "Choose a folder inside the project to search."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else {
            workspace.findInFilesStatus = "Choose a folder inside the project"
            return
        }
        workspace.findInFilesScope = path == rootPath ? .project : .directory(url)
    }

    private func rerunIfSearching() {
        if !workspace.findInFilesQuery.isEmpty { workspace.runFindInFiles() }
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

/// The file mask field under the query: `*.java, !*Test.java`.
private struct FindInFilesMaskField: View {
    @Binding var mask: String

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 10))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            TextField("File mask, e.g. *.java, !*Test.java", text: $mask)
                .textFieldStyle(.plain)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .autocorrectionDisabled()
                .accessibilityLabel("File mask")
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
        .background(IDEAppearance.ColorToken.tabActive)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
    }
}

/// Token-styled replacement for `.textFieldStyle(.roundedBorder)` — a leading magnifier glyph and
/// a rounded container that brightens to the accent color while focused, matching the in-editor
/// find bar's `FindPanelFieldContainer` (Penumbra's AppKit side) so both read as one system.
private struct FindInFilesSearchField: View {
    @Binding var query: String
    var isFocused: FocusState<Bool>.Binding
    var placeholder = "Search project files"
    var symbol = "magnifyingglass"
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            TextField(placeholder, text: $query)
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

/// A small on/off button beside the search field: match case, whole word, regular expression.
private struct FindInFilesOptionToggle: View {
    let label: String
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(label)
                .font(IDEAppearance.Typography.monoSmall.weight(.semibold))
                .foregroundStyle(isOn ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.muted)
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: IDEAppearance.Radius.control)
                        .fill(isOn ? IDEAppearance.ColorToken.accent.opacity(0.15) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
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

#Preview {
    FindInFilesPanel()
        .environment({
            let workspace = IDEWorkspace()
            workspace.findInFilesQuery = "TODO"
            workspace.findInFilesStatus = "2 results"
            workspace.findInFilesHits = [
                ProjectSearchResult(
                    url: URL(fileURLWithPath: "/project/src/ui/Editor.swift"),
                    line: 41,
                    column: 4,
                    preview: "    // TODO: handle multi-caret paste",
                    range: TextRange(
                        start: TextPosition(line: 41, column: 4, utf16Offset: 0),
                        end: TextPosition(line: 41, column: 8, utf16Offset: 4)
                    )
                ),
                ProjectSearchResult(
                    url: URL(fileURLWithPath: "/project/src/ui/Sidebar.swift"),
                    line: 12,
                    column: 8,
                    preview: "        // TODO: restore scroll position",
                    range: TextRange(
                        start: TextPosition(line: 12, column: 8, utf16Offset: 0),
                        end: TextPosition(line: 12, column: 12, utf16Offset: 4)
                    )
                )
            ]
            return workspace
        }())
        .preferredColorScheme(IDEAppearance.preferredColorScheme)
}
