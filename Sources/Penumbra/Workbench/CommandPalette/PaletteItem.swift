import Foundation

/// A small glyph shown at the start of a palette row. The tint is a semantic name (not an
/// `NSColor`) so ``PaletteItem`` stays `Sendable` and free of AppKit.
public struct PaletteIcon: Sendable, Hashable {
    public enum Tint: Sendable, Hashable {
        case accent, blue, orange, green, purple, red, secondary
    }

    /// SF Symbol name.
    public let systemName: String
    public let tint: Tint

    public init(systemName: String, tint: Tint = .secondary) {
        self.systemName = systemName
        self.tint = tint
    }
}

/// The kind of source root a file lives in, as IntelliJ marks it: a trailing folder badge and,
/// for test code, a tinted row.
public enum PaletteSourceRoot: Sendable, Hashable {
    case sources
    case tests
    case resources
    case testResources
    case generated

    public var isTest: Bool { self == .tests || self == .testResources }
}

/// A file's version-control state, which colors its name the way the project explorer does.
public enum PaletteFileStatus: Sendable, Hashable {
    case modified
    case added
    case untracked
    case conflicted
    case ignored
}

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
    /// Glyph shown before the title.
    public let icon: PaletteIcon?
    /// Dimmed text after the title (a file's folder inside its module, a class's package).
    /// Takes the place of ``subtitle`` in the row when set.
    public let location: String?
    /// Right-aligned secondary column (a file's module).
    public let trailing: String?
    /// Full description of the row shown in the palette footer (a file's path).
    public let footer: String?
    /// Secondary way to open the row (⇧↩ — "Open In Right Split"). `nil` when unsupported.
    public let alternateAction: (@MainActor @Sendable () -> Void)?
    /// Source root the row's file belongs to: a trailing badge, and a tinted row for test code.
    public let sourceRoot: PaletteSourceRoot?
    /// The file the row stands for, when it is one (Recent Files uses it to skip the active editor).
    public let fileURL: URL?
    /// Colors the title by version-control state.
    public let fileStatus: PaletteFileStatus?
    /// Removes the row's entry from its source (⌫ in Recent Files). `nil` when unsupported.
    public let removeAction: (@MainActor @Sendable () -> Void)?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        sectionTitle: String,
        matchedIndices: [Int] = [],
        score: Int = 0,
        action: @escaping @MainActor @Sendable () -> Void,
        icon: PaletteIcon? = nil,
        location: String? = nil,
        trailing: String? = nil,
        footer: String? = nil,
        alternateAction: (@MainActor @Sendable () -> Void)? = nil,
        sourceRoot: PaletteSourceRoot? = nil,
        fileURL: URL? = nil,
        fileStatus: PaletteFileStatus? = nil,
        removeAction: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.sectionTitle = sectionTitle
        self.matchedIndices = matchedIndices
        self.score = score
        self.action = action
        self.icon = icon
        self.location = location
        self.trailing = trailing
        self.footer = footer
        self.alternateAction = alternateAction
        self.sourceRoot = sourceRoot
        self.fileURL = fileURL
        self.fileStatus = fileStatus
        self.removeAction = removeAction
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
