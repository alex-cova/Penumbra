import Foundation
import SwiftUI

/// ⌘S and ⌘U while the Changes list is focused. Extra modifiers match nothing, so ⌥⌘S stays Save All.
enum IDEGitListShortcut {
    enum Action: Equatable, Sendable {
        case stage
        case unstage
    }

    static func action(characters: String, modifiers: EventModifiers) -> Action? {
        guard modifiers.contains(.command), modifiers.isDisjoint(with: [.shift, .option, .control]) else { return nil }
        switch characters.lowercased() {
        case "s": return Action.stage
        case "u": return Action.unstage
        default: return nil
        }
    }
}

/// Which save command ⌘S runs. Staging replaces that command while the Changes list is focused,
/// and leaves the other save command writing files.
enum IDEGitSaveIntercept {
    enum SaveCommand: Equatable, Sendable {
        case save
        case saveAll
    }

    /// Default, Sublime, and VS Code bind ⌘S to Save. IntelliJ binds ⌘S to Save All.
    static func commandBoundToStageShortcut(in preset: KeymapPreset) -> SaveCommand {
        preset == .intelliJ ? .saveAll : .save
    }

    static func shouldStage(changesListFocused: Bool, command: SaveCommand, preset: KeymapPreset) -> Bool {
        changesListFocused && command == commandBoundToStageShortcut(in: preset)
    }
}

/// Why the palette's Commit Staged command refuses. `requestCommit` keeps its own sentences.
enum IDEGitCommitRefusal {
    static let busy = "Wait for the current Git command to finish."
    static let nothingStaged = "Stage files to commit them"
    static let emptyMessage = "Enter a commit message"

    static func reason(isBusy: Bool, stagedCount: Int, isAmend: Bool, message: String) -> String? {
        if isBusy { return busy }
        if stagedCount == 0, !isAmend { return nothingStaged }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return emptyMessage }
        return nil
    }
}

/// Files a Stage or Unstage command should hand to git. A non-empty selection is used as it is.
/// An empty selection falls back to the active file when that file is on the matching side.
enum IDEGitIndexPaths {
    static func toStage(selected: [String], changes: [IDEGitChange], activeFile: String?) -> [String] {
        matching(selected: selected, changes: changes, activeFile: activeFile) {
            $0.unstaged != nil && $0.unstaged != .conflicted
        }
    }

    static func toUnstage(selected: [String], changes: [IDEGitChange], activeFile: String?) -> [String] {
        matching(selected: selected, changes: changes, activeFile: activeFile) {
            $0.staged != nil && $0.staged != .conflicted
        }
    }

    private static func matching(
        selected: [String],
        changes: [IDEGitChange],
        activeFile: String?,
        keep: (IDEGitChange) -> Bool
    ) -> [String] {
        let byPath = Dictionary(changes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        if !selected.isEmpty {
            return selected.filter { path in byPath[path].map(keep) ?? false }
        }
        guard let activeFile, let change = byPath[activeFile], keep(change) else { return [] }
        return [activeFile]
    }
}

/// The next conflicted path after the open file. Nil when there are no conflicts.
enum IDEGitConflictNavigation {
    enum Step: Equatable, Sendable {
        /// Open the merge tool on this path.
        case open(String)
        /// The open file is already the last conflict.
        case stayed(String)
    }

    static func next(paths: [String], currentPath: String?) -> Step? {
        guard let first = paths.first else { return nil }
        guard let currentPath, let index = paths.firstIndex(of: currentPath) else {
            return .open(first)
        }
        let following = index + 1
        guard paths.indices.contains(following) else { return .stayed(paths[index]) }
        return .open(paths[following])
    }
}
