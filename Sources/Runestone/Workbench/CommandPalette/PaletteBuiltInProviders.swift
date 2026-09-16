import Foundation
import EditorIntelligence

/// A file candidate for the files / recent-files palette sections.
public struct PaletteFileEntry: Sendable, Hashable {
    public let url: URL
    /// Optional display name override (defaults to the last path component).
    public let displayName: String?

    public init(url: URL, displayName: String? = nil) {
        self.url = url
        self.displayName = displayName
    }
}

/// Commands registered with a ``CommandRegistry`` (also the home of "Find Action").
public final class CommandsPaletteProvider: SearchEverywhereProvider {
    public let sectionTitle: String
    public let sectionOrder = 10
    private let registry: CommandRegistry

    public init(registry: CommandRegistry, sectionTitle: String = "Actions") {
        self.registry = registry
        self.sectionTitle = sectionTitle
    }

    public func items(matching query: String, limit: Int) async -> [PaletteItem] {
        let registry = self.registry
        let matches = await MainActor.run { registry.filteredWithMatches(query: query, limit: limit) }
        return matches.enumerated().map { index, entry in
            PaletteItem(
                id: "command:\(entry.command.id)",
                title: entry.command.title,
                subtitle: entry.command.shortcutDisplay,
                sectionTitle: sectionTitle,
                matchedIndices: entry.match.matchedIndices,
                score: limit - index,
                action: entry.command.action
            )
        }
    }
}

/// Fuzzy file lookup over a caller-supplied list of URLs (Runestone has no on-disk index).
/// The list and root are snapshotted on the main actor per query.
public final class FilesPaletteProvider: SearchEverywhereProvider {
    public let sectionTitle = "Files"
    public let sectionOrder = 20
    private let files: @MainActor @Sendable () -> [PaletteFileEntry]
    private let root: @MainActor @Sendable () -> URL?
    private let onOpen: @MainActor @Sendable (URL) -> Void

    public init(
        files: @escaping @MainActor @Sendable () -> [PaletteFileEntry],
        root: @escaping @MainActor @Sendable () -> URL? = { nil },
        onOpen: @escaping @MainActor @Sendable (URL) -> Void
    ) {
        self.files = files
        self.root = root
        self.onOpen = onOpen
    }

    public func items(matching query: String, limit: Int) async -> [PaletteItem] {
        let files = self.files
        let root = self.root
        let (entries, rootURL) = await MainActor.run { (files(), root()) }
        let ranked = QuickOpenFileRanker.rank(query: query, files: entries.map(\.url), root: rootURL, limit: limit)
        return ranked.map { url in
            let onOpen = self.onOpen
            return PaletteItem(
                id: "file:\(url.path)",
                title: entries.first { $0.url == url }?.displayName ?? url.lastPathComponent,
                subtitle: Self.relativeDirectory(of: url, root: rootURL),
                sectionTitle: sectionTitle,
                action: { onOpen(url) }
            )
        }
    }

    static func relativeDirectory(of url: URL, root: URL?) -> String? {
        let directory = url.deletingLastPathComponent()
        guard let root else { return directory.path }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if directory.path.hasPrefix(rootPath) {
            let relative = String(directory.path.dropFirst(rootPath.count))
            return relative.isEmpty ? nil : relative
        }
        return directory.path
    }
}

/// Most-recently-used documents.
public final class RecentFilesPaletteProvider: SearchEverywhereProvider {
    public let sectionTitle = "Recent Files"
    public let sectionOrder = 5
    private let entries: @MainActor @Sendable () -> [PaletteFileEntry]
    private let onOpen: @MainActor @Sendable (URL) -> Void

    public init(
        entries: @escaping @MainActor @Sendable () -> [PaletteFileEntry],
        onOpen: @escaping @MainActor @Sendable (URL) -> Void
    ) {
        self.entries = entries
        self.onOpen = onOpen
    }

    public func items(matching query: String, limit: Int) async -> [PaletteItem] {
        let entriesProvider = self.entries
        let all = await MainActor.run { entriesProvider() }
        let ranked = FuzzyMatcher.rankedWithMatches(
            query: query,
            items: all,
            key: { $0.displayName ?? $0.url.lastPathComponent },
            limit: limit
        )
        return ranked.enumerated().map { index, entry in
            let onOpen = self.onOpen
            let url = entry.item.url
            return PaletteItem(
                id: "recent:\(url.path)",
                title: entry.item.displayName ?? url.lastPathComponent,
                subtitle: url.deletingLastPathComponent().lastPathComponent,
                sectionTitle: sectionTitle,
                matchedIndices: entry.match.matchedIndices,
                score: limit - index,
                action: { onOpen(url) }
            )
        }
    }
}

/// Go to line (`:` sigil, ⌘G / ⌘L). Parses the query as a 1-based line number and offers a
/// single confirmable row; empty for non-numeric input.
public final class GoToLinePaletteProvider: SearchEverywhereProvider {
    public let sectionTitle = "Go to Line"
    public let sectionOrder = 5
    private let lineCount: @MainActor @Sendable () -> Int
    private let onGoToLine: @MainActor @Sendable (Int) -> Void

    public init(
        lineCount: @escaping @MainActor @Sendable () -> Int,
        onGoToLine: @escaping @MainActor @Sendable (Int) -> Void
    ) {
        self.lineCount = lineCount
        self.onGoToLine = onGoToLine
    }

    /// 1-based line number, or `nil` when the input is empty, non-numeric, or less than 1.
    public static func parse(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Int(trimmed), number >= 1 else { return nil }
        return number
    }

    public func items(matching query: String, limit: Int) async -> [PaletteItem] {
        guard let requested = Self.parse(query) else { return [] }
        let count = await MainActor.run { lineCount() }
        let target = min(requested, max(count, 1))
        let subtitle = target == requested ? nil : "Clamped to last line (\(count))"
        let onGoToLine = self.onGoToLine
        return [
            PaletteItem(
                id: "goToLine",
                title: "Go to Line \(target)",
                subtitle: subtitle,
                sectionTitle: sectionTitle,
                score: 1,
                action: { onGoToLine(target) }
            )
        ]
    }
}

/// In-buffer text search (`#` sigil) — Sublime's "search this file" mode. Backed by
/// `TextView.search(for:)` rather than any disk I/O.
public final class BufferTextPaletteProvider: SearchEverywhereProvider {
    public let sectionTitle = "Text"
    public let sectionOrder = 15
    private let text: @MainActor @Sendable () -> String
    private let search: @MainActor @Sendable (SearchQuery) -> [SearchResult]
    private let onSelect: @MainActor @Sendable (NSRange) -> Void

    public init(
        text: @escaping @MainActor @Sendable () -> String,
        search: @escaping @MainActor @Sendable (SearchQuery) -> [SearchResult],
        onSelect: @escaping @MainActor @Sendable (NSRange) -> Void
    ) {
        self.text = text
        self.search = search
        self.onSelect = onSelect
    }

    public func items(matching query: String, limit: Int) async -> [PaletteItem] {
        guard !query.isEmpty else { return [] }
        let searchQuery = SearchQuery(text: query, matchMethod: .contains, isCaseSensitive: false)
        let (results, fullText) = await MainActor.run { (search(searchQuery), text()) }
        guard !results.isEmpty else { return [] }
        let nsText = fullText as NSString
        let onSelect = self.onSelect
        return results.prefix(limit).enumerated().map { index, result in
            let clampedLocation = min(result.range.location, nsText.length)
            let lineRange = nsText.lineRange(for: NSRange(location: clampedLocation, length: 0))
            let preview = nsText.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let range = result.range
            return PaletteItem(
                id: "text:\(range.location):\(range.length)",
                title: preview.isEmpty ? " " : preview,
                subtitle: "Line \(result.startLocation.lineNumber + 1)",
                sectionTitle: sectionTitle,
                score: limit - index,
                action: { onSelect(range) }
            )
        }
    }
}

/// Disk-wide project search (⌘⇧F / `.findInFiles`), backed by `EditorIntelligence`'s
/// `ProjectSearchEngine`. Requires a workspace root; produces no rows without one.
public final class ProjectSearchPaletteProvider: SearchEverywhereProvider {
    public let sectionTitle = "Files"
    public let sectionOrder = 20
    private let engine: ProjectSearchEngine
    private let root: URL
    private let onSelect: @MainActor @Sendable (ProjectSearchResult) -> Void

    public init(engine: ProjectSearchEngine, root: URL, onSelect: @escaping @MainActor @Sendable (ProjectSearchResult) -> Void) {
        self.engine = engine
        self.root = root
        self.onSelect = onSelect
    }

    public func items(matching query: String, limit: Int) async -> [PaletteItem] {
        guard !query.isEmpty else { return [] }
        let searchQuery = WorkspaceSearchQuery(text: query)
        let results = await engine.search(searchQuery, in: root, maxResults: limit)
        let onSelect = self.onSelect
        return results.map { result in
            PaletteItem(
                id: "projectSearch:\(result.id)",
                title: result.preview,
                subtitle: "\(result.url.lastPathComponent):\(result.line + 1)",
                sectionTitle: sectionTitle,
                action: { onSelect(result) }
            )
        }
    }
}

/// Workspace symbols. `SymbolIndex` only does prefix/exact lookups, so this layers
/// ``FuzzyMatcher`` over `allSymbols()`.
public final class SymbolsPaletteProvider: SearchEverywhereProvider {
    public let sectionTitle = "Symbols"
    public let sectionOrder = 30
    private let index: SymbolIndex
    private let onSelect: @MainActor @Sendable (EditorIntelligence.Symbol) -> Void

    public init(index: SymbolIndex, onSelect: @escaping @MainActor @Sendable (EditorIntelligence.Symbol) -> Void) {
        self.index = index
        self.onSelect = onSelect
    }

    public func items(matching query: String, limit: Int) async -> [PaletteItem] {
        guard !query.isEmpty else { return [] }
        let all = await index.allSymbols()
        let ranked = FuzzyMatcher.rankedWithMatches(query: query, items: all, key: { $0.name }, limit: limit)
        return ranked.map { entry in
            let onSelect = self.onSelect
            let symbol = entry.item
            return PaletteItem(
                id: "symbol:\(symbol.id)",
                title: symbol.name,
                subtitle: symbol.signature ?? String(describing: symbol.kind),
                sectionTitle: sectionTitle,
                matchedIndices: entry.match.matchedIndices,
                action: { onSelect(symbol) }
            )
        }
    }
}
