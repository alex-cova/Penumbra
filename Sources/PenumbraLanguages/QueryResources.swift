import Foundation
import Penumbra

enum QueryResources {
    static func url(named name: String, in language: String) -> URL {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "scm",
            subdirectory: "Queries/\(language)"
        ) else {
            fatalError("Could not find Queries/\(language)/\(name).scm")
        }
        return url
    }

    static func query(named name: String, in language: String) -> TreeSitterLanguage.Query {
        TreeSitterLanguage.Query(contentsOf: url(named: name, in: language))!
    }

    static func combinedQuery(fromFilesAt fileURLs: [URL]) -> TreeSitterLanguage.Query? {
        let rawQuery = fileURLs.compactMap { try? String(contentsOf: $0) }.joined(separator: "\n")
        return rawQuery.isEmpty ? nil : TreeSitterLanguage.Query(string: rawQuery)
    }
}
