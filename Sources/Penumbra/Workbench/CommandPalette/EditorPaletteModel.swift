import Foundation

/// What a command palette is currently browsing.
public enum EditorPaletteMode: Hashable {
    case commands
    case quickOpen
    case symbols
    /// Types only (the Classes tab).
    case classes
    case textActions
    /// Every source at once — files, symbols, actions, recent files (double ⇧).
    case searchEverywhere
    /// Most-recently-used documents (⌘E).
    case recentFiles
    /// Recently visited caret positions (⌘⇧E).
    case recentLocations
    /// A list of jump targets, e.g. the results of "Go to Definition" when there is more than
    /// one, or the surround-with templates.
    case locations
    /// Go to line (⌘G / ⌘L) — the field is seeded with `:` so a bare number still resolves via
    /// ``PaletteQueryScope``.
    case goToLine
    /// Disk-wide project search (⌘⇧F).
    case findInFiles
}

/// The tabs of the tabbed palette (IntelliJ's All / Classes / Files / Symbols / Actions / Text).
/// Each maps to one ``EditorPaletteMode``; the tab-less modes (go to line, recent files, fixed
/// lists) have no tab, and the palette hides its tab strip for them.
public enum PaletteTab: CaseIterable, Sendable {
    case all, classes, files, symbols, actions, text

    public var title: String {
        switch self {
        case .all: "All"
        case .classes: "Classes"
        case .files: "Files"
        case .symbols: "Symbols"
        case .actions: "Actions"
        case .text: "Text"
        }
    }

    public var mode: EditorPaletteMode {
        switch self {
        case .all: .searchEverywhere
        case .classes: .classes
        case .files: .quickOpen
        case .symbols: .symbols
        case .actions: .commands
        case .text: .findInFiles
        }
    }

    public init?(mode: EditorPaletteMode) {
        guard let tab = Self.allCases.first(where: { $0.mode == mode }) else { return nil }
        self = tab
    }

    var placeholder: String {
        switch self {
        case .all: "Search Everywhere"
        case .classes: "Go to Class"
        case .files: "Go to File"
        case .symbols: "Go to Symbol"
        case .actions: "Find Action"
        case .text: "Find in Files"
        }
    }
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
