import Foundation
import TreeSitter

final class TreeSitterInternalLanguage {
    let languagePointer: TreeSitterLanguagePointer
    let highlightsQuery: TreeSitterQuery?
    let injectionsQuery: TreeSitterQuery?
    let indentationScopes: TreeSitterIndentationScopes?
    let lineCommentPrefix: String?
    let blockCommentDelimiters: BlockCommentDelimiters?
    let enterBehavior: EnterBehavior?

    init(languagePointer: TreeSitterLanguagePointer,
         highlightsQuery: TreeSitterQuery?,
         injectionsQuery: TreeSitterQuery?,
         indentationScopes: TreeSitterIndentationScopes?,
         lineCommentPrefix: String? = nil,
         blockCommentDelimiters: BlockCommentDelimiters? = nil,
         enterBehavior: EnterBehavior? = nil) {
        self.languagePointer = languagePointer
        self.highlightsQuery = highlightsQuery
        self.injectionsQuery = injectionsQuery
        self.indentationScopes = indentationScopes
        self.lineCommentPrefix = lineCommentPrefix
        self.blockCommentDelimiters = blockCommentDelimiters
        self.enterBehavior = enterBehavior
    }
}
