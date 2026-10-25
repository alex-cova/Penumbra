import XCTest
import EditorIntelligence

final class HoverEngineTests: XCTestCase {
    func testReturnsFirstProviderResult() async {
        let first = MockHoverProvider(name: "First", result: HoverResult(contents: "first", source: "First"))
        let second = MockHoverProvider(name: "Second", result: HoverResult(contents: "second", source: "Second"))
        let engine = HoverEngine(providers: [first, second])
        let context = makeHoverContext(text: "foo", offset: 0)
        let result = await engine.hover(context: context)
        XCTAssertEqual(result?.contents, "first")
    }

    func testReturnsNilWhenNoProviderMatches() async {
        let engine = HoverEngine(providers: [])
        let context = makeHoverContext(text: "foo", offset: 0)
        let result = await engine.hover(context: context)
        XCTAssertNil(result)
    }

    func testCachesResult() async {
        let provider = MockHoverProvider(name: "Counted", result: HoverResult(contents: "cached", source: "Counted"))
        let engine = HoverEngine(providers: [provider], cacheMaxSize: 100)
        let context = makeHoverContext(text: "foo", offset: 0)
        _ = await engine.hover(context: context)
        _ = await engine.hover(context: context)
        let count = await provider.callCount
        XCTAssertEqual(count, 1)
    }

    func testCacheEvictsLeastRecentlyUsed() async {
        let provider = MockHoverProvider(name: "Counted", result: HoverResult(contents: "cached", source: "Counted"))
        let engine = HoverEngine(providers: [provider], cacheMaxSize: 2)
        let documentID = DocumentID()
        _ = await engine.hover(context: makeHoverContext(text: "foo", offset: 0, documentID: documentID))
        _ = await engine.hover(context: makeHoverContext(text: "foo", offset: 1, documentID: documentID))
        _ = await engine.hover(context: makeHoverContext(text: "foo", offset: 0, documentID: documentID))
        _ = await engine.hover(context: makeHoverContext(text: "foo", offset: 2, documentID: documentID))
        _ = await engine.hover(context: makeHoverContext(text: "foo", offset: 0, documentID: documentID))
        _ = await engine.hover(context: makeHoverContext(text: "foo", offset: 1, documentID: documentID))
        let count = await provider.callCount
        XCTAssertEqual(count, 4)
    }
}

private actor MockHoverProvider: HoverProvider {
    let name: String
    let result: HoverResult?
    var callCount = 0

    init(name: String, result: HoverResult?) {
        self.name = name
        self.result = result
    }

    func provide(context: HoverContext) async -> HoverResult? {
        callCount += 1
        return result
    }
}

private func makeHoverContext(text: String, offset: Int, documentID: DocumentID = DocumentID()) -> HoverContext {
    let snapshot = TextSnapshot(version: 0, text: text)
    let position = TextPosition(line: 0, column: offset, utf16Offset: offset)
    let document = Document(
        id: documentID,
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
