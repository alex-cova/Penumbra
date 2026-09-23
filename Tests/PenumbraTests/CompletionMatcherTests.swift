import XCTest
import EditorIntelligence

final class CompletionMatcherTests: XCTestCase {
    private func tier(_ query: String, _ candidate: String) -> CompletionMatcher.Tier? {
        CompletionMatcher.match(query, in: candidate)?.tier
    }

    func testTiers() {
        XCTAssertEqual(tier("", "anything"), .any)
        XCTAssertEqual(tier("getName", "getName"), .exact)
        XCTAssertEqual(tier("getname", "getName"), .exactIgnoringCase)
        XCTAssertEqual(tier("getN", "getName"), .prefix)
        XCTAssertEqual(tier("GETN", "getName"), .prefix)
        XCTAssertEqual(tier("gN", "getName"), .camelHump)
        XCTAssertEqual(tier("Name", "getName"), .wordStart)
    }

    func testCamelHumpVariants() {
        XCTAssertEqual(tier("ArrLi", "ArrayList"), .camelHump)
        XCTAssertEqual(tier("aL", "ArrayList"), .camelHump)
        XCTAssertEqual(tier("AL", "ArrayList"), .camelHump)
        XCTAssertEqual(tier("NPE", "NullPointerException"), .camelHump)
        XCTAssertEqual(tier("URLC", "URLConnection"), .prefix)
        XCTAssertEqual(tier("UC", "URLConnection"), .camelHump)
        XCTAssertEqual(tier("tSt", "toString"), .camelHump)
        XCTAssertEqual(tier("mv", "MAX_VALUE"), .camelHump)
    }

    func testNonMatches() {
        XCTAssertNil(tier("xyz", "getName"))
        XCTAssertNil(tier("ame", "getName"), "arbitrary substrings don't match")
        XCTAssertNil(tier("LA", "ArrayList"), "humps must stay in order")
        XCTAssertNil(tier("getNames", "getName"))
    }

    func testMatchedRangesForHighlighting() {
        let match = CompletionMatcher.match("gNa", in: "getName")
        XCTAssertEqual(match?.matchedRanges, [NSRange(location: 0, length: 1), NSRange(location: 3, length: 2)])
        XCTAssertEqual(CompletionMatcher.match("get", in: "getName")?.matchedRanges, [NSRange(location: 0, length: 3)])
    }

    func testFirstCharacterCase() {
        XCTAssertEqual(CompletionMatcher.match("str", in: "String")?.firstCharacterCaseMatches, false)
        XCTAssertEqual(CompletionMatcher.match("Str", in: "String")?.firstCharacterCaseMatches, true)
    }
}
