import Foundation

/// Navigation provider that looks up the word under the cursor and returns its definition location.
public actor GoToDefinitionProvider: NavigationProvider {
    public let name = "GoToDefinition"
    private let index: SymbolIndex
    /// Languages a more specific provider owns. A failed Java resolve must not fall through to a
    /// same-name hit in some other file.
    private let skippedLanguageIdentifiers: Set<String>

    public init(index: SymbolIndex, skippingLanguages: [String] = []) {
        self.index = index
        self.skippedLanguageIdentifiers = Set(skippingLanguages)
    }

    public func provide(context: NavigationContext) async -> NavigationResult? {
        // Symbol-index lookup is a name match, so it can stand in for "go to
        // implementation" too when no LSP is configured.
        guard context.kind == .definition || context.kind == .implementation else { return nil }
        if let language = context.document.languageIdentifier, skippedLanguageIdentifiers.contains(language) {
            return nil
        }
        let target = context.document.wordAtCursor()
        guard !target.isEmpty else { return nil }
        let symbols = await index.search(exact: target)
        guard let symbol = symbols.first else { return nil }
        return .single(Location(
            documentID: symbol.documentID,
            url: nil,
            range: symbol.range,
            displayName: symbol.name
        ))
    }
}
