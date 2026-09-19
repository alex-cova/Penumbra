import Penumbra

/// Resolves the `markdown_inline` language injected by ``TreeSitterLanguage/markdown`` into
/// inline content (headings, paragraphs, list items, etc.), so emphasis, links, code spans, and
/// similar inline constructs are highlighted.
///
/// ```swift
/// let languageMode = TreeSitterLanguageMode(language: .markdown, languageProvider: MarkdownLanguageProvider())
/// textView.setState(TextViewState(text: text, language: languageMode))
/// ```
///
/// Fenced code blocks, HTML blocks, and YAML/TOML front matter are also injected by
/// ``TreeSitterLanguage/markdown`` but are named after the languages they contain (e.g. `"swift"`,
/// `"html"`, `"yaml"`) rather than `"markdown_inline"`. Pass a `fenceLanguageProvider` (such as
/// `BundledLanguageProvider` from `PenumbraLanguages`) to have those highlighted too.
public final class MarkdownLanguageProvider: TreeSitterLanguageProvider, @unchecked Sendable {
    // `TreeSitterLanguage.markdownInline` is a computed property that re-reads and recompiles two
    // `.scm` files on every access, and a child layer — hence a provider call — is created for every
    // `(inline)` node in the document. Without this cache a long document recompiles them per paragraph.
    private let cache = TreeSitterLanguageCache<String>()
    private let fenceLanguageProvider: TreeSitterLanguageProvider?

    /// - Parameter fenceLanguageProvider: Consulted for every language other than `markdown_inline`.
    public init(fenceLanguageProvider: TreeSitterLanguageProvider? = nil) {
        self.fenceLanguageProvider = fenceLanguageProvider
    }

    public func treeSitterLanguage(named languageName: String) -> TreeSitterLanguage? {
        if languageName == "markdown_inline" {
            return cache.language(for: languageName) { .markdownInline }
        }
        return fenceLanguageProvider?.treeSitterLanguage(named: languageName)
    }
}
