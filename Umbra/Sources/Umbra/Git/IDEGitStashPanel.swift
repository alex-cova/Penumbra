import GitIntelligence
import SwiftUI

/// The History panel's Stashes sub-tab: the stash list beside the selected stash's files.
struct IDEGitStashPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    let gitStatus: IDEGitStatusModel
    @State private var typeahead = IDETypeaheadBuffer()
    @State private var fileTypeahead = IDETypeaheadBuffer()
    @State private var selectedFileID: String?
    @FocusState private var isListFocused: Bool
    @FocusState private var isFilesFocused: Bool

    private static let dateStyle = Date.RelativeFormatStyle(presentation: .named, unitsStyle: .abbreviated)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Text(gitStatus.stashes.isEmpty ? "No stashes" : "\(gitStatus.stashes.count) stashed")
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Spacer(minLength: 0)
                Button("Stash Changes…") { gitStatus.requestStashChanges() }
                    .buttonStyle(.plain)
                    .foregroundStyle(IDEAppearance.ColorToken.accent)
                Button("Clear All…") { gitStatus.requestClearStashes() }
                    .buttonStyle(.plain)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .disabled(gitStatus.stashes.isEmpty)
            }
            .font(IDEAppearance.Typography.caption)
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, IDEAppearance.Spacing.xs)

            SplitPanes(
                minPrimary: 220, maxPrimary: 700, idealPrimary: 380, minSecondary: 200,
                storageKey: "umbra.git.stashSplit"
            ) {
                list
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .idePanel(fill: IDEAppearance.ColorToken.editor)
            } secondary: {
                files
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .idePanel(fill: IDEAppearance.ColorToken.editor)
            }
            .padding(.horizontal, IDEAppearance.Spacing.panelGap)
            .padding(.bottom, IDEAppearance.Spacing.panelGap)
        }
        .onAppear { gitStatus.loadStashes() }
        .onChange(of: gitStatus.selectedStashHash) { _, _ in
            selectedFileID = nil
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(gitStatus.stashes) { stash in
                        row(stash)
                            .id(stash.hash)
                    }
                }
                .padding(.vertical, IDEAppearance.Spacing.xs)
            }
            .focusable()
            .focused($isListFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in
                handleListKey(press)
            }
            .onChange(of: gitStatus.selectedStashHash) { _, hash in
                if let hash { proxy.scrollTo(hash) }
            }
        }
    }

    private func handleListKey(_ press: KeyPress) -> KeyPress.Result {
        let hashes = gitStatus.stashes.map(\.hash)
        switch press.key {
        case .upArrow, .downArrow:
            typeahead.reset()
            gitStatus.moveStashSelection(by: press.key == .downArrow ? 1 : -1, in: hashes)
            isListFocused = true
            return .handled
        case .return:
            typeahead.reset()
            isFilesFocused = true
            if selectedFileID == nil { selectedFileID = gitStatus.stashFiles.first?.id }
            return .handled
        case .escape:
            typeahead.reset()
            workspace.focusActiveEditor()
            return .handled
        default:
            guard let character = IDEListTypeahead.character(from: press) else { return .ignored }
            if let hash = IDEListTypeahead.match(
                query: typeahead.typed(character),
                in: hashes,
                selected: gitStatus.selectedStashHash,
                title: { hash in gitStatus.stashes.first { $0.hash == hash }?.title ?? "" }
            ) {
                gitStatus.selectStash(hash)
                isListFocused = true
            }
            return .handled
        }
    }

    private func row(_ stash: GitStash) -> some View {
        let isSelected = gitStatus.selectedStashHash == stash.hash
        return Button {
            isListFocused = true
            gitStatus.selectStash(stash.hash)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(stash.title).lineLimit(1).truncationMode(.tail)
                Text([stash.ref, stash.branch, stash.date.formatted(Self.dateStyle)].compactMap { $0 }.joined(separator: " · "))
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            .font(IDEAppearance.Typography.caption)
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, IDEAppearance.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? IDEAppearance.ColorToken.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Apply") { gitStatus.applyStash(stash) }
            Button("Apply and Restore Staged Changes") { gitStatus.applyStash(stash, reinstateIndex: true) }
            Button("Pop (Apply and Drop)") { gitStatus.applyStash(stash, drop: true) }
            Divider()
            Button("New Branch from Stash…") { gitStatus.requestBranchFromStash(stash) }
            Button("Copy Revision") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(stash.hash, forType: .string)
            }
            Divider()
            Button("Drop…", role: .destructive) { gitStatus.requestDropStash(stash) }
        }
    }

    @ViewBuilder
    private var files: some View {
        if let hash = gitStatus.selectedStashHash, let stash = gitStatus.stashes.first(where: { $0.hash == hash }) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if gitStatus.stashFiles.isEmpty {
                            Text("Loading…")
                                .font(IDEAppearance.Typography.caption)
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                                .padding(IDEAppearance.Spacing.md)
                        }
                        ForEach(gitStatus.stashFiles) { change in
                            stashFileRow(change, stash: stash)
                                .id(change.id)
                        }
                    }
                    .padding(.vertical, IDEAppearance.Spacing.xs)
                }
                .focusable()
                .focused($isFilesFocused)
                .focusEffectDisabled()
                .onKeyPress(phases: [.down, .repeat]) { press in
                    handleFilesKey(press, stash: stash)
                }
                .onChange(of: selectedFileID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        } else {
            Text("Select a stash to see its files.")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func stashFileRow(_ change: GitStashChange, stash: GitStash) -> some View {
        let isSelected = selectedFileID == change.id
        return HStack(spacing: IDEAppearance.Spacing.sm) {
            Text(change.isUntracked ? "?" : String(change.file.status))
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(color(for: change))
                .frame(width: 14)
            Text(change.file.path).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(IDEAppearance.Typography.caption)
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? IDEAppearance.ColorToken.selection : Color.clear)
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .onTapGesture(count: 2) { workspace.openStashDiff(stash: stash, change: change) }
        .onTapGesture {
            isFilesFocused = true
            selectedFileID = change.id
        }
    }

    private func handleFilesKey(_ press: KeyPress, stash: GitStash) -> KeyPress.Result {
        let ids = gitStatus.stashFiles.map(\.id)
        switch press.key {
        case .upArrow, .downArrow:
            fileTypeahead.reset()
            if let next = IDEListNeighbor.move(selectedFileID, in: ids, by: press.key == .downArrow ? 1 : -1) {
                selectedFileID = next
                isFilesFocused = true
            }
            return .handled
        case .return:
            fileTypeahead.reset()
            if let id = selectedFileID, let change = gitStatus.stashFiles.first(where: { $0.id == id }) {
                workspace.openStashDiff(stash: stash, change: change)
            }
            return .handled
        case .escape:
            fileTypeahead.reset()
            isListFocused = true
            return .handled
        default:
            guard let character = IDEListTypeahead.character(from: press) else { return .ignored }
            if let id = IDEListTypeahead.match(
                query: fileTypeahead.typed(character),
                in: ids,
                selected: selectedFileID,
                title: { id in gitStatus.stashFiles.first { $0.id == id }.map { ($0.file.path as NSString).lastPathComponent } ?? "" }
            ) {
                selectedFileID = id
                isFilesFocused = true
            }
            return .handled
        }
    }

    private func color(for change: GitStashChange) -> Color {
        if change.isUntracked { return IDEAppearance.ColorToken.gitUntracked }
        switch change.file.status {
        case "A": return IDEAppearance.ColorToken.gitAdded
        case "D": return IDEAppearance.ColorToken.error
        default: return IDEAppearance.ColorToken.gitModified
        }
    }
}
