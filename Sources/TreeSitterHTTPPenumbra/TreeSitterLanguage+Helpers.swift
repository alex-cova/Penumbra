import Penumbra
import TreeSitterHTTP
import TreeSitterHTTPQueries

public extension TreeSitterLanguage {
    static var http: TreeSitterLanguage {
        let highlightsQuery = TreeSitterLanguage.Query(contentsOf: TreeSitterHTTPQueries.Query.highlightsFileURL)
        let injectionsQuery = TreeSitterLanguage.Query(contentsOf: TreeSitterHTTPQueries.Query.injectionsFileURL)
        return TreeSitterLanguage(
            tree_sitter_http(),
            highlightsQuery: highlightsQuery,
            injectionsQuery: injectionsQuery,
            lineCommentPrefix: "#"
        )
    }
}
