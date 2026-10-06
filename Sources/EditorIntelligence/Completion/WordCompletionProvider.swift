import Foundation

/// Suggests indexed document words whose name matches the current completion prefix.
public actor WordCompletionProvider: CompletionProvider {
    public let name = "Word"
    /// Candidates collected from the index before ranking; a one-letter prefix would otherwise
    /// return every word in the workspace.
    static let maxCandidates = 500
    private let index: SymbolIndex

    public init(index: SymbolIndex) {
        self.index = index
    }

    public func provide(context: CompletionContext) async -> [CompletionItem] {
        let prefix = context.prefix
        let symbols = await index.search(prefix: prefix, limit: Self.maxCandidates) { $0.kind == .word }
        return symbols
            .map { word in
                CompletionItem(
                    label: word.name,
                    insertText: word.name,
                    kind: .text,
                    range: context.range,
                    source: name
                )
            }
    }
}
