import Foundation

/// Navigation provider that looks up the word under the cursor and returns all indexed locations.
public actor FindReferencesProvider: NavigationProvider {
    public let name = "FindReferences"
    private let index: SymbolIndex
    /// Languages a more specific provider owns. A name match is wrong for them (false positives
    /// and negatives), so no result is better than this one.
    private let skippedLanguageIdentifiers: Set<String>

    public init(index: SymbolIndex, skippingLanguages: [String] = []) {
        self.index = index
        self.skippedLanguageIdentifiers = Set(skippingLanguages)
    }

    public func provide(context: NavigationContext) async -> NavigationResult? {
        guard context.kind == .references else { return nil }
        if let language = context.document.languageIdentifier, skippedLanguageIdentifiers.contains(language) {
            return nil
        }
        let target = context.document.wordAtCursor()
        guard !target.isEmpty else { return nil }
        let symbols = await index.search(exact: target)
        guard !symbols.isEmpty else { return nil }
        let locations = symbols.map { symbol in
            Location(
                documentID: symbol.documentID,
                url: nil,
                range: symbol.range,
                displayName: symbol.name
            )
        }
        return .multiple(locations)
    }
}
