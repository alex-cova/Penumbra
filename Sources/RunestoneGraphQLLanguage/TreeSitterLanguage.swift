import Foundation
import Runestone
import TreeSitterGraphQL

public extension TreeSitterLanguage {
    static var graphQL: TreeSitterLanguage {
        let highlightsQueryURL = Bundle.module.url(forResource: "highlights", withExtension: "scm")!
        let highlightsQuery = TreeSitterLanguage.Query(contentsOf: highlightsQueryURL)
        return TreeSitterLanguage(tree_sitter_graphql(),
                                  highlightsQuery: highlightsQuery,
                                  injectionsQuery: nil,
                                  indentationScopes: .graphQL,
                                  lineCommentPrefix: "#")
    }
}
