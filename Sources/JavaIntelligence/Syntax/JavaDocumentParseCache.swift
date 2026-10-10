import EditorIntelligence
import Foundation
import TreeSitterJava

/// Per-document incremental parse cache. Applies tree-sitter ``ts_tree_edit`` for small edits
/// and falls back to a full parse when there is no cached tree or edits are unavailable.
///
/// The default grammar is Java. A host can point the same cache at another tree-sitter language
/// (Umbra does this for TypeScript); only documents with that ``languageIdentifier`` are parsed.
public actor JavaDocumentParseCache {
    private struct Entry {
        var source: String
        var version: Int
        var tree: JavaSyntaxTree
        let parser: JavaSyntaxParser
    }

    private var entries: [URL: Entry] = [:]
    private let languageIdentifier: String
    private let language: OpaquePointer

    /// The Java grammar. The pointer is chosen here, not as a default argument: a client that also
    /// imports Tree-sitter sees `tree_sitter_java` as a different pointer type and cannot re-check it.
    public init() {
        self.init(languageIdentifier: "java", language: tree_sitter_java())
    }

    /// `language` is a `tree_sitter_*()` pointer and must stay valid for the cache's lifetime.
    public init(languageIdentifier: String, language: OpaquePointer) {
        self.languageIdentifier = languageIdentifier
        self.language = language
    }

    /// Returns a syntax tree for `document`, incrementally when possible.
    public func tree(for document: Document, edits: [TextEdit]? = nil) -> JavaSyntaxTree? {
        guard document.languageIdentifier == languageIdentifier, let url = document.url else { return nil }
        guard !document.contentSnapshot.isElided else { return nil }
        let text = document.text
        if var entry = entries[url], entry.version <= document.version {
            if entry.source == text {
                entry.version = document.version
                entries[url] = entry
                return entry.tree
            }
            if let edits, !edits.isEmpty, document.version > entry.version {
                if let updated = applyIncremental(entry: &entry, text: text, version: document.version, edits: edits) {
                    entries[url] = entry
                    return updated
                }
            }
        }
        let parser = JavaSyntaxParser(language: language)
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
    ) -> JavaSyntaxTree? {
        var source = entry.source
        for edit in edits {
            guard let step = JavaParseEdit.make(edit: edit, in: source) else { return nil }
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
}
