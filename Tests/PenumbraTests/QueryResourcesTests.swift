import Foundation
import XCTest
@testable import PenumbraLanguages

/// F-18: bundled query files are optional resources. A missing file degrades to no-query for
/// that slot — logged, never a crash.
final class QueryResourcesTests: XCTestCase {
    func testMissingQueryURLReturnsNilInsteadOfCrashing() {
        XCTAssertNil(QueryResources.url(named: "does-not-exist", in: "NoSuchLanguage"))
    }

    func testMissingQueryReturnsNilInsteadOfCrashing() {
        XCTAssertNil(QueryResources.query(named: "does-not-exist", in: "NoSuchLanguage"))
    }

    func testCombinedQueryWithNoReadableFilesReturnsNil() {
        XCTAssertNil(QueryResources.combinedQuery(fromFilesAt: []))
        XCTAssertNil(QueryResources.combinedQuery(
            fromFilesAt: [URL(fileURLWithPath: "/nonexistent/highlights.scm")]
        ))
    }

    func testCombinedQuerySkipsMissingFiles() {
        let bundled = QueryResources.url(named: "highlights", in: "JSON")
        XCTAssertNotNil(bundled, "JSON highlights query must ship with the bundle")
        let combined = QueryResources.combinedQuery(fromFilesAt: [
            URL(fileURLWithPath: "/nonexistent/highlights.scm"),
            bundled!,
        ])
        XCTAssertNotNil(combined, "one readable file is enough; the missing one is skipped")
    }
}
