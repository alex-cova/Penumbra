import EditorIntelligence
import Foundation

/// Per-document incremental parse cache. Applies tree-sitter ``ts_tree_edit`` for the edits the
/// caller passes, or for the single diff between the cached source and the new text, and falls
/// back to a full parse when that fails.
///
/// The grammar is chosen by the caller. Java's no-argument initializer lives on
/// `JavaDocumentParseCache` in JavaIntelligence. Only documents with ``languageIdentifier`` are parsed.
public actor DocumentParseCache {
    private struct Entry {
        var source: String
        var version: Int
        var tree: SyntaxTree
        let parser: SyntaxParser
    }

    private var entries: [URL: Entry] = [:]
    /// Least-recently-used first. Every parsed document pins its full source text plus a native
    /// syntax tree, so without a bound opening files would grow the cache for the process lifetime.
    private var order: [URL] = []
    private var sourceBytes = 0
    /// Past this many documents the least recently parsed one is re-parsed on demand.
    nonisolated(unsafe) static var maxEntries = 64
    /// Past this many cached source bytes the least recently parsed documents go, even under the entry cap.
    nonisolated(unsafe) static var maxSourceBytes = 32 * 1024 * 1024
    private let languageIdentifier: String
    private let language: OpaquePointer

    /// `language` is a `tree_sitter_*()` pointer and must stay valid for the cache's lifetime.
    public init(languageIdentifier: String, language: OpaquePointer) {
        self.languageIdentifier = languageIdentifier
        self.language = language
    }

    /// Returns a syntax tree for `document`, incrementally when possible.
    public func tree(for document: Document, edits: [TextEdit]? = nil) -> SyntaxTree? {
        guard document.languageIdentifier == languageIdentifier, let url = document.url else { return nil }
        guard !document.contentSnapshot.isElided else { return nil }
        // Standardized: `invalidate(_:)` standardizes too, so both spellings of a path hit one entry.
        let key = url.standardizedFileURL
        let text = document.text
        if var entry = entries[key], entry.version <= document.version {
            if entry.source == text {
                entry.version = document.version
                entries[key] = entry
                touch(key)
                return entry.tree
            }
            if document.version > entry.version {
                if let edits, !edits.isEmpty,
                   let updated = applyIncremental(entry: &entry, text: text, version: document.version, edits: edits) {
                    store(key: key, entry: entry)
                    return updated
                }
                if let updated = applyDiff(entry: &entry, text: text, version: document.version) {
                    store(key: key, entry: entry)
                    return updated
                }
            }
        }
        let parser = SyntaxParser(language: language)
        guard let tree = parser.parse(text) else { return nil }
        store(key: key, entry: Entry(source: text, version: document.version, tree: tree, parser: parser))
        return tree
    }

    /// Stores `entry`, evicting least-recently-used entries past the bounds.
    private func store(key: URL, entry: Entry) {
        if let old = entries[key] {
            sourceBytes -= old.source.utf8.count
            order.removeAll { $0 == key }
        }
        entries[key] = entry
        sourceBytes += entry.source.utf8.count
        order.append(key)
        // The entry just stored is exempt: a single document larger than a cap stays cached
        // (re-parsing it on every request would cost more than keeping it) and only pushes
        // out older entries.
        while entries.count > Self.maxEntries || sourceBytes > Self.maxSourceBytes, order.count > 1 {
            guard let oldest = order.first else { break }
            order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                sourceBytes -= removed.source.utf8.count
            }
        }
    }

    /// Marks a cache hit as most recently used.
    private func touch(_ key: URL) {
        guard order.last != key else { return }
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// Rebuilds recency after an out-of-band removal. Order among survivors is not preserved.
    private func rebuildOrder() {
        sourceBytes = entries.values.reduce(0) { $0 + $1.source.utf8.count }
        order = Array(entries.keys)
    }

    var entryCount: Int { entries.count }
    var cachedSourceBytes: Int { sourceBytes }
    func contains(_ url: URL) -> Bool { entries[url.standardizedFileURL] != nil }

    public func invalidate(_ url: URL) {
        if entries.removeValue(forKey: url.standardizedFileURL) != nil {
            rebuildOrder()
        }
    }

    public func invalidateAll() {
        entries.removeAll()
        order.removeAll()
        sourceBytes = 0
    }

    private func applyIncremental(
        entry: inout Entry,
        text: String,
        version: Int,
        edits: [TextEdit]
    ) -> SyntaxTree? {
        var source = entry.source
        for edit in edits {
            guard let step = ParseEdit.make(edit: edit, in: source) else { return nil }
            entry.tree.apply(step.edit)
            source = step.newSource
        }
        guard source == text else { return nil }
        guard let reparsed = entry.parser.parseIncremental(oldTree: entry.tree, source: source) else { return nil }
        entry.source = source
        entry.version = version
        entry.tree = reparsed
        return reparsed
    }

    /// One diff from the cached bytes to `text`, then an incremental reparse. The cached tree is
    /// copied first so a failed reparse leaves it intact.
    private func applyDiff(entry: inout Entry, text: String, version: Int) -> SyntaxTree? {
        let newBytes = Array(text.utf8)
        guard let edit = ParseEdit.diff(from: entry.tree.sourceBytes, to: newBytes) else { return nil }
        let edited = entry.tree.copy()
        edited.apply(edit)
        guard let reparsed = entry.parser.parseIncremental(oldTree: edited, source: text) else { return nil }
        entry.source = text
        entry.version = version
        entry.tree = reparsed
        return reparsed
    }
}
