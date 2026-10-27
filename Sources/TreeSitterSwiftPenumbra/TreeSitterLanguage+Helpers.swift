import Foundation
import Penumbra
import TreeSitterSwift
import TreeSitterSwiftQueries

public extension TreeSitterLanguage {
    static var swift: TreeSitterLanguage {
        // The SwiftUI overlay comes first: highlight queries list specific patterns before
        // fallbacks, and on a same-range tie the earlier pattern wins, so the overlay's
        // `@type.builtin`/`@attribute` captures beat the generic `@function.call`/`@type` ones.
        let highlightsQuery = Self.combinedQuery(fromFilesAt: [
            TreeSitterSwiftQueries.Query.highlightsSwiftUIFileURL,
            TreeSitterSwiftQueries.Query.highlightsFileURL
        ])
        return TreeSitterLanguage(tree_sitter_swift(), highlightsQuery: highlightsQuery, injectionsQuery: nil, indentationScopes: .swift, lineCommentPrefix: "//", blockCommentDelimiters: .cStyle)
    }
}
