import Foundation

/// A single row in a "Search Everywhere" / "Find Action" style palette.
///
/// Sources produce `PaletteItem`s (a file, a symbol, a command, a surround template, …); the
/// palette groups them by ``sectionTitle`` and runs ``action`` when the row is chosen.
public struct PaletteItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    /// Secondary text shown dimmed after the title — a file's folder, a symbol's kind, a
    /// command's shortcut.
    public let subtitle: String?
    /// Group heading this item is filed under.
    public let sectionTitle: String
    /// Character offsets in ``title`` that matched the query, for highlight rendering. Comes
    /// straight from ``FuzzyMatcher/Match``.
    public let matchedIndices: [Int]
    /// Higher sorts first within a section.
    public let score: Int
    public let action: @MainActor @Sendable () -> Void

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        sectionTitle: String,
        matchedIndices: [Int] = [],
        score: Int = 0,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.sectionTitle = sectionTitle
        self.matchedIndices = matchedIndices
        self.score = score
        self.action = action
    }
}

/// A group of ``PaletteItem``s under one heading, as rendered by the palette.
public struct PaletteSection: Identifiable, Sendable {
    public var id: String { title }
    public let title: String
    public let items: [PaletteItem]

    public init(title: String, items: [PaletteItem]) {
        self.title = title
        self.items = items
    }
}
