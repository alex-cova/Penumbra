import AppKit
import GitIntelligence
import SwiftUI

/// The Changes file list. Its body does not read `commitMessage`. The parent passes the snapshot
/// the list paints, and `EquatableView` skips this body when a commit-field edit leaves that
/// snapshot unchanged.
struct IDEChangesFileList: View, Equatable {
    @Environment(IDEWorkspace.self) private var workspace
    var gitStatus: IDEGitStatusModel
    /// Sendable snapshot fields. Equality is nonisolated so `EquatableView` can skip this body
    /// without crossing the main actor.
    nonisolated let changes: [IDEGitChange]
    nonisolated let selectedChanges: Set<IDEGitListedChange>
    nonisolated let selectedChange: IDEGitListedChange?
    /// Compared so a refresh-state change updates the list. The rows themselves paint `changes`.
    nonisolated let refreshState: GitRefreshState
    /// Compared so a busy change updates the list. Row actions still call the model directly.
    nonisolated let isBusy: Bool
    nonisolated let listIsFocused: Bool
    var isListFocused: FocusState<Bool>.Binding
    var messageFocused: FocusState<Bool>.Binding

    @State private var typeahead = IDETypeaheadBuffer()
    @State private var scrollToken: String?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.changes == rhs.changes
            && lhs.selectedChanges == rhs.selectedChanges
            && lhs.selectedChange == rhs.selectedChange
            && lhs.refreshState == rhs.refreshState
            && lhs.isBusy == rhs.isBusy
            && lhs.listIsFocused == rhs.listIsFocused
    }

    var body: some View {
        let conflicted = conflictedChanges
        let staged = stagedChanges
        let unstaged = unstagedChanges
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: IDEAppearance.Spacing.xxs) {
                    if !conflicted.isEmpty {
                        sectionHeader("Conflicts", count: conflicted.count)
                        ForEach(conflicted) { change in
                            IDEConflictRow(
                                change: change,
                                isSelected: selectedChanges.contains(IDEGitListedChange(section: .conflict, path: change.path)),
                                showsFocus: listIsFocused && selectedChange == IDEGitListedChange(section: .conflict, path: change.path),
                                onSelect: {
                                    let row = IDEGitListedChange(section: .conflict, path: change.path)
                                    isListFocused.wrappedValue = true
                                    scrollToken = row.scrollID
                                    select(change, section: .conflict, in: conflicted)
                                },
                                onMerge: { workspace.openMergeTool(forPath: change.path) },
                                onTakeYours: { gitStatus.resolve(paths: [change.path], taking: .ours) },
                                onTakeTheirs: { gitStatus.resolve(paths: [change.path], taking: .theirs) },
                                onOpenFile: { Task { await workspace.openDocument(from: URL(fileURLWithPath: change.path)) } }
                            )
                            .id(IDEGitChangeListIdentity.id(section: .conflict, path: change.path))
                        }
                    }
                    if staged.isEmpty && unstaged.isEmpty && conflicted.isEmpty {
                        IDEEmptyState(symbol: "checkmark.circle", title: "No changes")
                    } else {
                        if !staged.isEmpty {
                            sectionHeader("Staged Changes", count: staged.count)
                            ForEach(staged) { change in
                                IDESourceControlChangeRow(
                                    change: change,
                                    section: .staged,
                                    isSelected: selectedChanges.contains(IDEGitListedChange(section: .staged, path: change.path)),
                                    showsFocus: listIsFocused && selectedChange == IDEGitListedChange(section: .staged, path: change.path),
                                    showsStage: false,
                                    onSelect: {
                                        let row = IDEGitListedChange(section: .staged, path: change.path)
                                        isListFocused.wrappedValue = true
                                        scrollToken = row.scrollID
                                        select(change, section: .staged, in: staged)
                                    },
                                    onOpen: { workspace.openChangeDiff(path: change.path, staged: true) },
                                    onOpenFile: { Task { await workspace.openDocument(from: URL(fileURLWithPath: change.path)) } },
                                    onStage: {},
                                    onUnstage: { gitStatus.unstage(paths: actionPaths(from: change, section: .staged)) },
                                    onRevert: { revert(from: change, section: .staged) }
                                )
                                .id(IDEGitChangeListIdentity.id(section: .staged, path: change.path))
                            }
                        }
                        if !unstaged.isEmpty {
                            sectionHeader("Unstaged Changes", count: unstaged.count)
                            ForEach(unstaged) { change in
                                IDESourceControlChangeRow(
                                    change: change,
                                    section: .unstaged,
                                    isSelected: selectedChanges.contains(IDEGitListedChange(section: .unstaged, path: change.path)),
                                    showsFocus: listIsFocused && selectedChange == IDEGitListedChange(section: .unstaged, path: change.path),
                                    showsStage: true,
                                    onSelect: {
                                        let row = IDEGitListedChange(section: .unstaged, path: change.path)
                                        isListFocused.wrappedValue = true
                                        scrollToken = row.scrollID
                                        select(change, section: .unstaged, in: unstaged)
                                    },
                                    onOpen: { workspace.openChangeDiff(path: change.path, staged: false) },
                                    onOpenFile: { Task { await workspace.openDocument(from: URL(fileURLWithPath: change.path)) } },
                                    onStage: { gitStatus.stage(paths: actionPaths(from: change, section: .unstaged)) },
                                    onUnstage: {},
                                    onRevert: { revert(from: change, section: .unstaged) }
                                )
                                .id(IDEGitChangeListIdentity.id(section: .unstaged, path: change.path))
                            }
                        }
                    }
                }
                .padding(.vertical, IDEAppearance.Spacing.sm)
            }
            .focusable()
            .focused(isListFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in
                handleListKey(press)
            }
            .onChange(of: selectedChange) { _, row in
                guard let row else { return }
                proxy.scrollTo(row.scrollID)
            }
            .onChange(of: scrollToken) { _, token in
                if let token { proxy.scrollTo(token) }
            }
        }
    }

    /// Conflicts, then staged, then unstaged — the order the list paints.
    private var visibleRows: [IDEGitListedChange] {
        IDEGitChangeRows.listed(in: changes)
    }

    private var conflictedChanges: [IDEGitChange] {
        changes.filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
    }

    private var stagedChanges: [IDEGitChange] {
        changes.filter { $0.staged != nil && $0.staged != .conflicted }
    }

    private var unstagedChanges: [IDEGitChange] {
        changes.filter { $0.unstaged != nil && $0.unstaged != .conflicted }
    }

    private func handleListKey(_ press: KeyPress) -> KeyPress.Result {
        let rows = visibleRows
        switch press.key {
        case .upArrow, .downArrow:
            typeahead.reset()
            let delta = press.key == .downArrow ? 1 : -1
            guard let next = IDEListNeighbor.move(gitStatus.selectedChange, in: rows, by: delta) else {
                return .handled
            }
            isListFocused.wrappedValue = true
            scrollToken = next.scrollID
            if press.modifiers.contains(.shift) {
                gitStatus.extendChangeSelection(to: next, in: rows)
            } else {
                gitStatus.selectChange(row: next)
            }
            return .handled
        case .return:
            typeahead.reset()
            activateSelectedChange()
            return .handled
        case .escape:
            typeahead.reset()
            messageFocused.wrappedValue = true
            workspace.isChangesListFocused = false
            return .handled
        default:
            // The Save menu consumes ⌘S before this view when that menu item is installed.
            // This runs only when no menu equivalent takes the key. ⌘U is not a menu key.
            if let action = IDEGitListShortcut.action(characters: press.characters, modifiers: press.modifiers) {
                typeahead.reset()
                switch action {
                case .stage: workspace.stageSelectedChanges()
                case .unstage: workspace.unstageSelectedChanges()
                }
                return .handled
            }
            guard let character = IDEListTypeahead.character(from: press) else { return .ignored }
            if let row = IDEListTypeahead.match(
                query: typeahead.typed(character),
                in: rows,
                selected: gitStatus.selectedChange,
                title: { ($0.path as NSString).lastPathComponent }
            ) {
                gitStatus.selectChange(row: row)
                scrollToken = row.scrollID
            }
            return .handled
        }
    }

    private func activateSelectedChange() {
        guard let row = gitStatus.selectedChange,
              let change = changes.first(where: { $0.path == row.path }) else { return }
        if row.section == .conflict || change.unstaged == .conflicted || change.staged == .conflicted {
            workspace.openMergeTool(forPath: row.path)
        } else {
            workspace.openChangeDiff(path: row.path, staged: row.section == .staged)
        }
    }

    /// Plain click selects one row, ⌘-click toggles it, ⇧-click extends inside this section.
    private func select(_ change: IDEGitChange, section: IDEGitChangeSection, in visible: [IDEGitChange]) {
        let row = IDEGitListedChange(section: section, path: change.path)
        let rows = visible.map { IDEGitListedChange(section: section, path: $0.path) }
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            gitStatus.toggleChangeSelection(row: row)
        } else if flags.contains(.shift) {
            gitStatus.extendChangeSelection(to: row, in: rows)
        } else {
            gitStatus.selectChange(row: row)
        }
    }

    /// The context menu acts on the whole selection when this row is part of it, else on that row.
    private func actionPaths(from change: IDEGitChange, section: IDEGitChangeSection) -> [String] {
        let row = IDEGitListedChange(section: section, path: change.path)
        guard selectedChanges.contains(row) else { return [change.path] }
        var seen = Set<String>()
        return IDEGitChangeRows.listed(in: changes).compactMap { listed in
            guard selectedChanges.contains(listed), seen.insert(listed.path).inserted else { return nil }
            return listed.path
        }
    }

    private func revert(from change: IDEGitChange, section: IDEGitChangeSection) {
        workspace.revertChanges(actionPaths(from: change, section: section))
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Text(title)
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            Spacer(minLength: 0)
            Text(count, format: .number)
                .font(IDEAppearance.Typography.tabLabel.monospacedDigit())
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.top, IDEAppearance.Spacing.sm)
        .padding(.bottom, IDEAppearance.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
