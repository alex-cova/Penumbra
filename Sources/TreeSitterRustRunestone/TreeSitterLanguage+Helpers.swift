import Runestone
import TreeSitterRust
import TreeSitterRustQueries

public extension TreeSitterLanguage {
    static var rust: TreeSitterLanguage {
        let highlightsQuery = TreeSitterLanguage.Query(contentsOf: TreeSitterRustQueries.Query.highlightsFileURL)
        return TreeSitterLanguage(tree_sitter_rust(), highlightsQuery: highlightsQuery, lineCommentPrefix: "//")
    }
}
