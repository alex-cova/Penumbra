import Foundation
@preconcurrency import AppKit

enum MarkdownPreviewCodeHighlighter {
    static func highlight(
        source: String,
        languageHint: String?,
        theme: Theme,
        languageResolver: (String) -> TreeSitterLanguage?,
        languageProvider: TreeSitterLanguageProvider? = nil
    ) -> NSAttributedString? {
        guard let identifier = MarkdownPreviewFenceLanguage.normalize(languageHint),
              let language = languageResolver(identifier) else {
            return nil
        }
        let highlighter = StringSyntaxHighlighter(
            theme: theme,
            language: language,
            languageProvider: languageProvider
        )
        return highlighter.syntaxHighlight(source)
    }
}
