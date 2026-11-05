import Foundation
import TreeSitter
import EditorIntelligence

/// Tree-sitter-based `LanguageParser` that produces a `TreeSitterSyntaxTree`.
///
/// The parser is an actor because the underlying `TreeSitterParser` is not thread-safe. It keeps the
/// last tree of each document it has parsed (bounded, least recently used out first) and reparses an
/// edited document against it: the one changed region between the previous text and the new text is
/// handed to `ts_tree_edit` and tree-sitter reuses every subtree outside it. The tree is derived into
/// symbols, words and imports as before; that pass is still over the whole document.
public actor TreeSitterLanguageParser: LanguageParser {
    private struct Entry {
        var text: String
        var tree: TreeSitterTree
        /// Language the cached extraction was built for; a document keeps its snapshot when the
        /// identifier changes without a text change.
        var languageIdentifier: String?
        /// Extraction for `text`, so re-parsing an unchanged snapshot is O(1). Cleared on edit.
        var cached: TreeSitterSyntaxTree?
        /// `text` bytes plus the cached extraction footprint, for cap accounting.
        var footprint: Int
    }

    private let languageMode: TreeSitterLanguageMode
    private let parser: TreeSitterParser
    private let languageConfigurations: LanguageConfigurationRegistry
    private var entries: [DocumentID: Entry] = [:]
    /// Least recently parsed first.
    private var order: [DocumentID] = []
    private var cachedBytes = 0
    /// Past these bounds the least recently parsed documents are parsed from scratch next time.
    nonisolated(unsafe) static var maxEntries = 64
    nonisolated(unsafe) static var maxCachedBytes = 32 * 1024 * 1024
    /// Parses that started from scratch, and parses that reused the document's previous tree.
    public private(set) var fullParseCount = 0
    public private(set) var incrementalParseCount = 0
    /// Symbol/word/import extractions run. Unchanged snapshots reuse the cached extraction, so
    /// this stays flat while `parse` is called repeatedly without edits.
    public private(set) var extractionCount = 0

    public init(
        language: TreeSitterLanguage,
        languageConfigurations: LanguageConfigurationRegistry = .builtIns
    ) {
        let mode = TreeSitterLanguageMode(language: language)
        self.languageMode = mode
        self.languageConfigurations = languageConfigurations
        self.parser = TreeSitterParser(encoding: .treeSitterUTF16)
        self.parser.language = mode.language.languagePointer
    }

    public init(
        languageMode: TreeSitterLanguageMode,
        languageConfigurations: LanguageConfigurationRegistry = .builtIns
    ) {
        self.languageMode = languageMode
        self.languageConfigurations = languageConfigurations
        self.parser = TreeSitterParser(encoding: .treeSitterUTF16)
        self.parser.language = languageMode.language.languagePointer
    }

    public func parse(document: Document) async -> SyntaxTree {
        let text = document.contentSnapshot.text ?? ""
        // An unchanged snapshot reuses its extraction: extraction is a pure function of
        // (tree structure, text, configuration), all covered by this key.
        if let entry = entries[document.id],
           entry.text == text,
           entry.languageIdentifier == document.languageIdentifier,
           let cached = entry.cached {
            touch(document.id)
            return cached
        }
        let tree = parsedTree(for: text, documentID: document.id)
        let configuration = languageConfigurations.configuration(for: document.languageIdentifier)
        let extraction = TreeSitterSyntaxTree(
            tree: tree,
            documentID: document.id,
            text: text,
            languageConfiguration: configuration
        )
        extractionCount += 1
        // Only reusable trees are cached: a failed first parse leaves no entry to attach to.
        if tree != nil, entries[document.id] != nil {
            let footprint = Self.footprint(of: extraction)
            entries[document.id]?.cached = extraction
            entries[document.id]?.languageIdentifier = document.languageIdentifier
            entries[document.id]?.footprint += footprint
            cachedBytes += footprint
            evictIfNeeded()
        }
        return extraction
    }

    /// Approximate memory of an extraction, for cap accounting.
    private static func footprint(of extraction: TreeSitterSyntaxTree) -> Int {
        var bytes = 0
        for symbol in extraction.symbols {
            bytes += symbol.name.utf8.count + 48
        }
        for word in extraction.words {
            bytes += word.utf8.count + 8
        }
        for imported in extraction.imports {
            bytes += imported.utf8.count + 8
        }
        return bytes
    }

    private func parsedTree(for text: String, documentID: DocumentID) -> TreeSitterTree? {
        if var entry = entries[documentID] {
            if entry.text == text {
                touch(documentID)
                return entry.tree
            }
            if let edit = TextChangeRegion.edit(from: entry.text, to: text) {
                entry.tree.apply(edit)
                if let tree = parser.parse(text as NSString, oldTree: entry.tree) {
                    incrementalParseCount += 1
                    store(documentID, tree, text: text)
                    return tree
                }
            }
            remove(documentID)
        }
        fullParseCount += 1
        guard let tree = parser.parse(text as NSString) else { return nil }
        store(documentID, tree, text: text)
        return tree
    }

    private func store(_ id: DocumentID, _ tree: TreeSitterTree, text: String) {
        if let old = entries[id] {
            cachedBytes -= old.footprint
            order.removeAll { $0 == id }
        }
        entries[id] = Entry(
            text: text,
            tree: tree,
            languageIdentifier: nil,
            cached: nil,
            footprint: text.utf8.count
        )
        cachedBytes += text.utf8.count
        order.append(id)
        evictIfNeeded()
    }

    /// Drop least-recently-parsed documents while over a cap. The most recent entry stays even
    /// when it alone is over a cap.
    private func evictIfNeeded() {
        while entries.count > Self.maxEntries || cachedBytes > Self.maxCachedBytes, order.count > 1 {
            remove(order[0])
        }
    }

    private func remove(_ id: DocumentID) {
        if let removed = entries.removeValue(forKey: id) {
            cachedBytes -= removed.footprint
        }
        order.removeAll { $0 == id }
    }

    private func touch(_ id: DocumentID) {
        guard order.last != id else { return }
        order.removeAll { $0 == id }
        order.append(id)
    }

    /// Documents whose previous tree is kept, for tests.
    var cachedDocumentCount: Int { entries.count }
}
