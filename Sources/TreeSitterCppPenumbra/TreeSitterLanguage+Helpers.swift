import Foundation
import Penumbra
import TreeSitterCQueries
import TreeSitterCpp
import TreeSitterCppQueries

public extension TreeSitterLanguage {
    static var cpp: TreeSitterLanguage {
        let highlightsQuery = Self.combinedQuery(fromFilesAt: [
            TreeSitterCQueries.Query.highlightsFileURL,
            TreeSitterCppQueries.Query.highlightsFileURL
        ])
        let injectionsQuery = TreeSitterLanguage.Query(contentsOf: TreeSitterCppQueries.Query.injectionsFileURL)
        return TreeSitterLanguage(
            tree_sitter_cpp(),
            highlightsQuery: highlightsQuery,
            injectionsQuery: injectionsQuery,
            lineCommentPrefix: "//", blockCommentDelimiters: .cStyle
        )
    }
}
