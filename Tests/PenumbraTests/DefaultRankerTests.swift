import XCTest
import EditorIntelligence

final class DefaultRankerTests: XCTestCase {
    func testExactMatchScoresHighest() async {
        let ranker = DefaultRanker()
        let context = makeContext(prefix: "foo")
        let exact = makeItem(label: "foo", kind: .variable, source: "Symbol")
        let prefix = makeItem(label: "foobar", kind: .variable, source: "Symbol")
        let fuzzy = makeItem(label: "fxoo", kind: .variable, source: "Symbol")
        let ranked = await ranker.rank(items: [fuzzy, prefix, exact], context: context)
        XCTAssertEqual(ranked.map(\.item.label), ["foo", "foobar", "fxoo"])
    }

    func testCaseInsensitivePrefixMatch() async throws {
        let ranker = DefaultRanker()
        let context = makeContext(prefix: "FOO")
        let item = makeItem(label: "foo", kind: .variable, source: "Symbol")
        let ranked = await ranker.rank(items: [item], context: context)
        let score = try XCTUnwrap(ranked.first?.score)
        XCTAssertEqual(score, 0.95 + providerAndKindBonus(item: item), accuracy: 0.001)
    }

    func testCamelCaseMatch() async {
        let ranker = DefaultRanker()
        let context = makeContext(prefix: "GB")
        let item = makeItem(label: "getBar", kind: .method, source: "Symbol")
        let ranked = await ranker.rank(items: [item], context: context)
        XCTAssertEqual(ranked.first?.item.label, "getBar")
    }

    func testFuzzyMatchScoresLowerThanPrefix() async {
        let ranker = DefaultRanker()
        let context = makeContext(prefix: "fo")
        let prefix = makeItem(label: "foo", kind: .variable, source: "Symbol")
        let fuzzy = makeItem(label: "fxoo", kind: .variable, source: "Symbol")
        let ranked = await ranker.rank(items: [fuzzy, prefix], context: context)
        XCTAssertEqual(ranked.map(\.item.label), ["foo", "fxoo"])
    }

    func testProviderAndKindWeights() async {
        let ranker = DefaultRanker()
        let context = makeContext(prefix: "f")
        let function = makeItem(label: "foo", kind: .function, source: "Symbol")
        let word = makeItem(label: "foo", kind: .text, source: "Word")
        let ranked = await ranker.rank(items: [word, function], context: context)
        XCTAssertEqual(ranked.first?.item.source, "Symbol")
    }
}

private func makeContext(prefix: String) -> CompletionContext {
    let snapshot = TextSnapshot(version: 0, text: "\(prefix)")
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

private func makeItem(label: String, kind: CompletionItemKind, source: String) -> CompletionItem {
    let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
    return CompletionItem(
        label: label,
        insertText: label,
        kind: kind,
        range: TextRange(start: position, end: position),
        source: source
    )
}

private func providerAndKindBonus(item: CompletionItem) -> Double {
    var bonus: Double = 0
    switch item.source {
    case "Symbol": bonus += 0.3
    case "Snippet": bonus += 0.2
    case "Word": bonus += 0.1
    default: break
    }
    switch item.kind {
    case .function, .method: bonus += 0.2
    case .type: bonus += 0.15
    case .property, .variable: bonus += 0.1
    case .snippet: bonus += 0.05
    case .keyword: bonus += 0.04
    case .text: bonus += 0.0
    case .module, .file: bonus += 0.05
    }
    return bonus
}