import Foundation
import TreeSitter

final class TreeSitterInternalLanguage {
    let languagePointer: TreeSitterLanguagePointer
    let highlightsQuery: TreeSitterQuery?
    let injectionsQuery: TreeSitterQuery?
    let indentationScopes: TreeSitterIndentationScopes?
    let lineCommentPrefix: String?

    init(languagePointer: TreeSitterLanguagePointer,
         highlightsQuery: TreeSitterQuery?,
         injectionsQuery: TreeSitterQuery?,
         indentationScopes: TreeSitterIndentationScopes?,
         lineCommentPrefix: String? = nil) {
        self.languagePointer = languagePointer
        self.highlightsQuery = highlightsQuery
        self.injectionsQuery = injectionsQuery
        self.indentationScopes = indentationScopes
        self.lineCommentPrefix = lineCommentPrefix
    }
}
