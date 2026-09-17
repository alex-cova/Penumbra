import Foundation
import Penumbra
import TreeSitterMarkdown
import TreeSitterMarkdownInline

public extension TreeSitterLanguage {
    /// The block-level Markdown grammar. Headings, lists, block quotes, code fences, and similar
    /// block structure are parsed by this language; inline content within them (emphasis, links,
    /// code spans, etc.) is highlighted by injecting ``markdownInline`` — supply a
    /// ``MarkdownLanguageProvider`` as the `languageProvider` of `TreeSitterLanguageMode` for that
    /// injection to be resolved.
    static var markdown: TreeSitterLanguage {
        let highlightsQuery = TreeSitterLanguage.Query(contentsOf: markdownQueryURL(named: "highlights", in: "Block"))
        let injectionsQuery = TreeSitterLanguage.Query(contentsOf: markdownQueryURL(named: "injections", in: "Block"))
        return TreeSitterLanguage(tree_sitter_markdown(),
                                   highlightsQuery: highlightsQuery,
                                   injectionsQuery: injectionsQuery,
                                   indentationScopes: .markdown)
    }

    /// The inline Markdown grammar, resolving emphasis, strong emphasis, links, code spans, and
    /// similar inline constructs. Used as an injected language within ``markdown`` rather than set
    /// directly on a `TextView`.
    static var markdownInline: TreeSitterLanguage {
        let highlightsQuery = TreeSitterLanguage.Query(contentsOf: markdownQueryURL(named: "highlights", in: "Inline"))
        let injectionsQuery = TreeSitterLanguage.Query(contentsOf: markdownQueryURL(named: "injections", in: "Inline"))
        return TreeSitterLanguage(tree_sitter_markdown_inline(),
                                   highlightsQuery: highlightsQuery,
                                   injectionsQuery: injectionsQuery)
    }
}

private func markdownQueryURL(named name: String, in subdirectory: String) -> URL {
    guard let url = Bundle.module.url(forResource: name, withExtension: "scm", subdirectory: "Queries/\(subdirectory)") else {
        fatalError("Could not find \(name).scm in Queries/\(subdirectory)")
    }
    return url
}
