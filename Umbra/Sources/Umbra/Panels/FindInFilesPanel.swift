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
    @FocusState private var isListFocused: Bool
    @State private var maskRerun: Task<Void, Never>?
    @State private var typeahead = IDETypeaheadBuffer()

    var body: some View {
        @Bindable var model = workspace.findInFiles
        VStack(spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                FindInFilesSearchField(
                    query: $model.query,
                    isFocused: $queryFocused,
                    onMoveDown: moveFromQueryIntoResults
                ) {
                    submitQuery()
                }

                FindInFilesOptionToggle(label: "Aa", help: "Match Case", isOn: $model.isCaseSensitive)
                FindInFilesOptionToggle(label: "W", help: "Whole Word", isOn: $model.matchesWholeWord)
                FindInFilesOptionToggle(label: ".*", help: "Regular Expression", isOn: $model.usesRegex)

                IDEIconButton(
                    systemImage: "magnifyingglass",
                    help: "Search",
                    tint: IDEAppearance.ColorToken.accent,
                    action: submitQuery
                )
                IDEIconButton(
                    systemImage: "arrow.left.arrow.right",
                    help: "Replace",
                    isActive: workspace.findInFiles.isReplaceVisible
                ) {
                    workspace.findInFiles.isReplaceVisible.toggle()
                }
                IDEIconButton(systemImage: "xmark", help: "Close", action: workspace.hideFindInFiles)
            }
            .padding(.leading, IDEAppearance.Spacing.md)
            .padding(.trailing, IDEAppearance.Spacing.md)
            .padding(.vertical, IDEAppearance.Spacing.sm)

            if workspace.findInFiles.isReplaceVisible {
                HStack(spacing: IDEAppearance.Spacing.sm) {
                    FindInFilesSearchField(
                        query: $model.replacement,
                        isFocused: $replacementFocused,
                        placeholder: "Replace with",
                        symbol: "arrow.left.arrow.right"
                    ) {
                        workspace.replaceInFiles()
                    }
                    Button("Replace All…", action: workspace.replaceInFiles)
                        .controlSize(.small)
                        .disabled(workspace.findInFiles.query.isEmpty)
                        .help("Preview the changes before anything is edited")
                }
                .padding(.leading, IDEAppearance.Spacing.md)
                .padding(.trailing, IDEAppearance.Spacing.md)
                .padding(.bottom, IDEAppearance.Spacing.sm)
            }

            HStack(spacing: IDEAppearance.Spacing.sm) {
                FindInFilesMaskField(mask: $model.mask)
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
                Text(workspace.findInFiles.maskProblem ?? workspace.findInFiles.status)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Spacer()
            }
            .padding(.leading, IDEAppearance.Spacing.md)
            .padding(.trailing, IDEAppearance.Spacing.md)
            .padding(.bottom, IDEAppearance.Spacing.xs)

            if workspace.findInFiles.hits.isEmpty {
                IDEEmptyState(symbol: "magnifyingglass", message: emptyMessage)
            } else {
                resultsList
            }
        }
        .frame(height: workspace.findInFiles.isReplaceVisible ? 292 : 256)
        .background(IDEAppearance.ColorToken.sidebar)
        .task { queryFocused = true }
        .onExitCommand {
            if isListFocused {
                queryFocused = true
            } else {
                workspace.hideFindInFiles()
            }
        }
        .onChange(of: workspace.findInFiles.resultsVersion) {
            takeResultsFocusIfRequested()
        }
        .onChange(of: workspace.findInFiles.focusGeneration) {
            takeResultsFocusIfRequested()
            takeQueryFocusIfRequested()
        }
        // Results shown for one set of options would be wrong for another.
        .onChange(of: workspace.findInFiles.isCaseSensitive) { rerunIfSearching() }
        .onChange(of: workspace.findInFiles.matchesWholeWord) { rerunIfSearching() }
        .onChange(of: workspace.findInFiles.usesRegex) { rerunIfSearching() }
        .onChange(of: workspace.findInFiles.scope) { rerunIfSearching() }
        .onChange(of: workspace.findInFiles.mask) { scheduleMaskRerun() }
    }

    private var resultsList: some View {
        let hits = workspace.findInFiles.hits
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(hits) { hit in
                        FindInFilesHitRow(
                            hit: hit,
                            label: hitLabel(hit),
                            isSelected: workspace.findInFiles.selectedHitID == hit.id
                        ) {
                            isListFocused = true
                            workspace.openFindInFilesHit(hit)
                        }
                        .id(hit.id)
                    }
                }
                .padding(.vertical, IDEAppearance.Spacing.xs)
            }
            .focusable()
            .focused($isListFocused)
            .onKeyPress(phases: [.down, .repeat]) { press in
                handleResultsKey(press)
            }
            .onChange(of: workspace.findInFiles.selectedHitID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .accessibilityLabel("Search results")
        }
    }

    private func handleResultsKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow:
            typeahead.reset()
            _ = workspace.findInFiles.moveSelection(-1)
            return .handled
        case .downArrow:
            typeahead.reset()
            _ = workspace.findInFiles.moveSelection(1)
            return .handled
        case .return:
            typeahead.reset()
            workspace.openSelectedFindInFilesHit()
            return .handled
        case .escape:
            typeahead.reset()
            queryFocused = true
            return .handled
        default:
            guard let character = IDEListTypeahead.character(from: press) else { return .ignored }
            let hits = workspace.findInFiles.hits
            if let hit = IDEListTypeahead.match(
                query: typeahead.typed(character),
                in: hits,
                selected: workspace.findInFiles.selectedHit,
                title: hitLabel
            ) {
                workspace.findInFiles.selectedHitID = hit.id
            }
            return .handled
        }
    }

    /// Return in the query field searches, then the list takes keyboard focus when hits arrive.
    private func submitQuery() {
        workspace.findInFiles.wantsResultsFocus = true
        workspace.runFindInFiles()
    }

    private func moveFromQueryIntoResults() -> KeyPress.Result {
        if workspace.findInFiles.selectedHitID == nil {
            guard workspace.findInFiles.moveSelection(1) else { return .ignored }
        }
        guard workspace.findInFiles.selectedHitID != nil else { return .ignored }
        isListFocused = true
        return .handled
    }

    private func takeResultsFocusIfRequested() {
        guard workspace.findInFiles.wantsResultsFocus else { return }
        workspace.findInFiles.wantsResultsFocus = false
        guard workspace.findInFiles.selectedHitID != nil else { return }
        isListFocused = true
    }

    private func takeQueryFocusIfRequested() {
        guard workspace.findInFiles.wantsQueryFocus else { return }
        workspace.findInFiles.wantsQueryFocus = false
        queryFocused = true
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
            workspace.findInFiles.scope = scope
        } label: {
            if workspace.findInFiles.scope == scope { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private var scopeTitle: String {
        switch workspace.findInFiles.scope {
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
            workspace.findInFiles.status = "Choose a folder inside the project"
            return
        }
        workspace.findInFiles.scope = path == rootPath ? .project : .directory(url)
    }

    private func rerunIfSearching() {
        if !workspace.findInFiles.query.isEmpty { workspace.runFindInFiles() }
    }

    private var emptyMessage: String {
        if workspace.project.rootURL == nil {
            return "Open a folder to search files on disk."
        }
        if workspace.findInFiles.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                .font(.system(size: IDEAppearance.IconSize.smallGlyph))
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
    var onMoveDown: (() -> KeyPress.Result)?
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: symbol)
                .font(.system(size: IDEAppearance.IconSize.rowGlyph))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(IDEAppearance.Typography.monoCaption)
                .focused(isFocused)
                .onSubmit(onSubmit)
                .onKeyPress(.downArrow) { onMoveDown?() ?? .ignored }
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
    var isSelected = false
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: IDEAppearance.Spacing.xs) {
                Image(systemName: IDEFileIcon.systemName(forFilename: hit.url.lastPathComponent))
                    .font(.system(size: IDEAppearance.IconSize.rowGlyph))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: 14)
                    .padding(.top, IDEAppearance.Spacing.xxs)

                VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xxs) {
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
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, IDEAppearance.Spacing.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? IDEAppearance.ColorToken.selection : (isHovering ? IDEAppearance.ColorToken.controlHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    FindInFilesPanel()
        .environment({
            let workspace = IDEWorkspace()
            workspace.findInFiles.query = "TODO"
            workspace.findInFiles.status = "2 results"
            workspace.findInFiles.setResults([
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
            ])
            return workspace
        }())
        .preferredColorScheme(IDEAppearance.preferredColorScheme)
}
