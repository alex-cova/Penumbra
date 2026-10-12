import Penumbra
import TreeSitterGitIgnore
import TreeSitterGitIgnoreQueries

public extension TreeSitterLanguage {
    /// `.gitignore`, `.dockerignore`, `.npmignore` and the like: one pattern per line, `#` comments.
    static var gitIgnore: TreeSitterLanguage {
        let highlightsQuery = TreeSitterLanguage.Query(contentsOf: TreeSitterGitIgnoreQueries.Query.highlightsFileURL)
        return TreeSitterLanguage(tree_sitter_gitignore(), highlightsQuery: highlightsQuery, lineCommentPrefix: "#")
    }
}
