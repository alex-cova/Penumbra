import Foundation
import Runestone
import TreeSitterSwift
import TreeSitterSwiftQueries

public extension TreeSitterLanguage {
    static var swift: TreeSitterLanguage {
        let highlightsQuery = Self.combinedQuery(fromFilesAt: [
            TreeSitterSwiftQueries.Query.highlightsFileURL,
            TreeSitterSwiftQueries.Query.highlightsSwiftUIFileURL
        ])
        return TreeSitterLanguage(tree_sitter_swift(), highlightsQuery: highlightsQuery, injectionsQuery: nil, indentationScopes: .swift, lineCommentPrefix: "//")
    }

    private static func combinedQuery(fromFilesAt fileURLs: [URL]) -> TreeSitterLanguage.Query? {
        let rawQuery = fileURLs.compactMap { try? String(contentsOf: $0) }.joined(separator: "\n")
        return rawQuery.isEmpty ? nil : TreeSitterLanguage.Query(string: rawQuery)
    }
}
