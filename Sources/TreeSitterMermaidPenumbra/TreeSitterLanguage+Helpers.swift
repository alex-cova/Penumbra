import Penumbra
import TreeSitterMermaid
import TreeSitterMermaidQueries

public extension TreeSitterLanguage {
    static var mermaid: TreeSitterLanguage {
        let highlightsQuery = TreeSitterLanguage.Query(contentsOf: TreeSitterMermaidQueries.Query.highlightsFileURL)
        return TreeSitterLanguage(tree_sitter_mermaid(), highlightsQuery: highlightsQuery, lineCommentPrefix: "%%")
    }
}
