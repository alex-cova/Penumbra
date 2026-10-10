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
        let text = document.text
        if var entry = entries[url], entry.version <= document.version {
            if entry.source == text {
                entry.version = document.version
                entries[url] = entry
                return entry.tree
            }
            if document.version > entry.version {
                if let edits, !edits.isEmpty,
                   let updated = applyIncremental(entry: &entry, text: text, version: document.version, edits: edits) {
                    entries[url] = entry
                    return updated
                }
                if let updated = applyDiff(entry: &entry, text: text, version: document.version) {
                    entries[url] = entry
                    return updated
                }
            }
        }
        let parser = SyntaxParser(language: language)
        guard let tree = parser.parse(text) else { return nil }
        entries[url] = Entry(source: text, version: document.version, tree: tree, parser: parser)
        return tree
    }

    public func invalidate(_ url: URL) {
        entries[url.standardizedFileURL] = nil
    }

    public func invalidateAll() {
        entries.removeAll()
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
