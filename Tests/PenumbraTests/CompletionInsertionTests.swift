import EditorIntelligence
import XCTest

/// `CompletionInsertion.resolve`: what is written depends on what already follows the caret.
final class CompletionInsertionTests: XCTestCase {
    private func item(_ label: String, _ insert: String, _ kind: CompletionItemKind, snippet: Bool = false, caret: Int? = nil) -> CompletionItem {
        let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return CompletionItem(
            label: label, insertText: insert, kind: kind,
            range: EditorIntelligence.TextRange(start: origin, end: origin), source: "test",
            insertTextIsSnippet: snippet, caretOffset: caret
        )
    }

    func testMethodDropsParenthesesWhenOneFollows() {
        let method = item("length", "length()", .method)
        XCTAssertEqual(CompletionInsertion.resolve(method, nextCharacter: "(").text, "length")
        XCTAssertEqual(CompletionInsertion.resolve(method, nextCharacter: "(").caretOffset, 7)
        XCTAssertEqual(CompletionInsertion.resolve(method, nextCharacter: " ").text, "length()")
        XCTAssertEqual(CompletionInsertion.resolve(method, nextCharacter: nil).text, "length()")
    }

    func testConstructorKeepsOnlyTheNameBeforeExistingTypeArguments() {
        let diamond = item("ArrayList", "ArrayList<>()", .class)
        XCTAssertEqual(CompletionInsertion.resolve(diamond, nextCharacter: "<").text, "ArrayList")
        XCTAssertEqual(CompletionInsertion.resolve(diamond, nextCharacter: "(").text, "ArrayList<>")
        XCTAssertEqual(CompletionInsertion.resolve(diamond, nextCharacter: " ").text, "ArrayList<>()")
    }

    func testAnonymousClassSnippetIsReducedToThePlainNameBeforeExistingText() {
        let anonymous = item("Runnable", "Runnable() {\n    $0\n}", .interface, snippet: true)
        for next in ["(", "<"] {
            let resolved = CompletionInsertion.resolve(anonymous, nextCharacter: next)
            XCTAssertEqual(resolved.text, "Runnable")
            XCTAssertFalse(resolved.isSnippet)
        }
        // Before an existing `(` the caret steps into it, as for every other constructor.
        XCTAssertEqual(CompletionInsertion.resolve(anonymous, nextCharacter: "(").caretOffset, 9)
        XCTAssertNil(CompletionInsertion.resolve(anonymous, nextCharacter: "<").caretOffset)
        XCTAssertTrue(CompletionInsertion.resolve(anonymous, nextCharacter: " ").isSnippet)
    }

    func testPlainConstructorStepsIntoExistingParentheses() {
        let plain = item("Thread", "Thread()", .class)
        let resolved = CompletionInsertion.resolve(plain, nextCharacter: "(")
        XCTAssertEqual(resolved.text, "Thread")
        XCTAssertEqual(resolved.caretOffset, 7, "the caret goes inside the parentheses already written")
    }

    func testCastItemDoesNotDuplicateTheClosingParenthesis() {
        let cast = item("Number", "Number) ", .class)
        XCTAssertEqual(CompletionInsertion.resolve(cast, nextCharacter: ")").text, "Number")
        XCTAssertEqual(CompletionInsertion.resolve(cast, nextCharacter: " ").text, "Number) ")
    }

    func testAnnotationAttributeDoesNotDuplicateAnExistingEquals() {
        let attribute = item("using", "using = ", .method)
        XCTAssertEqual(CompletionInsertion.resolve(attribute, nextCharacter: " ", following: " = Foo.class)").text, "using")
        XCTAssertEqual(CompletionInsertion.resolve(attribute, nextCharacter: "=", following: "= 1)").text, "using")
        XCTAssertEqual(CompletionInsertion.resolve(attribute, nextCharacter: ")", following: ")").text, "using = ")
        XCTAssertEqual(CompletionInsertion.resolve(attribute, nextCharacter: nil).text, "using = ")
    }

    func testPlainFieldIsUntouched() {
        let field = item("size", "size", .field)
        XCTAssertEqual(CompletionInsertion.resolve(field, nextCharacter: "(").text, "size")
    }
}
