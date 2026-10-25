import XCTest
@testable import Penumbra
import PenumbraLanguages

/// Every grammar `PenumbraLanguages` ships must prepare: a missing or broken query file
/// force-unwraps inside `QueryResources.query(named:in:)`, which would otherwise surface as a
/// crash the first time a user opens that language. Resolving every built-in identifier here
/// turns that into a test failure, and guards the registration table against entries whose
/// highlights silently go missing (`combinedQuery` returns `nil` on failure).
final class BundledGrammarConsistencyTests: XCTestCase {
    func testEveryBundledGrammarResolvesWithHighlights() {
        var resolved = 0
        var withoutHighlights: [String] = []
        for definition in LanguageDefinition.builtIns {
            guard let language = BundledLanguages.language(forIdentifier: definition.id) else {
                continue // No bundled grammar for this identifier (e.g. plain text).
            }
            resolved += 1
            if language.highlightsQuery == nil {
                withoutHighlights.append(definition.id)
            }
        }
        XCTAssertTrue(
            withoutHighlights.isEmpty,
            "Bundled grammars without a highlights query: \(withoutHighlights.joined(separator: ", "))"
        )
        XCTAssertGreaterThanOrEqual(
            resolved, 25,
            "Only \(resolved) bundled grammars resolved; the registration table may have lost entries."
        )
    }
}
