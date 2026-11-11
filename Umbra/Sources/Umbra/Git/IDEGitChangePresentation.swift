import Foundation
import GitIntelligence

/// Whether the Changes tab, the History tab, and Show Source Control are offered.
///
/// `.unavailable` is "this folder is not a work tree" and stays hidden. Every other state is a
/// repository Umbra is talking to, including a first status that is still running or that failed
/// before any snapshot existed.
enum IDEGitChrome {
    static func isVisible(_ state: GitRefreshState) -> Bool {
        switch state {
        case .unavailable:
            return false
        case .loading, .stale, .idle, .failed:
            return true
        }
    }

    /// The commit field stays hidden until a snapshot exists, so a commit cannot run against a
    /// repository the model never finished opening.
    static func showsCommitControls(_ state: GitRefreshState) -> Bool {
        state.snapshot != nil
    }
}

/// The one muted line under the change list while a status is in flight.
enum IDEGitRefreshCaption {
    static let updating = "Updating status…"

    static func updatingLine(_ state: GitRefreshState) -> String? {
        switch state {
        case .loading, .stale:
            return updating
        case .unavailable, .idle, .failed:
            return nil
        }
    }
}

/// Which block of the Changes list a row belongs to. Scroll identity is the section plus the path,
/// because one file can sit in Staged and Changes at once.
enum IDEGitChangeSection: String, Equatable, Hashable, Sendable {
    case conflict
    case staged
    case unstaged

    var accessibilityName: String {
        switch self {
        case .conflict: "conflict"
        case .staged: "staged"
        case .unstaged: "unstaged"
        }
    }
}

enum IDEGitChangeListIdentity {
    static func id(section: IDEGitChangeSection, path: String) -> String {
        section.rawValue + "\t" + path
    }
}

/// One row of the Changes list, identified by section so a path in two sections can be scrolled to
/// the copy the user selected.
struct IDEGitListedChange: Equatable, Hashable, Sendable {
    var section: IDEGitChangeSection
    var path: String

    var scrollID: String { IDEGitChangeListIdentity.id(section: section, path: path) }
}

/// Conflicts, then staged, then unstaged. The model and the list share this order, so a selection
/// reconciled after a refresh lands on the row the list paints.
enum IDEGitChangeRows {
    static func listed(in changes: [IDEGitChange]) -> [IDEGitListedChange] {
        var conflict: [IDEGitListedChange] = []
        var staged: [IDEGitListedChange] = []
        var unstaged: [IDEGitListedChange] = []
        for change in changes {
            if change.staged == .conflicted || change.unstaged == .conflicted {
                conflict.append(IDEGitListedChange(section: .conflict, path: change.path))
                continue
            }
            if change.staged != nil {
                staged.append(IDEGitListedChange(section: .staged, path: change.path))
            }
            if change.unstaged != nil {
                unstaged.append(IDEGitListedChange(section: .unstaged, path: change.path))
            }
        }
        return conflict + staged + unstaged
    }
}

/// The Changes selection. The model is the only owner. A row is the repository root, the section,
/// and the absolute path. The section is the change side (staged, unstaged, or conflict).
struct IDEGitChangeSelection: Equatable, Sendable {
    var primary: IDEGitListedChange?
    var rows: Set<IDEGitListedChange> = []
    /// The work tree these rows were selected in. A refresh of another root drops them.
    var repositoryRoot: String?

    var paths: Set<String> { Set(rows.map(\.path)) }

    func selecting(_ row: IDEGitListedChange?, repositoryRoot: String?) -> IDEGitChangeSelection {
        IDEGitChangeSelection(
            primary: row,
            rows: row.map { [$0] } ?? [],
            repositoryRoot: repositoryRoot ?? self.repositoryRoot
        )
    }

    func toggling(_ row: IDEGitListedChange) -> IDEGitChangeSelection {
        var next = self
        if next.rows.remove(row) != nil {
            if next.primary == row {
                next.primary = next.rows.min { lhs, rhs in
                    if lhs.path != rhs.path { return lhs.path < rhs.path }
                    return lhs.section.rawValue < rhs.section.rawValue
                }
            }
        } else {
            next.rows.insert(row)
            next.primary = row
        }
        return next
    }

    /// ⇧-click and ⇧-arrow. The range is `visible` only, so a shift-click inside one section
    /// cannot select the other copy of a path.
    func extending(to row: IDEGitListedChange, in visible: [IDEGitListedChange]) -> IDEGitChangeSelection {
        guard let anchor = primary,
              let from = visible.firstIndex(of: anchor),
              let to = visible.firstIndex(of: row) else {
            return selecting(row, repositoryRoot: repositoryRoot)
        }
        var next = self
        next.rows.formUnion(visible[min(from, to)...max(from, to)])
        next.primary = row
        return next
    }

    /// Drops rows the snapshot no longer has. A path that lost the focused section follows the
    /// copy that remains. A different repository clears the selection even when a path string matches.
    func reconciled(with visible: [IDEGitListedChange], repositoryRoot newRoot: String?) -> IDEGitChangeSelection {
        if let newRoot, let current = repositoryRoot, current != newRoot {
            return IDEGitChangeSelection(repositoryRoot: newRoot)
        }
        let present = Set(visible)
        var kept = Set<IDEGitListedChange>()
        for row in rows {
            if present.contains(row) {
                kept.insert(row)
            } else if let moved = visible.first(where: { $0.path == row.path }) {
                kept.insert(moved)
            }
        }
        var primary = self.primary
        if let current = primary {
            if present.contains(current) {
                primary = current
            } else if let moved = visible.first(where: { $0.path == current.path }) {
                primary = moved
            } else {
                primary = visible.first { kept.contains($0) }
            }
        }
        if let primary {
            kept.insert(primary)
        } else {
            kept = []
        }
        return IDEGitChangeSelection(primary: primary, rows: kept, repositoryRoot: newRoot ?? repositoryRoot)
    }
}

/// Letter, noun, and the old path of a rename or copy. Built from the porcelain entry, not from the
/// collapsed explorer tint.
struct IDEGitChangePresentation: Equatable, Sendable {
    var letter: String
    var noun: String
    /// The path a rename or copy came from. Nil for every other change.
    var fromPath: String?

    enum Side: Equatable, Sendable {
        case index
        case worktree
    }

    static func make(entry: GitStatusEntry, side: Side) -> IDEGitChangePresentation {
        if entry.isConflicted {
            return IDEGitChangePresentation(letter: "U", noun: "Conflict", fromPath: nil)
        }
        let code: Character = switch side {
        case .index: entry.indexCode
        case .worktree: entry.worktreeCode
        }
        return make(code: code, originalPath: entry.originalPath)
    }

    static func make(code: Character, originalPath: String?) -> IDEGitChangePresentation {
        switch code {
        case "A":
            return IDEGitChangePresentation(letter: "A", noun: "Added", fromPath: nil)
        case "M":
            return IDEGitChangePresentation(letter: "M", noun: "Modified", fromPath: nil)
        case "D":
            return IDEGitChangePresentation(letter: "D", noun: "Deleted", fromPath: nil)
        case "R":
            return IDEGitChangePresentation(letter: "R", noun: "Renamed", fromPath: originalPath)
        case "C":
            return IDEGitChangePresentation(letter: "C", noun: "Copied", fromPath: originalPath)
        case "?":
            return IDEGitChangePresentation(letter: "?", noun: "Untracked", fromPath: nil)
        case "U":
            return IDEGitChangePresentation(letter: "U", noun: "Conflict", fromPath: nil)
        case "!":
            return IDEGitChangePresentation(letter: "!", noun: "Ignored", fromPath: nil)
        case " ":
            return IDEGitChangePresentation(letter: "", noun: "", fromPath: nil)
        default:
            return IDEGitChangePresentation(letter: String(code), noun: "Modified", fromPath: nil)
        }
    }

    /// The row title. A rename or copy names both paths.
    func title(path: String) -> String {
        if let fromPath, !fromPath.isEmpty {
            return "\(fromPath) → \(path)"
        }
        return path
    }

    /// VoiceOver name: the noun, the path (both paths for a rename), and the section.
    func accessibilityLabel(path: String, section: IDEGitChangeSection) -> String {
        if section == .conflict || noun == "Conflict" {
            return "Conflict in \(path)"
        }
        if let fromPath, !fromPath.isEmpty {
            return "\(noun) from \(fromPath) to \(path), \(section.accessibilityName)"
        }
        return "\(noun), \(path), \(section.accessibilityName)"
    }
}

extension IDEGitChange {
    /// The porcelain entry this row was parsed from. The explorer tint stays collapsed; the letter
    /// comes from these codes.
    func statusEntry() -> GitStatusEntry {
        GitStatusEntry(path: relativePath, originalPath: originalPath, indexCode: indexCode, worktreeCode: worktreeCode)
    }

    func presentation(in section: IDEGitChangeSection) -> IDEGitChangePresentation {
        let side: IDEGitChangePresentation.Side = section == .staged ? .index : .worktree
        return IDEGitChangePresentation.make(entry: statusEntry(), side: side)
    }
}

/// The color of a row's porcelain letter. The explorer tint stays the collapsed status.
enum IDEGitLetterTint: Equatable, Sendable {
    case added
    case modified
    case deleted
    case conflict
    case ignored
    case muted

    static func tint(forLetter letter: String) -> IDEGitLetterTint {
        switch letter {
        case "A", "?", "C": .added
        case "D": .deleted
        case "U": .conflict
        case "R", "M": .modified
        case "!": .ignored
        default: .muted
        }
    }
}

/// Which copy of a path stays focused after a refresh. A path in both sections keeps the section
/// that already had focus. When that copy is gone, focus follows the copy that remains.
enum IDEGitListFocus {
    static func section(
        focused: IDEGitChangeSection,
        path: String?,
        rows: [IDEGitListedChange]
    ) -> IDEGitChangeSection {
        guard let path else { return focused }
        if rows.contains(where: { $0.path == path && $0.section == focused }) {
            return focused
        }
        return rows.first { $0.path == path }?.section ?? focused
    }
}

/// The noun the Explorer speaks for a collapsed status. A file that has a change row uses that
/// row's presentation instead, so a deletion is "Deleted" even though the folder tint stays modified.
enum IDEGitStatusNoun {
    static func noun(for status: IDEGitFileStatus) -> String {
        switch status {
        case .modified: "Modified"
        case .added: "Added"
        case .untracked: "Untracked"
        case .conflicted: "Conflict"
        case .ignored: "Ignored"
        }
    }
}

/// The word an explorer row speaks. The tint stays the collapsed status. A file with a change row
/// speaks that row's porcelain noun, so a deletion is "Deleted" and a rename is "Renamed".
enum IDEGitExplorerNoun {
    static func spoken(status: IDEGitFileStatus?, change: IDEGitChange?) -> String? {
        guard let status else { return nil }
        if let change {
            let noun = change.presentation(in: section(for: change)).noun
            if !noun.isEmpty { return noun }
        }
        return IDEGitStatusNoun.noun(for: status)
    }

    /// Work-tree side when the file has one, otherwise the index. A conflict speaks "Conflict".
    static func section(for change: IDEGitChange) -> IDEGitChangeSection {
        if change.staged == .conflicted || change.unstaged == .conflicted { return .conflict }
        if change.unstaged != nil { return .unstaged }
        return .staged
    }
}

/// History's empty line. "Loading history…" until the load for this list has applied. After that,
/// the empty copy depends on whether the list is the whole log, one file, or a line range.
enum IDEGitHistoryPlaceholder {
    static func text(hasLoaded: Bool, isEmpty: Bool, fileScoped: Bool, lineScoped: Bool) -> String? {
        guard isEmpty else { return nil }
        if !hasLoaded { return "Loading history…" }
        if lineScoped { return "No commits touched these lines" }
        if fileScoped { return "No commits touched this file" }
        return "No commits"
    }
}

/// The editor strip is shown from the snapshot's conflict set, never from a scan of `<<<<<<<`.
enum IDEGitConflictBannerPolicy {
    static func shows(status: IDEGitFileStatus?) -> Bool {
        status == .conflicted
    }

    /// The editor banner's check. `conflicted` is membership in the snapshot's conflict set.
    static func shows(conflicted: Bool) -> Bool {
        conflicted
    }
}

/// Confirm copy for discarding working-tree changes. The log's Revert Commit is a different command.
enum IDEGitDiscardPrompt {
    struct Confirmation: Equatable, Sendable {
        var title: String
        var detail: String
        var confirm: String
    }

    static func changes(revertable: [String], skipped: [String], unsavedEditors: Int) -> Confirmation {
        let names = nameList(revertable)
        var detail = "This discards every change to \(revertable.count == 1 ? names : "these files") since the last commit, staged or not. It cannot be undone.\n\n\(revertable.count == 1 ? "" : names)"
        if unsavedEditors > 0 {
            let verb = unsavedEditors == 1 ? "has" : "have"
            detail += "\n\n\(unsavedEditors) of them \(verb) unsaved edits in an open editor; those are discarded too."
        }
        if !skipped.isEmpty {
            detail += "\n\nNot discarded (not in the last commit): \(nameList(skipped, limit: 5))"
        }
        let title = revertable.count == 1
            ? "Discard changes to \(revertable[0])?"
            : "Discard changes to \(revertable.count) files?"
        return Confirmation(
            title: title,
            detail: detail.trimmingCharacters(in: .whitespacesAndNewlines),
            confirm: "Discard"
        )
    }

    static func activeFile(name: String) -> Confirmation {
        Confirmation(
            title: "Discard changes to \(name)?",
            detail: "This discards every change to \(name) since the last commit, including unsaved edits. It cannot be undone.",
            confirm: "Discard"
        )
    }

    static func nothingToDiscard(skipped: Bool) -> (title: String, detail: String) {
        (
            "Nothing to Discard",
            skipped
                ? "The selected files are not in the last commit, so there is no earlier version to go back to."
                : "The selected files have no changes."
        )
    }

    static func nameList(_ names: [String], limit: Int = 10) -> String {
        var lines = names.prefix(limit).map { "• \($0)" }
        if names.count > limit { lines.append("and \(names.count - limit) more") }
        return lines.joined(separator: "\n")
    }
}
