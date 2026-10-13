import Foundation
import XCTest
@testable import Umbra

final class HTTPSemanticTokenTests: XCTestCase {
    func testTemplateInABodyIsSplitIntoBracketsAndName() {
        let text = "POST https://x.test/a\n\n{\"id\": {{ userId }}}\n"
        let tokens = HTTPSemanticTokens.highlights(in: text)
        XCTAssertEqual(tokens.map(\.highlightName), ["punctuation.bracket", "variable", "punctuation.bracket"])
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: nsRange(tokens[0].range)), "{{")
        XCTAssertEqual(ns.substring(with: nsRange(tokens[1].range)), "userId")
        XCTAssertEqual(ns.substring(with: nsRange(tokens[2].range)), "}}")
    }

    func testDynamicVariableIsAFunction() {
        let tokens = HTTPSemanticTokens.highlights(in: "GET https://x.test/{{$uuid}}\n")
        XCTAssertEqual(tokens.map(\.highlightName), ["punctuation.bracket", "function.builtin", "punctuation.bracket"])
    }

    func testUnclosedAndBraceyTemplatesAreLeftAlone() {
        XCTAssertTrue(HTTPSemanticTokens.highlights(in: "{\"a\": {{id}\n").isEmpty)
        XCTAssertTrue(HTTPSemanticTokens.highlights(in: "{\"a\": {\"b\": 1}}\n").isEmpty)
        XCTAssertTrue(HTTPSemanticTokens.highlights(in: "query { a { b } }\n").isEmpty)
    }

    func testCommentLinesAreNotScanned() {
        XCTAssertTrue(HTTPSemanticTokens.highlights(in: "# uses {{id}}\n// and {{id}}\n").isEmpty)
    }

    func testSchemeDirectiveSplitsKeywordFromURL() {
        let text = "###@scheme:https://api.test/graphql\nGRAPHQL https://api.test/graphql\n"
        let tokens = HTTPSemanticTokens.highlights(in: text)
        XCTAssertEqual(tokens.map(\.highlightName), ["keyword", "string.special.url"])
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: nsRange(tokens[0].range)), "@scheme")
        XCTAssertEqual(ns.substring(with: nsRange(tokens[1].range)), "https://api.test/graphql")
    }

    func testTemplateInsideTheDirectiveURL() {
        let tokens = HTTPSemanticTokens.highlights(in: "### @scheme: {{host}}/schema.graphql\n")
        XCTAssertEqual(
            tokens.map(\.highlightName),
            ["keyword", "string.special.url", "punctuation.bracket", "variable", "punctuation.bracket"]
        )
    }

    func testOffsetsAreUTF16AfterNonBMPText() {
        let text = "# 😀\nGET https://x.test/{{a}}\n"
        let tokens = HTTPSemanticTokens.highlights(in: text)
        XCTAssertEqual((text as NSString).substring(with: nsRange(tokens[1].range)), "a")
    }

    func testCRLFLines() {
        let text = "###@scheme:https://api.test/s.graphql\r\nGET https://x.test/{{a}}\r\n"
        let tokens = HTTPSemanticTokens.highlights(in: text)
        XCTAssertEqual(tokens.count, 5)
        XCTAssertEqual((text as NSString).substring(with: nsRange(tokens[1].range)), "https://api.test/s.graphql")
    }

    // MARK: - Directive

    func testDirectiveInEffectIsTheNearestOneAbove() {
        let text = """
        ###@scheme:https://one.test/graphql
        GRAPHQL https://one.test/graphql

        { a }

        ###@scheme:https://two.test/graphql
        GRAPHQL https://two.test/graphql

        { b }
        """
        let first = (text as NSString).range(of: "{ a }").location
        let second = (text as NSString).range(of: "{ b }").location
        XCTAssertEqual(HTTPGraphQLDirective.directive(in: text, caretUTF16: first)?.url, "https://one.test/graphql")
        XCTAssertEqual(HTTPGraphQLDirective.directive(in: text, caretUTF16: second)?.url, "https://two.test/graphql")
        XCTAssertEqual(HTTPGraphQLDirective.directives(in: text).count, 2)
    }

    func testNoDirectiveAboveTheCaret() {
        let text = "GRAPHQL https://x.test\n\n{ a }\n###@scheme:https://later.test/s.graphql\n"
        XCTAssertNil(HTTPGraphQLDirective.directive(in: text, caretUTF16: 10))
        XCTAssertNil(HTTPGraphQLDirective.directive(in: "", caretUTF16: 0))
    }

    func testOrdinarySeparatorsAndMalformedDirectivesAreNotDirectives() {
        for line in ["### Create user", "##@scheme:https://x.test", "###@scheme", "###@scheme:", "###@schemes:https://x.test", "@scheme:https://x.test"] {
            XCTAssertTrue(HTTPGraphQLDirective.directives(in: line + "\n").isEmpty, line)
        }
    }

    private func nsRange(_ range: Range<Int>) -> NSRange {
        NSRange(location: range.lowerBound, length: range.count)
    }
}
