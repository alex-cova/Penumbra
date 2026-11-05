import XCTest
import TestTreeSitterLanguages
@testable import Penumbra

final class TreeSitterQueryTests: XCTestCase {
    func testQuerySourceLengthUsesUTF8Bytes() throws {
        // Non-ASCII in a comment used to make `ts_query_new` truncate the query because
        // Swift `String.count` is characters, not UTF-8 bytes.
        let source = "; café — ellipsis …\n(string) @string\n"
        guard let language = TreeSitterLanguagePointer(tree_sitter_json()) else {
            XCTFail("tree_sitter_json() returned nil")
            return
        }
        XCTAssertGreaterThan(source.utf8.count, source.count)
        XCTAssertNoThrow(try TreeSitterQuery(source: source, language: language))
    }

    /// F-18: an invalid query disables highlighting for that slot — never a crash, never silent.
    /// `prepare()` must complete and the compiled query must come out `nil`.
    func testInvalidQueryDegradesInsteadOfCrashing() {
        let language = TreeSitterLanguage(
            tree_sitter_json(),
            highlightsQuery: TreeSitterLanguage.Query(string: "(((this is not a query [[[")
        )
        language.prepare()
        XCTAssertNil(language.internalLanguage.highlightsQuery)
    }

    /// F-18: a query file that cannot be read produces `nil`, not a trap.
    func testUnreadableQueryFileReturnsNil() {
        let missing = URL(fileURLWithPath: "/nonexistent/highlights.scm")
        XCTAssertNil(TreeSitterLanguage.Query(contentsOf: missing))
    }
}
