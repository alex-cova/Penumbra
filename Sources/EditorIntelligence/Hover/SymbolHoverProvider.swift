import Foundation

/// Hover provider that looks up the word at the cursor in the symbol index and returns its
/// documentation or signature as Markdown.
public actor SymbolHoverProvider: HoverProvider {
    public let name = "Symbol"
    private let index: SymbolIndex
    /// Languages a more specific provider owns. A bare name match would only echo the word back
    /// for them, and would shadow that provider when it has nothing to say.
    private let skippedLanguageIdentifiers: Set<String>

    public init(index: SymbolIndex, skippingLanguages: [String] = []) {
        self.index = index
        self.skippedLanguageIdentifiers = Set(skippingLanguages)
    }

    public func provide(context: HoverContext) async -> HoverResult? {
        if let language = context.document.languageIdentifier, skippedLanguageIdentifiers.contains(language) {
            return nil
        }
        let word = context.document.wordAtCursor()
        guard !word.isEmpty else { return nil }
        let symbols = await index.search(exact: word)
        guard let symbol = symbols.first else { return nil }
        let contents = symbol.documentation ?? symbol.signature ?? symbol.name
        return HoverResult(
            contents: contents,
            range: symbol.range,
            source: name
        )
    }
}
