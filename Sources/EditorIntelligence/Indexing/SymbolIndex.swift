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

    /// Replace the symbols for a single document. Only the difference from the previous set touches
    /// the trie, so re-indexing after a small edit costs the change, not the document.
    public func index(_ symbols: [Symbol], for documentID: DocumentID) {
        let symbolSet = Set(symbols)
        let previous = symbolsByDocument[documentID] ?? []
        for symbol in previous.subtracting(symbolSet) {
            trie.remove(symbol.name, value: symbol)
        }
        for symbol in symbolSet.subtracting(previous) {
            trie.insert(symbol.name, value: symbol)
        }
        symbolsByDocument[documentID] = symbolSet
    }

    /// Remove all symbols associated with a document.
    public func remove(documentID: DocumentID) {
        guard let symbols = symbolsByDocument.removeValue(forKey: documentID) else { return }
        for symbol in symbols {
            trie.remove(symbol.name, value: symbol)
        }
    }

    /// Find symbols whose name begins with the given prefix, shortest names first when `limit` is set.
    ///
    /// `include` runs before `limit`, so filtered-out symbols never use up the cap.
    public func search(
        prefix: String,
        limit: Int? = nil,
        where include: @Sendable (Symbol) -> Bool = { _ in true }
    ) -> [Symbol] {
        EditorPerformanceTrace.shared.measure(.indexQuery) {
            trie.search(prefix: prefix, limit: limit, where: include)
        }
    }

    /// Find symbols whose name matches the query exactly.
    public func search(exact: String) -> [Symbol] {
        EditorPerformanceTrace.shared.measure(.indexQuery) {
            trie.search(exact: exact)
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
