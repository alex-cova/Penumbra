import XCTest
import EditorIntelligence

final class AITests: XCTestCase {
    func testAICompletionProvider() async {
        let model = MockAITextModel { _ in "helloWorld" }
        let provider = AICompletionProvider(model: model)
        let context = makeCompletionContext(prefix: "he")
        let items = await provider.provide(context: context)
        XCTAssertEqual(items.first?.insertText, "helloWorld")
        XCTAssertEqual(items.first?.source, "AI")
    }

    func testAIHoverProvider() async {
        let model = MockAITextModel { _ in "An explanation." }
        let provider = AIHoverProvider(model: model)
        let context = makeHoverContext(text: "foo", offset: 0)
        let result = await provider.provide(context: context)
        XCTAssertEqual(result?.contents, "An explanation.")
        XCTAssertEqual(result?.source, "AI")
    }

    func testAIProviderReturnsEmptyOnError() async {
        let model = MockAITextModel { _ in throw TestError.intentional }
        let provider = AICompletionProvider(model: model)
        let context = makeCompletionContext(prefix: "he")
        let items = await provider.provide(context: context)
        XCTAssertTrue(items.isEmpty)
    }
}

private struct TestError: Error {
    static let intentional = TestError()
}

private struct MockAITextModel: AITextModel {
    let generator: @Sendable (String) throws -> String

    func generate(prompt: String) async throws -> String {
        try generator(prompt)
    }
}

private func makeCompletionContext(prefix: String) -> CompletionContext {
    let snapshot = TextSnapshot(version: 0, text: prefix)
    let position = TextPosition(line: 0, column: prefix.count, utf16Offset: prefix.count)
    let document = Document(
        id: DocumentID(),
        url: nil,
        displayName: "test",
        contentSnapshot: snapshot,
        selection: Selection(range: TextRange(start: position, end: position)),
        cursor: Cursor(position: position),
        viewport: Viewport(x: 0, y: 0, width: 100, height: 100)
    )
    return CompletionContext(
        document: document,
        cursor: Cursor(position: position),
        trigger: .keystroke(prefix),
        prefix: prefix,
        range: TextRange(start: position, end: position)
    )
}

private func makeHoverContext(text: String, offset: Int) -> HoverContext {
    let snapshot = TextSnapshot(version: 0, text: text)
    let position = TextPosition(line: 0, column: offset, utf16Offset: offset)
    let document = Document(
        id: DocumentID(),
        url: nil,
        displayName: "test",
        contentSnapshot: snapshot,
        selection: Selection(range: TextRange(start: position, end: position)),
        cursor: Cursor(position: position),
        viewport: Viewport(x: 0, y: 0, width: 100, height: 100)
    )
    return HoverContext(
        document: document,
        cursor: Cursor(position: position),
        selection: Selection(range: TextRange(start: position, end: position))
    )
}