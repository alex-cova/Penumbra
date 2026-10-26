import XCTest
import GitIntelligence
@testable import Penumbra
@testable import Umbra

final class IDEBlamePresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hashA = String(repeating: "a", count: 40)
    private let hashB = String(repeating: "b", count: 40)

    private func line(_ hash: String, author: String = "Alex", daysAgo: Double = 3, summary: String = "Fix it") -> GitBlameLine {
        GitBlameLine(hash: hash, author: author, date: now.addingTimeInterval(-daysAgo * 86_400), summary: summary,
                     isUncommitted: hash.allSatisfy { $0 == "0" })
    }

    private func annotations(_ lines: [GitBlameLine]) -> [GutterAnnotation?] {
        IDEBlamePresentation.annotations(for: lines, now: now, locale: Locale(identifier: "en_US"))
    }

    func testLinesOfOneCommitShareAnAnnotation() throws {
        let result = annotations([line(hashA), line(hashA), line(hashB, author: "Sam")])
        XCTAssertEqual(result[0], result[1])
        XCTAssertNotEqual(result[1], result[2])
        XCTAssertEqual(try XCTUnwrap(result[2]).text.hasPrefix("Sam, "), true)
    }

    func testTheTextNamesTheAuthorAndAge() throws {
        let text = try XCTUnwrap(annotations([line(hashA, daysAgo: 3)])[0]).text
        XCTAssertEqual(text, "Alex, 3 days ago")
    }

    func testTheTooltipCarriesTheCommitAndSummary() throws {
        let tooltip = try XCTUnwrap(annotations([line(hashA, summary: "Add blame")])[0]).tooltip
        XCTAssertTrue(tooltip.hasPrefix("aaaaaaa Add blame"), tooltip)
    }

    func testUncommittedLinesUseTheEditedAnnotation() {
        let zeros = String(repeating: "0", count: 40)
        let result = annotations([line(hashA), line(zeros), line(zeros), line(hashA)])
        XCTAssertEqual(result[1], IDEBlamePresentation.edited)
        XCTAssertEqual(result[2], IDEBlamePresentation.edited)
        // A commit keeps its id across the uncommitted stretch, so it is one block on each side.
        XCTAssertEqual(result[0]?.id, result[3]?.id)
        XCTAssertNotEqual(result[0]?.id, IDEBlamePresentation.edited.id)
    }

    func testAnEmptyBlameHasNoRows() {
        XCTAssertTrue(annotations([]).isEmpty)
    }
}
