import Foundation

/// Suggests built-in snippets whose prefix matches the current completion prefix.
public actor SnippetCompletionProvider: CompletionProvider {
    public let name = "Snippet"
    private let snippets: [Snippet]
    private let excludedLanguageIdentifiers: Set<String>

    /// - Parameter excludedLanguageIdentifiers: Documents in these languages get no snippets,
    ///   e.g. `["java"]` to keep the JavaScript-flavored built-ins out of Java files.
    public init(snippets: [Snippet] = Snippet.builtIn, excludedLanguageIdentifiers: Set<String> = []) {
        self.snippets = snippets
        self.excludedLanguageIdentifiers = excludedLanguageIdentifiers
    }

    public func provide(context: CompletionContext) async -> [CompletionItem] {
        if let language = context.document.languageIdentifier, excludedLanguageIdentifiers.contains(language) {
            return []
        }
        let prefix = context.prefix.lowercased()
        return snippets.compactMap { snippet in
            let snippetPrefix = snippet.prefix.lowercased()
            if prefix.isEmpty || snippetPrefix.hasPrefix(prefix) {
                return CompletionItem(
                    label: snippet.prefix,
                    insertText: snippet.body,
                    kind: snippet.kind,
                    range: context.range,
                    source: name,
                    documentation: snippet.description
                )
            }
            return nil
        }
    }
}
