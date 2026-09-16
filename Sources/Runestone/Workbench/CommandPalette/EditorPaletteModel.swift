import Foundation

/// What a command palette is currently browsing.
public enum EditorPaletteMode: Equatable {
    case commands
    case quickOpen
    case symbols
    case textActions
    /// Every source at once — files, symbols, actions, recent files (double ⇧).
    case searchEverywhere
    /// Most-recently-used documents (⌘E).
    case recentFiles
    /// A list of jump targets, e.g. the results of "Go to Definition" when there is more than
    /// one, or the surround-with templates.
    case locations
    /// Go to line (⌘G / ⌘L) — the field is seeded with `:` so a bare number still resolves via
    /// ``PaletteQueryScope``.
    case goToLine
    /// Disk-wide project search (⌘⇧F).
    case findInFiles
}

/// Presentation/navigation state for a command palette — which mode it's in, the current query,
/// and the selected row index. Pair with ``CommandRegistry`` (for `.commands`),
/// ``QuickOpenFileRanker`` (for `.quickOpen`), and ``PaletteQueryScope`` (for prefix-based mode
/// switching, e.g. typing `">"` to jump into `.commands` regardless of the current mode).
@MainActor
public final class EditorPaletteModel {
    public var isPresented = false
    public var mode: EditorPaletteMode = .textActions
    public var query = ""
    public var selectedIndex = 0

    public init() {}

    public func showCommands() {
        mode = .commands
        resetForShow()
    }

    public func showQuickOpen() {
        mode = .quickOpen
        resetForShow()
    }

    public func showSymbols() {
        mode = .symbols
        resetForShow()
    }

    public func showTextActions() {
        mode = .textActions
        resetForShow()
    }

    public func showSearchEverywhere() {
        mode = .searchEverywhere
        resetForShow()
    }

    public func showRecentFiles() {
        mode = .recentFiles
        resetForShow()
    }

    public func showLocations() {
        mode = .locations
        resetForShow()
    }

    public func showGoToLine() {
        mode = .goToLine
        resetForShow()
    }

    public func showFindInFiles() {
        mode = .findInFiles
        resetForShow()
    }

    public func hide() {
        isPresented = false
    }

    /// Steps the selection by `delta` (e.g. `+1`/`-1` for arrow keys), clamped to `0..<count`.
    /// No-op when `count <= 0`.
    public func moveSelection(by delta: Int, count: Int) {
        guard count > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }

    /// Clamps the current selection into `0..<count` — needed after an async result refresh (e.g.
    /// a debounced quick-open file search) changes the row count out from under the selection.
    public func clampSelection(count: Int) {
        selectedIndex = min(selectedIndex, max(count - 1, 0))
    }

    private func resetForShow() {
        query = ""
        selectedIndex = 0
        isPresented = true
    }
}
