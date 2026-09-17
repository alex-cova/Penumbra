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
/// `"html"`, `"yaml"`) rather than `"markdown_inline"`. Wrap this provider in your own
/// `TreeSitterLanguageProvider` if you also want those highlighted.
public final class MarkdownLanguageProvider: TreeSitterLanguageProvider {
    public init() {}

    public func treeSitterLanguage(named languageName: String) -> TreeSitterLanguage? {
        languageName == "markdown_inline" ? .markdownInline : nil
    }
}
