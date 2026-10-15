@preconcurrency import AppKit
import XCTest
@testable import Penumbra

final class TagAutoCloserTests: XCTestCase {
    private let all: TagAutoClosingOptions = [.onStartTagCompletion, .onEndTagSlash]

    private func typeGreaterThan(after before: String,
                                 followedBy after: String = "",
                                 void: Set<String>? = TagAutoCloser.htmlVoidTags,
                                 options: TagAutoClosingOptions? = nil) -> TagAutoCloseEdit? {
        TagAutoCloser.edit(typed: ">", textBefore: before, textAfter: after, options: options ?? all, voidTags: void)
    }

    private func typeSlash(after before: String,
                           void: Set<String>? = TagAutoCloser.htmlVoidTags,
                           options: TagAutoClosingOptions? = nil) -> TagAutoCloseEdit? {
        TagAutoCloser.edit(typed: "/", textBefore: before, textAfter: "", options: options ?? all, voidTags: void)
    }

    // MARK: - Start tag completion

    func testCompletingStartTagInsertsEndTag() {
        XCTAssertEqual(typeGreaterThan(after: "<div"), TagAutoCloseEdit(text: "></div>", caretOffset: 1))
        XCTAssertEqual(typeGreaterThan(after: "<div class=\"a\""), TagAutoCloseEdit(text: "></div>", caretOffset: 1))
    }

    func testCaseOfTheStartTagIsKept() {
        XCTAssertEqual(typeGreaterThan(after: "<Button")?.text, "></Button>")
    }

    func testVoidElementsAreNotClosedInHTML() {
        XCTAssertNil(typeGreaterThan(after: "<br"))
        XCTAssertNil(typeGreaterThan(after: "<IMG src=\"a.png\""))
    }

    func testEveryElementIsClosedInXML() {
        XCTAssertEqual(typeGreaterThan(after: "<item", void: nil)?.text, "></item>")
        XCTAssertEqual(typeGreaterThan(after: "<br", void: nil)?.text, "></br>")
    }

    func testSelfClosingTagIsLeftAlone() {
        XCTAssertNil(typeGreaterThan(after: "<item /", void: nil))
        XCTAssertNil(typeGreaterThan(after: "<item a=\"1\"/", void: nil))
    }

    func testGreaterThanInsideAttributeValueIsLiteral() {
        XCTAssertNil(typeGreaterThan(after: "<a href=\"x"))
        XCTAssertEqual(typeGreaterThan(after: "<a title=\"x>y\"")?.text, "></a>")
    }

    func testNoEndTagWhenOneIsAlreadyThere() {
        XCTAssertNil(typeGreaterThan(after: "<div", followedBy: "</div>"))
    }

    func testTypingInsideAnExistingTagDoesNotClose() {
        XCTAssertNil(typeGreaterThan(after: "<di", followedBy: "v>"))
    }

    func testClosingAfterTextAndOtherMarkup() {
        let before = "<!-- <b> -->\n<ul>\n  <li>one</li>\n  <li"
        XCTAssertEqual(typeGreaterThan(after: before)?.text, "></li>")
    }

    func testNotInsideAComment() {
        XCTAssertNil(typeGreaterThan(after: "<!-- <div"))
    }

    func testOptionOffDoesNothing() {
        XCTAssertNil(typeGreaterThan(after: "<div", options: [.onEndTagSlash]))
        XCTAssertNil(typeSlash(after: "<div>text<", options: [.onStartTagCompletion]))
    }

    // MARK: - End tag slash

    func testSlashCompletesTheInnermostOpenElement() {
        XCTAssertEqual(typeSlash(after: "<div><span>text<"), TagAutoCloseEdit(text: "/span>", caretOffset: 6))
        XCTAssertEqual(typeSlash(after: "<div><span>text</span><")?.text, "/div>")
    }

    func testSlashSkipsVoidAndSelfClosingElements() {
        XCTAssertEqual(typeSlash(after: "<p>a<br>b<img src=\"x\"><")?.text, "/p>")
        XCTAssertEqual(typeSlash(after: "<root><item/><", void: nil)?.text, "/root>")
    }

    func testSlashWithNothingOpenIsTypedAlone() {
        XCTAssertNil(typeSlash(after: "<div></div><"))
        XCTAssertNil(typeSlash(after: "<"))
    }

    func testSlashNeedsAnOpeningAngleBracket() {
        XCTAssertNil(typeSlash(after: "<div>a "))
    }

    func testSlashIgnoresCommentsAndQuotedMarkup() {
        XCTAssertEqual(typeSlash(after: "<a title=\"<b>\"><!-- <i> -->x<")?.text, "/a>")
    }

    func testSlashInsideScriptClosesScript() {
        XCTAssertEqual(typeSlash(after: "<script>\nif (a <b) {}\n<")?.text, "/script>")
    }

    func testHTMLNamesMatchCaseInsensitively() {
        XCTAssertEqual(typeSlash(after: "<DIV><p>x</P><")?.text, "/DIV>")
    }

    func testXMLNamesAreCaseSensitive() {
        // `</A>` closes nothing in XML, so `a` stays open; in HTML it closes `a`.
        XCTAssertEqual(typeSlash(after: "<a>x</A><", void: nil)?.text, "/a>")
        XCTAssertNil(typeSlash(after: "<a>x</A><"))
    }
}

@MainActor
final class TagAutoClosingTextViewTests: XCTestCase {
    private func type(_ strings: [String], into input: String, void: Set<String>? = TagAutoClosingOptions.htmlVoidTagNames) -> String {
        let caret = (input as NSString).range(of: "|").location
        let text = input.replacingOccurrences(of: "|", with: "")
        let textView = makeFocusedTextView(text: text)
        textView.tagAutoClosing = [.onStartTagCompletion, .onEndTagSlash]
        textView.voidTagNames = void
        textView.selectedRange = NSRange(location: caret, length: 0)
        for string in strings {
            textView.insertText(string)
        }
        let result = textView.text as String
        let location = textView.selectedRange.location
        return (result as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: "|")
    }

    func testTypingTheClosingAngleBracketAddsTheEndTagAndKeepsTheCaretBetween() {
        XCTAssertEqual(type([">"], into: "<div class=\"a\"|"), "<div class=\"a\">|</div>")
    }

    func testVoidElementGetsNoEndTag() {
        XCTAssertEqual(type([">"], into: "<br|"), "<br>|")
    }

    func testTypingTextBetweenTheTagsAndThenSlashClosesTheOuterElement() {
        XCTAssertEqual(type(["<", "/"], into: "<ul><li>one</li>|</ul>"), "<ul><li>one</li></ul>|</ul>")
        XCTAssertEqual(type(["<", "/"], into: "<ul><li>one|"), "<ul><li>one</li>|")
    }

    func testIsOneUndoStep() {
        let textView = makeFocusedTextView(text: "<p")
        textView.tagAutoClosing = [.onStartTagCompletion]
        textView.voidTagNames = TagAutoClosingOptions.htmlVoidTagNames
        textView.selectedRange = NSRange(location: 2, length: 0)
        textView.insertText(">")
        XCTAssertEqual(textView.text as String, "<p></p>")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.text as String, "<p")
    }
}
