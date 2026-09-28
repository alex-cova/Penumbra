import XCTest
@testable import Penumbra

final class BracketNavigationTests: XCTestCase {
    private func target(_ text: String, caret: Int) -> Int? {
        BracketNavigation.target(from: caret, in: text as NSString, windowStart: 0)
    }

    func testCaretAfterClosingBracketLandsAfterOpeningBracket() {
        XCTAssertEqual(target("foo(bar)", caret: 8), 4)
    }

    func testCaretAfterOpeningBracketLandsAfterClosingBracket() {
        XCTAssertEqual(target("foo(bar)", caret: 4), 8)
    }

    func testCaretBeforeOpeningBracketLandsBeforeClosingBracket() {
        XCTAssertEqual(target("foo(bar)", caret: 3), 7)
    }

    func testCaretBeforeClosingBracketLandsBeforeOpeningBracket() {
        XCTAssertEqual(target("foo(bar)", caret: 7), 3)
    }

    func testPressingTwiceReturnsToTheStart() {
        let first = target("foo(bar)", caret: 8)
        XCTAssertEqual(first.flatMap { target("foo(bar)", caret: $0) }, 8)
    }

    func testNestedBracketsMatchTheirOwnPartner() {
        // a ( b ( c ) d )
        // 0 1 2 3 4 5 6 7
        XCTAssertEqual(target("a(b(c)d)", caret: 6), 4, "after the inner ) → after the inner (")
        XCTAssertEqual(target("a(b(c)d)", caret: 8), 2, "after the outer ) → after the outer (")
    }

    func testDifferentBracketKindsDoNotCountAsNesting() {
        // { [ ( x ) ] }
        let text = "{[(x)]}"
        XCTAssertEqual(target(text, caret: 7), 1, "after } → after {")
        XCTAssertEqual(target(text, caret: 6), 2, "after ] → after [")
    }

    func testCaretInsideABlockMovesAfterTheEnclosingOpeningBracket() {
        XCTAssertEqual(target("x(ab cd)", caret: 4), 2)
    }

    func testEnclosingSearchSkipsBalancedPairs() {
        // caret after "(b)" inside the braces: the enclosing bracket is {, not (.
        XCTAssertEqual(target("{a (b) c}", caret: 7), 1)
    }

    func testNoBracketsMeansNoTarget() {
        XCTAssertNil(target("abc", caret: 2))
    }

    func testUnbalancedOpeningBracketStaysPut() {
        // Nothing balances the "(", so the enclosing search lands right after it, where the caret is.
        XCTAssertEqual(target("foo(", caret: 4), 4)
    }

    func testQuotesAreNotBrackets() {
        XCTAssertNil(target("\"abc\"", caret: 5))
    }

    func testMatchingBeyondTheSearchWindowIsNotFound() {
        let text = "(" + String(repeating: "x", count: BracketNavigation.searchLimit + 100) + ")"
        let length = (text as NSString).length
        let found = BracketNavigation.target(from: length, documentLength: length) { range in
            (text as NSString).substring(with: range)
        }
        XCTAssertNil(found, "The partner is farther than the bounded window")
    }

    func testWindowOffsetIsAppliedToTheResult() {
        let text = "foo(bar)"
        let found = BracketNavigation.target(from: 8, documentLength: 8) { range in
            (text as NSString).substring(with: range)
        }
        XCTAssertEqual(found, 4)
        // The same text embedded far into a larger document: locations stay absolute.
        let padded = String(repeating: " ", count: 10_000) + text
        let length = (padded as NSString).length
        let paddedFound = BracketNavigation.target(from: length, documentLength: length) { range in
            (padded as NSString).substring(with: range)
        }
        XCTAssertEqual(paddedFound, 10_004)
    }
}
