import Runestone
import TreeSitterHTTP
import TreeSitterHTTPQueries

public extension TreeSitterLanguage {
    static var http: TreeSitterLanguage {
        let highlightsQuery = TreeSitterLanguage.Query(contentsOf: TreeSitterHTTPQueries.Query.highlightsFileURL)
        return TreeSitterLanguage(tree_sitter_http(), highlightsQuery: highlightsQuery, lineCommentPrefix: "#")
    }
}
