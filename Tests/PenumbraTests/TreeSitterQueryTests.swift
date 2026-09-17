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
}
