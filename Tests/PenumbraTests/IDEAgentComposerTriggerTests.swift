import Foundation
import XCTest

@testable import Umbra

final class IDEAgentComposerTriggerTests: XCTestCase {
    private func detect(_ text: String, caret: Int? = nil) -> IDEAgentComposerTrigger {
        IDEAgentComposerTrigger.detect(in: text, caret: caret ?? (text as NSString).length)
    }

    func testASlashAtTheStartOpensTheCommandList() {
        XCTAssertEqual(detect("/"), .slash(query: "", range: NSRange(location: 0, length: 1)))
        XCTAssertEqual(detect("/res"), .slash(query: "res", range: NSRange(location: 0, length: 4)))
    }

    func testTheCommandListClosesOnceTheCommandHasArguments() {
        XCTAssertEqual(detect("/resume foo"), .none)
        XCTAssertEqual(detect("/resume "), .none)
        XCTAssertEqual(
            detect("/resume foo", caret: 4), .slash(query: "res", range: NSRange(location: 0, length: 4)),
            "a caret back inside the command name reopens it")
    }

    func testASlashLaterInTheMessageIsNotACommand() {
        XCTAssertEqual(detect("look at src/main"), .none)
        XCTAssertEqual(detect("hello /resume"), .none)
        XCTAssertEqual(detect("first line\n/resume"), .none, "only the message's first word")
    }

    func testAnAtAfterWhitespaceOpensTheMentionList() {
        XCTAssertEqual(detect("look at @"), .mention(query: "", range: NSRange(location: 8, length: 1)))
        XCTAssertEqual(detect("look at @Panel"), .mention(query: "Panel", range: NSRange(location: 8, length: 6)))
        XCTAssertEqual(detect("@Panel"), .mention(query: "Panel", range: NSRange(location: 0, length: 6)))
        XCTAssertEqual(detect("a\n@x"), .mention(query: "x", range: NSRange(location: 2, length: 2)))
    }

    func testPathsStayInsideOneMention() {
        XCTAssertEqual(
            detect("see @Example/Umbra/Agent/IDE"),
            .mention(query: "Example/Umbra/Agent/IDE", range: NSRange(location: 4, length: 24)))
    }

    func testAnAtInsideAWordIsNotAMention() {
        XCTAssertEqual(detect("mail me@example.com"), .none)
    }

    func testAMentionClosesOnceTheCaretMovesPastIt() {
        XCTAssertEqual(detect("@Panel and more"), .none)
        XCTAssertEqual(detect("@Panel and more", caret: 3), .mention(query: "Pa", range: NSRange(location: 0, length: 3)))
    }

    func testPlainTextAndOutOfRangeCaretsAreNothing() {
        XCTAssertEqual(detect(""), .none)
        XCTAssertEqual(detect("hello"), .none)
        XCTAssertEqual(IDEAgentComposerTrigger.detect(in: "hi", caret: 9), .none)
        XCTAssertEqual(IDEAgentComposerTrigger.detect(in: "hi", caret: -1), .none)
    }

    func testEmojiBeforeTheTriggerKeepsUTF16OffsetsRight() {
        let text = "👍 @fi"
        XCTAssertEqual(detect(text), .mention(query: "fi", range: NSRange(location: 3, length: 3)))
    }

    func testAcceptingASuggestionReplacesTheWordAndPlacesTheCaretAfterIt() {
        let text = "read @Pan please"
        let trigger = IDEAgentComposerTrigger.detect(in: text, caret: 9)
        guard case .mention(_, let range) = trigger else { return XCTFail("expected a mention, got \(trigger)") }

        let result = IDEAgentComposerTrigger.apply("@Panel.swift ", replacing: range, in: text)
        XCTAssertEqual(result.text, "read @Panel.swift  please")
        XCTAssertEqual(result.caret, 5 + 13)
    }

    func testScanFindsMentionsAndIgnoresEmailsAndTrailingPunctuation() {
        let tokens = IDEAgentMentionToken.scan("Fix @A.java, then @src/B.java. Mail me@x.com or @ alone")
        XCTAssertEqual(tokens.map(\.text), ["A.java", "src/B.java"])
        XCTAssertEqual(tokens.map(\.range), [NSRange(location: 4, length: 7), NSRange(location: 18, length: 11)])
    }

    func testScanHandlesAMentionAtTheStartAndSpecialNames() {
        XCTAssertEqual(IDEAgentMentionToken.scan("@selection explain").map(\.text), ["selection"])
        XCTAssertEqual(IDEAgentMentionToken.scan("use @skill:review now").map(\.text), ["skill:review"])
        XCTAssertTrue(IDEAgentMentionToken.scan("nothing here").isEmpty)
        XCTAssertTrue(IDEAgentMentionToken.scan("").isEmpty)
    }

    func testAQuotedMentionNamesAPathWithSpaces() {
        let tokens = IDEAgentMentionToken.scan("open @\"My Notes/a b.md\" and @C.java")
        XCTAssertEqual(tokens.map(\.text), ["My Notes/a b.md", "C.java"])
        XCTAssertEqual(tokens[0].range, NSRange(location: 5, length: 18))
    }

    func testAnUnclosedOrEmptyQuoteIsAPlainWord() {
        XCTAssertEqual(IDEAgentMentionToken.scan("see @\"unclosed path").map(\.text), ["\"unclosed"])
        XCTAssertEqual(IDEAgentMentionToken.scan("see @\"\"").map(\.text), ["\"\""])
        XCTAssertEqual(IDEAgentMentionToken.scan("a @\"x\ny\"").map(\.text), ["\"x"], "a quote does not span lines")
    }

    func testFormatQuotesOnlyWhenNeeded() {
        XCTAssertEqual(IDEAgentMentionToken.format(path: "src/A.java"), "@src/A.java")
        XCTAssertEqual(IDEAgentMentionToken.format(path: "My Notes/a.md"), "@\"My Notes/a.md\"")
    }

    func testRelativePathsAreProjectRelativeOnlyInsideTheProject() {
        let root = URL(fileURLWithPath: "/work/proj")
        XCTAssertEqual(IDEAgentMentionPath.relative(URL(fileURLWithPath: "/work/proj/src/A.java"), root: root), "src/A.java")
        XCTAssertEqual(IDEAgentMentionPath.relative(URL(fileURLWithPath: "/work/project2/A.java"), root: root), "/work/project2/A.java")
        XCTAssertEqual(IDEAgentMentionPath.relative(URL(fileURLWithPath: "/x/A.java"), root: nil), "/x/A.java")
    }
}
