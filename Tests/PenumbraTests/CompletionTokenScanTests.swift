import EditorIntelligence
import XCTest

final class CompletionTokenScanTests: XCTestCase {
    func testDotEndsAnOrdinaryIdentifier() {
        let text = "foo.bar"
        XCTAssertEqual(CompletionTokenScan.tokenStart(utf16Text: text, caret: (text as NSString).length), 4)
        XCTAssertFalse(CompletionTokenScan.opensTemplate(utf16Text: text, tokenStart: 4))
        XCTAssertEqual(CompletionTokenScan.suffixLength(utf16Text: "uuid", template: false), 4)
        XCTAssertEqual(CompletionTokenScan.suffixLength(utf16Text: ".uuid", template: false), 0)
    }

    func testTemplateKeepsDotsAndANameWithoutADot() {
        let dotted = "{{$random.uuid"
        let start = CompletionTokenScan.tokenStart(utf16Text: dotted, caret: (dotted as NSString).length)
        XCTAssertEqual((dotted as NSString).substring(from: start), "$random.uuid")
        XCTAssertTrue(CompletionTokenScan.opensTemplate(utf16Text: dotted, tokenStart: start))
        XCTAssertEqual(CompletionTokenScan.suffixLength(utf16Text: ".uuid}}", template: true), 5)

        let plain = "{{host"
        let plainStart = CompletionTokenScan.tokenStart(utf16Text: plain, caret: (plain as NSString).length)
        XCTAssertEqual((plain as NSString).substring(from: plainStart), "host")
        XCTAssertTrue(CompletionTokenScan.opensTemplate(utf16Text: plain, tokenStart: plainStart))

        let spaced = "{{ $random.u"
        let spacedStart = CompletionTokenScan.tokenStart(utf16Text: spaced, caret: (spaced as NSString).length)
        XCTAssertEqual((spaced as NSString).substring(from: spacedStart), "$random.u")
    }

    func testCompletionContextUsesTheTemplateToken() {
        let dotted = "{{$random.u"
        let dottedContext = makeContext(dotted)
        XCTAssertEqual(dottedContext.prefix, "$random.u")
        XCTAssertFalse(dottedContext.isMemberAccess)

        let member = makeContext("a.f")
        XCTAssertEqual(member.prefix, "f")
        XCTAssertTrue(member.isMemberAccess)
    }

    private func makeContext(_ text: String) -> CompletionContext {
        let offset = (text as NSString).length
        let position = TextPosition(line: 0, column: offset, utf16Offset: offset)
        let document = Document(
            id: DocumentID(),
            url: nil,
            displayName: "test",
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100)
        )
        return makeCompletionContext(document: document, trigger: .manual)
    }
}
