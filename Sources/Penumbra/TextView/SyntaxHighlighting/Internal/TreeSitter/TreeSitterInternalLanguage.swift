import Foundation
import TreeSitter

final class TreeSitterInternalLanguage {
    let languagePointer: TreeSitterLanguagePointer
    let highlightsQuery: TreeSitterQuery?
    let injectionsQuery: TreeSitterQuery?
    let indentationScopes: TreeSitterIndentationScopes?
    let lineCommentPrefix: String?
    let enterBehavior: EnterBehavior?

    init(languagePointer: TreeSitterLanguagePointer,
         highlightsQuery: TreeSitterQuery?,
         injectionsQuery: TreeSitterQuery?,
         indentationScopes: TreeSitterIndentationScopes?,
         lineCommentPrefix: String? = nil,
         enterBehavior: EnterBehavior? = nil) {
        self.languagePointer = languagePointer
        self.highlightsQuery = highlightsQuery
        self.injectionsQuery = injectionsQuery
        self.indentationScopes = indentationScopes
        self.lineCommentPrefix = lineCommentPrefix
        self.enterBehavior = enterBehavior
    }
}
