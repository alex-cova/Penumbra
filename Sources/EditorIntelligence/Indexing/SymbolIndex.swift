import Foundation

/// Actor-isolated symbol database that supports incremental updates at the document level.
///
/// The index stores every `Symbol` extracted from a document and indexes each symbol by name in a
/// trie. Updating a document removes all of its previous symbols and inserts the new ones, giving
/// O(changes) cost relative to the size of the document rather than the whole workspace.
public actor SymbolIndex {
    private var trie = Trie<Symbol>()
    private var symbolsByDocument: [DocumentID: Set<Symbol>] = [:]

    public init() {}

    /// Replace the symbols for a single document. Previous symbols for the document are removed.
    public func index(_ symbols: [Symbol], for documentID: DocumentID) {
        remove(documentID: documentID)
        let symbolSet = Set(symbols)
        symbolsByDocument[documentID] = symbolSet
        for symbol in symbolSet {
            trie.insert(symbol.name, value: symbol)
        }
    }

    /// Remove all symbols associated with a document.
    public func remove(documentID: DocumentID) {
        guard let symbols = symbolsByDocument.removeValue(forKey: documentID) else { return }
        for symbol in symbols {
            trie.remove(symbol.name, value: symbol)
        }
    }

    /// Find symbols whose name begins with the given prefix.
    public func search(prefix: String) -> [Symbol] {
        EditorPerformanceTrace.shared.measure(.indexQuery) {
            trie.search(prefix: prefix)
        }
    }

    /// Find symbols whose name matches the query exactly.
    public func search(exact: String) -> [Symbol] {
        EditorPerformanceTrace.shared.measure(.indexQuery) {
            trie.search(prefix: exact).filter { $0.name == exact }
        }
    }

    /// All symbols currently stored in the index.
    public func allSymbols() -> [Symbol] {
        symbolsByDocument.values.flatMap { Array($0) }
    }

    /// Symbols from a specific document.
    public func symbols(in documentID: DocumentID) -> [Symbol] {
        Array(symbolsByDocument[documentID] ?? [])
    }
}
