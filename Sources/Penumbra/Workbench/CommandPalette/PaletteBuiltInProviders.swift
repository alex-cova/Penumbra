import Foundation
import EditorIntelligence

/// A file candidate for the files / recent-files palette sections.
public struct PaletteFileEntry: Sendable, Hashable {
    public let url: URL
    /// Optional display name override (defaults to the last path component).
    public let displayName: String?
    /// Whether the file was edited recently (the `⌘E` "edited only" filter): unsaved changes, or
    /// whatever the host counts as recently edited.
    public let isEdited: Bool
    /// Version-control state, shown as the row's title color.
    public let status: PaletteFileStatus?

    public init(url: URL, displayName: String? = nil, isEdited: Bool = false, status: PaletteFileStatus? = nil) {
        self.url = url
        self.displayName = displayName
        self.isEdited = isEdited
        self.status = status
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

/// Fuzzy file lookup. Two backends:
/// - a prebuilt ``PaletteFileIndex`` (fast path: no per-query enumeration, IntelliJ-style
///   name matching, icons / module / footer columns, narrowing between keystrokes), or
/// - a caller-supplied list of URLs, snapshotted on the main actor per query (legacy path).
public final class FilesPaletteProvider: SearchEverywhereProvider {
    public let sectionTitle = "Files"
    public let sectionOrder = 20
    private let files: (@MainActor @Sendable () -> [PaletteFileEntry])?
    private let root: @MainActor @Sendable () -> URL?
    private let onOpen: @MainActor @Sendable (URL) -> Void
    private let indexProvider: (@MainActor @Sendable () -> PaletteFileIndex?)?
    private let boostsProvider: @MainActor @Sendable () -> [URL]
    private let onOpenInSplit: (@MainActor @Sendable (URL) -> Void)?
    private let onOpenAtLine: (@MainActor @Sendable (URL, PaletteLineTarget) -> Void)?
    private let narrowing = NarrowingCache()

    public init(
        files: @escaping @MainActor @Sendable () -> [PaletteFileEntry],
        root: @escaping @MainActor @Sendable () -> URL? = { nil },
        onOpen: @escaping @MainActor @Sendable (URL) -> Void
    ) {
        self.files = files
        self.root = root
        self.onOpen = onOpen
        self.indexProvider = nil
        self.boostsProvider = { [] }
        self.onOpenInSplit = nil
        self.onOpenAtLine = nil
    }

    /// Index-backed provider. `index` and `boosts` are read on the main actor per query, so the
    /// same provider instance keeps serving as the host swaps in a fresh index. With
    /// `onOpenAtLine`, a `Name:line[:column]` query (IntelliJ's Go to File suffix) opens the
    /// chosen file at that position.
    public init(
        index: @escaping @MainActor @Sendable () -> PaletteFileIndex?,
        boosts: @escaping @MainActor @Sendable () -> [URL] = { [] },
        onOpen: @escaping @MainActor @Sendable (URL) -> Void,
        onOpenInSplit: (@MainActor @Sendable (URL) -> Void)? = nil,
        onOpenAtLine: (@MainActor @Sendable (URL, PaletteLineTarget) -> Void)? = nil
    ) {
        self.files = nil
        self.root = { nil }
        self.onOpen = onOpen
        self.indexProvider = index
        self.boostsProvider = boosts
        self.onOpenInSplit = onOpenInSplit
        self.onOpenAtLine = onOpenAtLine
    }

    public func items(matching query: String, limit: Int) async -> [PaletteItem] {
        if let indexProvider {
            return await indexedItems(matching: query, limit: limit, indexProvider: indexProvider)
        }
        guard let files else { return [] }
        let root = self.root
        let (entries, rootURL) = await MainActor.run { (files(), root()) }
        let ranked = QuickOpenFileRanker.rank(query: query, files: entries.map(\.url), root: rootURL, limit: limit)
        let names = Dictionary(entries.compactMap { entry in entry.displayName.map { (entry.url, $0) } },
                               uniquingKeysWith: { first, _ in first })
        return ranked.enumerated().map { rank, url in
            let onOpen = self.onOpen
            return PaletteItem(
                id: "file:\(url.path)",
                title: names[url] ?? url.lastPathComponent,
                subtitle: Self.relativeDirectory(of: url, root: rootURL),
                sectionTitle: sectionTitle,
                score: limit - rank,
                action: { onOpen(url) }
            )
        }
    }

    private func indexedItems(
        matching query: String,
        limit: Int,
        indexProvider: @MainActor @Sendable () -> PaletteFileIndex?
    ) async -> [PaletteItem] {
        var lineTarget: PaletteLineTarget?
        var query = query
        if onOpenAtLine != nil, let split = PaletteLineTarget.split(query) {
            query = split.query
            lineTarget = split.target
        }
        let boostsProvider = self.boostsProvider
        let (indexOrNil, boosts) = await MainActor.run { (indexProvider(), boostsProvider()) }
        guard let index = indexOrNil else { return [] }
        let candidates = narrowing.candidates(for: index, query: query)
        let result = index.search(query, limit: limit, boosts: boosts, among: candidates)
        narrowing.store(index: index, query: query, candidates: result.candidates)
        guard !Task.isCancelled else { return [] }

        let onOpen = self.onOpen
        let onOpenInSplit = self.onOpenInSplit
        let onOpenAtLine = self.onOpenAtLine
        var items: [PaletteItem] = []
        items.reserveCapacity(result.hits.count)
        for hit in result.hits {
            let entry = index.entry(at: hit.index)
            let url = entry.url
            var alternate: (@MainActor @Sendable () -> Void)?
            if let onOpenInSplit {
                alternate = { onOpenInSplit(url) }
            }
            var action: @MainActor @Sendable () -> Void = { onOpen(url) }
            var footer = entry.relativePath
            if let lineTarget, let onOpenAtLine {
                action = { onOpenAtLine(url, lineTarget) }
                footer += ":\(lineTarget.line)" + (lineTarget.column.map { ":\($0)" } ?? "")
            }
            items.append(PaletteItem(
                id: "file:\(url.path)",
                title: url.lastPathComponent,
                sectionTitle: sectionTitle,
                matchedIndices: index.highlightOffsets(forEntryAt: hit.index, query: query),
                score: hit.score,
                action: action,
                icon: entry.icon,
                location: entry.location,
                trailing: entry.module,
                footer: footer,
                alternateAction: alternate,
                sourceRoot: entry.sourceRoot
            ))
        }
        return items
    }

    /// Remembers which entries matched the previous query so a query that merely extends it only
    /// rescans those. Guarded by a lock because provider calls may overlap.
    private final class NarrowingCache: @unchecked Sendable {
        private let lock = NSLock()
        private var indexID: ObjectIdentifier?
        private var query = ""
        private var matched: [Int32]?

        func candidates(for index: PaletteFileIndex, query newQuery: String) -> [Int32]? {
            guard Self.isNarrowable(newQuery) else { return nil }
            lock.lock()
            defer { lock.unlock() }
            guard indexID == ObjectIdentifier(index), let matched, !query.isEmpty,
                  newQuery.lowercased().hasPrefix(query) else { return nil }
            return matched
        }

        func store(index: PaletteFileIndex, query newQuery: String, candidates: [Int32]?) {
            lock.lock()
            defer { lock.unlock() }
            indexID = ObjectIdentifier(index)
            query = newQuery.lowercased()
            matched = Self.isNarrowable(newQuery) ? candidates : nil
        }

        private static func isNarrowable(_ query: String) -> Bool {
            !query.isEmpty && !query.contains { $0 == " " || $0 == "\t" || $0 == "/" }
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

/// A 1-based line (and optional column) typed after a file name in Go to File: `Foo.java:42`.
public struct PaletteLineTarget: Sendable, Equatable {
    public let line: Int
    public let column: Int?

    public init(line: Int, column: Int? = nil) {
        self.line = line
        self.column = column
    }

    /// Splits `Name:line[:column]` into the name query and the target. A trailing `:` with no
    /// digits yet (`Foo:`) strips the colon and leaves no target, so results don't flicker while
    /// the number is typed. Returns `nil` when the query has no such suffix.
    public static func split(_ query: String) -> (query: String, target: PaletteLineTarget?)? {
        let parts = query.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts[0].trimmingCharacters(in: .whitespaces).isEmpty,
              parts.dropFirst().allSatisfy({ $0.allSatisfy(\.isASCIIDigitCharacter) }) else { return nil }
        let name = String(parts[0])
        guard let line = Int(parts[1]), line > 0 else { return (name, nil) }
        let column = parts.count > 2 ? Int(parts[2]).flatMap { $0 > 0 ? $0 : nil } : nil
        return (name, PaletteLineTarget(line: line, column: column))
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}

/// Most-recently-used documents.
public final class RecentFilesPaletteProvider: SearchEverywhereProvider {
    public let sectionTitle = "Recent Files"
    public let sectionOrder = 5
    private let entries: @MainActor @Sendable () -> [PaletteFileEntry]
    private let root: @MainActor @Sendable () -> URL?
    private let indexProvider: (@MainActor @Sendable () -> PaletteFileIndex?)?
    private let editedOnly: @MainActor @Sendable () -> Bool
    private let onOpen: @MainActor @Sendable (URL) -> Void
    private let onOpenInSplit: (@MainActor @Sendable (URL) -> Void)?
    private let onRemove: (@MainActor @Sendable (URL) -> Void)?

    public init(
        entries: @escaping @MainActor @Sendable () -> [PaletteFileEntry],
        root: @escaping @MainActor @Sendable () -> URL? = { nil },
        index: (@MainActor @Sendable () -> PaletteFileIndex?)? = nil,
        editedOnly: @escaping @MainActor @Sendable () -> Bool = { false },
        onOpen: @escaping @MainActor @Sendable (URL) -> Void,
        onOpenInSplit: (@MainActor @Sendable (URL) -> Void)? = nil,
        onRemove: (@MainActor @Sendable (URL) -> Void)? = nil
    ) {
        self.entries = entries
        self.root = root
        self.indexProvider = index
        self.editedOnly = editedOnly
        self.onOpen = onOpen
        self.onOpenInSplit = onOpenInSplit
        self.onRemove = onRemove
    }

    public func items(matching query: String, limit: Int) async -> [PaletteItem] {
        let entriesProvider = self.entries
        let rootProvider = self.root
        let indexLookup = self.indexProvider
        let editedOnlyProvider = self.editedOnly
        let all = await MainActor.run {
            let entries = entriesProvider()
            return editedOnlyProvider() ? entries.filter(\.isEdited) : entries
        }
        let ranked = FuzzyMatcher.rankedWithMatches(
            query: query,
            items: all,
            key: { $0.displayName ?? $0.url.lastPathComponent },
            limit: limit
        )
        let (rootURL, index) = await MainActor.run { (rootProvider(), indexLookup?()) }
        return ranked.enumerated().map { rank, entry in
            let onOpen = self.onOpen
            let onOpenInSplit = self.onOpenInSplit
            let url = entry.item.url
            let indexed = index?.entry(for: url)
            var alternate: (@MainActor @Sendable () -> Void)?
            if let onOpenInSplit {
                alternate = { onOpenInSplit(url) }
            }
            var remove: (@MainActor @Sendable () -> Void)?
            if let onRemove = self.onRemove {
                remove = { onRemove(url) }
            }
            return PaletteItem(
                id: "recent:\(url.path)",
                title: entry.item.displayName ?? url.lastPathComponent,
                subtitle: FilesPaletteProvider.relativeDirectory(of: url, root: rootURL),
                sectionTitle: sectionTitle,
                matchedIndices: entry.match.matchedIndices,
                score: limit - rank,
                action: { onOpen(url) },
                icon: indexed?.icon,
                location: indexed?.location,
                trailing: indexed?.module,
                footer: Self.displayPath(url),
                alternateAction: alternate,
                sourceRoot: indexed?.sourceRoot,
                fileURL: url,
                fileStatus: entry.item.status,
                removeAction: remove
            )
        }
    }

    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
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
    private let files: (@MainActor @Sendable () -> [URL]?)?
    private let onSelect: @MainActor @Sendable (ProjectSearchResult) -> Void

    /// - Parameter files: An already-enumerated candidate list (e.g. ``PaletteFileIndex/urls``).
    ///   When it returns a list the disk tree is not walked again for every query.
    public init(
        engine: ProjectSearchEngine,
        root: URL,
        files: (@MainActor @Sendable () -> [URL]?)? = nil,
        onSelect: @escaping @MainActor @Sendable (ProjectSearchResult) -> Void
    ) {
        self.engine = engine
        self.root = root
        self.files = files
        self.onSelect = onSelect
    }

    public func items(matching query: String, limit: Int) async -> [PaletteItem] {
        guard !query.isEmpty else { return [] }
        let searchQuery = WorkspaceSearchQuery(text: query)
        let candidates = await MainActor.run { files?() }
        let results: [ProjectSearchResult]
        if let candidates {
            results = await engine.search(searchQuery, files: candidates, maxResults: limit)
        } else {
            results = await engine.search(searchQuery, in: root, maxResults: limit)
        }
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
    public let sectionTitle: String
    public let sectionOrder: Int
    private let index: SymbolIndex
    private let kinds: Set<SymbolKind>?
    private let onSelect: @MainActor @Sendable (EditorIntelligence.Symbol) -> Void

    /// - Parameter kinds: Restricts results to these kinds (the Classes tab passes `[.type]`).
    public init(
        index: SymbolIndex,
        kinds: Set<SymbolKind>? = nil,
        sectionTitle: String = "Symbols",
        sectionOrder: Int = 30,
        onSelect: @escaping @MainActor @Sendable (EditorIntelligence.Symbol) -> Void
    ) {
        self.index = index
        self.kinds = kinds
        self.sectionTitle = sectionTitle
        self.sectionOrder = sectionOrder
        self.onSelect = onSelect
    }

    public func items(matching query: String, limit: Int) async -> [PaletteItem] {
        guard !query.isEmpty else { return [] }
        var all = await index.allSymbols()
        if let kinds { all = all.filter { kinds.contains($0.kind) } }
        let ranked = FuzzyMatcher.rankedWithMatches(query: query, items: all, key: { $0.name }, limit: limit)
        return ranked.enumerated().map { rank, entry in
            let onSelect = self.onSelect
            let symbol = entry.item
            return PaletteItem(
                id: "symbol:\(symbol.id)",
                title: symbol.name,
                subtitle: symbol.signature ?? String(describing: symbol.kind),
                sectionTitle: sectionTitle,
                matchedIndices: entry.match.matchedIndices,
                score: limit - rank,
                action: { onSelect(symbol) }
            )
        }
    }
}

/// A remembered caret position for Recent Locations (⌘⇧E).
public struct PaletteLocationEntry: Sendable, Hashable {
    public let url: URL
    /// 1-based line.
    public let line: Int
    /// 1-based column, when known.
    public let column: Int?
    /// The line's text, shown trimmed after the title. `nil` when the host can't read it cheaply.
    public let lineText: String?

    public init(url: URL, line: Int, column: Int? = nil, lineText: String? = nil) {
        self.url = url
        self.line = line
        self.column = column
        self.lineText = lineText
    }
}

/// Recently visited caret positions (IntelliJ's Recent Locations): newest first, one row per
/// file and line.
public final class RecentLocationsPaletteProvider: SearchEverywhereProvider {
    public let sectionTitle = "Recent Locations"
    public let sectionOrder = 5
    private let entries: @MainActor @Sendable () -> [PaletteLocationEntry]
    private let root: @MainActor @Sendable () -> URL?
    private let onOpen: @MainActor @Sendable (URL, PaletteLineTarget) -> Void

    public init(
        entries: @escaping @MainActor @Sendable () -> [PaletteLocationEntry],
        root: @escaping @MainActor @Sendable () -> URL? = { nil },
        onOpen: @escaping @MainActor @Sendable (URL, PaletteLineTarget) -> Void
    ) {
        self.entries = entries
        self.root = root
        self.onOpen = onOpen
    }

    /// Drops repeats of a file and line, keeping the first (newest) one.
    static func deduplicated(_ entries: [PaletteLocationEntry]) -> [PaletteLocationEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert("\($0.url.path):\($0.line)").inserted }
    }

    static func title(for entry: PaletteLocationEntry) -> String {
        "\(entry.url.lastPathComponent):\(entry.line)"
    }

    public func items(matching query: String, limit: Int) async -> [PaletteItem] {
        let entriesProvider = self.entries
        let rootProvider = self.root
        let (all, rootURL) = await MainActor.run { (Self.deduplicated(entriesProvider()), rootProvider()) }
        let ranked = FuzzyMatcher.rankedWithMatches(
            query: query,
            items: all,
            key: { Self.title(for: $0) },
            limit: limit
        )
        let onOpen = self.onOpen
        return ranked.enumerated().map { rank, match in
            let entry = match.item
            let url = entry.url
            let target = PaletteLineTarget(line: entry.line, column: entry.column)
            let text = entry.lineText?.trimmingCharacters(in: .whitespacesAndNewlines)
            return PaletteItem(
                id: "location:\(url.path):\(entry.line)",
                title: Self.title(for: entry),
                subtitle: FilesPaletteProvider.relativeDirectory(of: url, root: rootURL),
                sectionTitle: sectionTitle,
                matchedIndices: match.match.matchedIndices,
                score: limit - rank,
                action: { onOpen(url, target) },
                location: text?.isEmpty == false ? text : nil,
                footer: RecentFilesPaletteProvider.displayPath(url),
                fileURL: url
            )
        }
    }
}
