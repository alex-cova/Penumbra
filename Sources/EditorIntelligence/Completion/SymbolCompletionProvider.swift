import Foundation

/// Suggests indexed symbols whose name matches the current completion prefix.
public actor SymbolCompletionProvider: CompletionProvider {
    public let name = "Symbol"
    private let index: SymbolIndex

    public init(index: SymbolIndex) {
        self.index = index
    }

    public func provide(context: CompletionContext) async -> [CompletionItem] {
        let prefix = context.prefix
        // Plain buffer words come from `WordCompletionProvider` (as `.text`, which never opens the
        // popup on its own while typing prose); reporting them here as variables would.
        let symbols = await index.search(prefix: prefix).filter { $0.kind != .word }
        return symbols.map { symbol in
            CompletionItem(
                label: symbol.name,
                insertText: symbol.name,
                kind: kindForSymbol(symbol.kind),
                range: context.range,
                source: name,
                documentation: symbol.documentation
            )
        }
    }

    private func kindForSymbol(_ kind: SymbolKind) -> CompletionItemKind {
        switch kind {
        case .function:
            return .function
        case .type:
            return .type
        case .property:
            return .property
        case .variable, .unknown, .word:
            return .variable
        case .importStatement:
            return .module
        case .fileName:
            return .file
        }
    }
}
