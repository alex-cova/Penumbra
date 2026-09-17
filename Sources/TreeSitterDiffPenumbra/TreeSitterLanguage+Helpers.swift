import Penumbra
import TreeSitterDiff
import TreeSitterDiffQueries

public extension TreeSitterLanguage {
    static var diff: TreeSitterLanguage {
        let highlightsQuery = TreeSitterLanguage.Query(contentsOf: TreeSitterDiffQueries.Query.highlightsFileURL)
        return TreeSitterLanguage(tree_sitter_diff(), highlightsQuery: highlightsQuery, lineCommentPrefix: "#")
    }
}
