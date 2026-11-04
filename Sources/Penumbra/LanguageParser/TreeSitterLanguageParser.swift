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
        let tree = parsedTree(for: text, documentID: document.id)
        let configuration = languageConfigurations.configuration(for: document.languageIdentifier)
        return TreeSitterSyntaxTree(
            tree: tree,
            documentID: document.id,
            text: text,
            languageConfiguration: configuration
        )
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
                    store(documentID, Entry(text: text, tree: tree))
                    return tree
                }
            }
            remove(documentID)
        }
        fullParseCount += 1
        guard let tree = parser.parse(text as NSString) else { return nil }
        store(documentID, Entry(text: text, tree: tree))
        return tree
    }

    private func store(_ id: DocumentID, _ entry: Entry) {
        if let old = entries[id] {
            cachedBytes -= old.text.utf8.count
            order.removeAll { $0 == id }
        }
        entries[id] = entry
        cachedBytes += entry.text.utf8.count
        order.append(id)
        // The entry just stored stays even when it alone is over a cap.
        while entries.count > Self.maxEntries || cachedBytes > Self.maxCachedBytes, order.count > 1 {
            remove(order[0])
        }
    }

    private func remove(_ id: DocumentID) {
        if let removed = entries.removeValue(forKey: id) {
            cachedBytes -= removed.text.utf8.count
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
