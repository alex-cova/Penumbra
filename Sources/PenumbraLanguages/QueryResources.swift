import Foundation
import os
import Penumbra

private let queryLog = Logger(subsystem: "Penumbra", category: "QueryResources")

enum QueryResources {
    /// The bundled query file, or `nil` when it is missing from the bundle. Missing queries
    /// degrade to no highlighting for that slot — never a crash. The absence is logged so a
    /// broken bundle is diagnosable from Console.
    static func url(named name: String, in language: String) -> URL? {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "scm",
            subdirectory: "Queries/\(language)"
        ) else {
            queryLog.error("Missing bundled query: Queries/\(language, privacy: .public)/\(name, privacy: .public).scm; highlighting for that slot is disabled.")
            return nil
        }
        return url
    }

    /// The parsed query, or `nil` when the file is missing or unreadable. Never traps.
    static func query(named name: String, in language: String) -> TreeSitterLanguage.Query? {
        guard let fileURL = url(named: name, in: language) else { return nil }
        guard let query = TreeSitterLanguage.Query(contentsOf: fileURL) else {
            queryLog.error("Unreadable bundled query: Queries/\(language, privacy: .public)/\(name, privacy: .public).scm; highlighting for that slot is disabled.")
            return nil
        }
        return query
    }

    static func combinedQuery(fromFilesAt fileURLs: [URL]) -> TreeSitterLanguage.Query? {
        TreeSitterLanguage.combinedQuery(fromFilesAt: fileURLs)
    }
}
