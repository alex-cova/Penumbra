import AppKit

/// A bookmark drawn in the gutter's decoration column (IntelliJ's bookmarks), kept apart from
/// ``GutterDecoration`` so it shows beside whatever else the host puts in the gutter (breakpoints,
/// run buttons) and follows edits on its own. A mnemonic (a digit or a letter) is drawn on it.
public struct GutterBookmark: Equatable, Hashable, Sendable, Identifiable {
    /// The host's identity for the bookmark.
    public let id: String
    /// 1-based document line. Bookmarks follow line insertions and removals until the host
    /// replaces them (see ``TextView/gutterBookmarksDidMove``).
    public private(set) var line: Int
    /// `0`–`9` or `A`–`Z`, drawn on the icon.
    public let mnemonic: Character?
    /// The bookmark's description, read aloud by accessibility.
    public let note: String?

    public init(id: String, line: Int, mnemonic: Character? = nil, note: String? = nil) {
        self.id = id
        self.line = max(1, line)
        self.mnemonic = mnemonic
        self.note = note
    }

    func moved(toLine line: Int) -> GutterBookmark {
        var copy = self
        copy.line = max(1, line)
        return copy
    }

    static let decorationIDPrefix = "penumbra.bookmark:"

    /// How the bookmark is drawn: a bookmark icon, with the mnemonic on a small badge.
    var decoration: GutterDecoration {
        var label = "Bookmark"
        if let mnemonic { label += " \(mnemonic)" }
        if let note, !note.isEmpty { label += ", \(note)" }
        return GutterDecoration(
            line: line,
            symbolName: "bookmark.fill",
            accessibilityLabel: label,
            tintColor: NSColor.systemIndigo.cgColor,
            badgeSymbolName: mnemonic.map { Self.badgeSymbol(for: $0) },
            placement: .decorationColumn,
            id: Self.decorationIDPrefix + id
        )
    }

    /// SF Symbols names a letter or digit: `a.circle.fill`, `7.circle.fill`.
    static func badgeSymbol(for mnemonic: Character) -> String {
        "\(String(mnemonic).lowercased()).circle.fill"
    }
}
