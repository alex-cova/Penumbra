import Foundation
import Penumbra
import TreeSitterSwift
import TreeSitterSwiftQueries

public extension TreeSitterLanguage {
    static var swift: TreeSitterLanguage {
        let highlightsQuery = Self.combinedQuery(fromFilesAt: [
            TreeSitterSwiftQueries.Query.highlightsFileURL,
            TreeSitterSwiftQueries.Query.highlightsSwiftUIFileURL
        ])
        return TreeSitterLanguage(tree_sitter_swift(), highlightsQuery: highlightsQuery, injectionsQuery: nil, indentationScopes: .swift, lineCommentPrefix: "//", blockCommentDelimiters: .cStyle)
    }
}
