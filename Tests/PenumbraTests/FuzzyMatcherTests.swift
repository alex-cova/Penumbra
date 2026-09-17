import XCTest
@testable import Penumbra

final class FuzzyMatcherTests: XCTestCase {
    func testExactMatchScoresHigherThanMatchBuriedInTheMiddle() {
        let exact = FuzzyMatcher.match(query: "abc", in: "abc")
        let buried = FuzzyMatcher.match(query: "abc", in: "xxxabcxxx")
        XCTAssertNotNil(exact)
        XCTAssertNotNil(buried)
        XCTAssertGreaterThan(exact!.score, buried!.score)
    }

    func testNoMatchWhenQueryCharactersAreOutOfOrder() {
        XCTAssertNil(FuzzyMatcher.match(query: "cba", in: "abc"))
    }

    func testEmptyQueryMatchesEverythingWithZeroScore() {
        let match = FuzzyMatcher.match(query: "", in: "anything")
        XCTAssertEqual(match, FuzzyMatcher.Match(score: 0, matchedIndices: []))
    }

    func testNoMatchAgainstEmptyCandidate() {
        XCTAssertNil(FuzzyMatcher.match(query: "a", in: ""))
    }

    func testMatchedIndicesPointAtEachMatchedCharacter() {
        let match = FuzzyMatcher.match(query: "ac", in: "abc")
        XCTAssertEqual(match?.matchedIndices, [0, 2])
    }

    func testRankedOrdersByScoreDescendingThenPreservesInputOrderOnTies() {
        let items = ["zzzabc", "abc", "azzbzzc"]
        let ranked = FuzzyMatcher.ranked(query: "abc", items: items, key: { $0 })
        XCTAssertEqual(ranked.first, "abc")
    }

    func testRankedDropsNonMatchingItems() {
        let ranked = FuzzyMatcher.ranked(query: "xyz", items: ["abc", "def"], key: { $0 })
        XCTAssertTrue(ranked.isEmpty)
    }

    func testRankedReturnsPrefixOfItemsWhenQueryIsBlank() {
        let ranked = FuzzyMatcher.ranked(query: "  ", items: ["a", "b", "c"], key: { $0 }, limit: 2)
        XCTAssertEqual(ranked, ["a", "b"])
    }

    func testRankedRespectsLimit() {
        let items = (0 ..< 10).map { "match\($0)" }
        let ranked = FuzzyMatcher.ranked(query: "match", items: items, key: { $0 }, limit: 3)
        XCTAssertEqual(ranked.count, 3)
    }

    func testRankedWithMatchesReturnsMatchedIndicesPerItem() {
        let items = ["Reformat Code", "Reindent Lines", "Toggle Find Panel"]
        let ranked = FuzzyMatcher.rankedWithMatches(query: "rc", items: items, key: { $0 }, limit: 10)
        XCTAssertEqual(ranked.first?.item, "Reformat Code")
        XCTAssertEqual(ranked.first?.match.matchedIndices, [0, 9]) // R…C
        XCTAssertFalse(ranked.contains { $0.item == "Toggle Find Panel" })
    }

    func testRankedWithMatchesBlankQueryReturnsPrefixWithEmptyMatches() {
        let ranked = FuzzyMatcher.rankedWithMatches(query: "", items: ["a", "b", "c"], key: { $0 }, limit: 2)
        XCTAssertEqual(ranked.map(\.item), ["a", "b"])
        XCTAssertTrue(ranked.allSatisfy { $0.match.matchedIndices.isEmpty })
    }
}
