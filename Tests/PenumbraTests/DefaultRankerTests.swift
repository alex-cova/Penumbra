import XCTest
import EditorIntelligence

final class DefaultRankerTests: XCTestCase {
    func testMatchTiersOrderExactThenPrefixThenCamelHumpThenWordStart() async {
        let ranker = DefaultRanker()
        let context = makeContext(prefix: "getN")
        let items = [
            makeItem(label: "targetName", kind: .variable, source: "Symbol"), // no word-start match for "getN"
            makeItem(label: "getNumberOfThings", kind: .method, source: "Symbol"),
            makeItem(label: "getName", kind: .method, source: "Symbol"),
            makeItem(label: "getN", kind: .method, source: "Symbol"),
            makeItem(label: "gettingNear", kind: .method, source: "Symbol") // camel hump: get + N
        ]
        let ranked = await ranker.rank(items: items, context: context)
        XCTAssertEqual(ranked.map(\.item.label), ["getN", "getName", "getNumberOfThings", "gettingNear"])
    }

    func testCamelHumpMatchesLowercaseAndMixedQueries() async {
        let ranker = DefaultRanker()
        for query in ["gN", "gn", "getNa"] {
            let ranked = await ranker.rank(items: [makeItem(label: "getName", kind: .method, source: "Java")], context: makeContext(prefix: query))
            XCTAssertEqual(ranked.first?.item.label, "getName", "query \(query)")
        }
    }

    func testNonMatchingItemsAreDropped() async {
        let ranker = DefaultRanker()
        let ranked = await ranker.rank(
            items: [makeItem(label: "foo", kind: .variable, source: "Symbol"), makeItem(label: "fxoo", kind: .variable, source: "Symbol")],
            context: makeContext(prefix: "fo")
        )
        XCTAssertEqual(ranked.map(\.item.label), ["foo"])
    }

    func testPriorityOrdersWithinTierButNotAcrossTiers() async {
        let ranker = DefaultRanker()
        let local = makeItem(label: "value", kind: .variable, source: "Java", priority: 3)
        let inherited = makeItem(label: "valueOf", kind: .method, source: "Java", priority: 1)
        let objectMember = makeItem(label: "values", kind: .method, source: "Java", priority: 0)
        let exactLowPriority = makeItem(label: "val", kind: .keyword, source: "Java", priority: -2)
        let ranked = await ranker.rank(items: [objectMember, inherited, local, exactLowPriority], context: makeContext(prefix: "val"))
        XCTAssertEqual(ranked.map(\.item.label), ["val", "value", "valueOf", "values"])
    }

    func testEqualScoresBreakTiesByLengthThenAlphabetically() async {
        let ranker = DefaultRanker()
        let items = ["beta", "alpha", "al"].map { makeItem(label: $0, kind: .variable, source: "Java") }
        let ranked = await ranker.rank(items: items, context: makeContext(prefix: ""))
        XCTAssertEqual(ranked.map(\.item.label), ["al", "beta", "alpha"])
    }

    func testRecentlyAcceptedItemRanksFirstAmongEquals() async {
        let recency = CompletionRecency()
        let ranker = DefaultRanker(recency: recency)
        let first = makeItem(label: "fooA", kind: .method, source: "Java")
        let second = makeItem(label: "fooB", kind: .method, source: "Java")
        recency.record(second)
        let ranked = await ranker.rank(items: [first, second], context: makeContext(prefix: "foo"))
        XCTAssertEqual(ranked.first?.item.label, "fooB")
    }

    /// F-17: same-score items from one provider follow the provider's own order instead of
    /// length/alphabetical — that is what a language server's `sortText` is for.
    func testSortTextOrdersSameSourceTies() async {
        let ranker = DefaultRanker()
        let items = [
            makeItem(label: "printf", kind: .method, source: "LSP", sortText: "2"),
            makeItem(label: "printx", kind: .method, source: "LSP", sortText: "1"),
        ]
        let ranked = await ranker.rank(items: items, context: makeContext(prefix: "print"))
        XCTAssertEqual(ranked.map(\.item.label), ["printx", "printf"])
    }

    /// F-17: `sortText` never leaks across providers; other sources keep the old order.
    func testSortTextDoesNotOrderAcrossSources() async {
        let ranker = DefaultRanker()
        let items = [
            makeItem(label: "ab", kind: .method, source: "B", sortText: "1"),
            makeItem(label: "aa", kind: .method, source: "A", sortText: "2"),
        ]
        let ranked = await ranker.rank(items: items, context: makeContext(prefix: ""))
        XCTAssertEqual(ranked.map(\.item.source), ["A", "B"])
    }

    /// F-17: items without `sortText` sort after same-score items that have one.
    func testMissingSortTextSortsLastWithinSource() async {
        let ranker = DefaultRanker()
        let items = [
            makeItem(label: "aba", kind: .method, source: "LSP"),
            makeItem(label: "abz", kind: .method, source: "LSP", sortText: "9"),
        ]
        let ranked = await ranker.rank(items: items, context: makeContext(prefix: "ab"))
        XCTAssertEqual(ranked.map(\.item.label), ["abz", "aba"])
    }

    /// F-17: an expected type boosts the items whose `detail` names it, below `preselect`
    /// but above recency noise.
    func testExpectedTypeBoostsMatchingDetail() async {
        let ranker = DefaultRanker()
        let plain = makeItem(label: "size", kind: .method, source: "Java", priority: 1, detail: "int")
        let typed = makeItem(label: "size", kind: .method, source: "Java", priority: 0, detail: "String")
        var context = makeContext(prefix: "size")
        let untyped = await ranker.rank(items: [typed, plain], context: context)
        XCTAssertEqual(untyped.first?.item.detail, "int", "without expected types priority wins")
        context = makeContext(prefix: "size", expectedTypeNames: ["String"])
        let ranked = await ranker.rank(items: [typed, plain], context: context)
        XCTAssertEqual(ranked.first?.item.detail, "String")
    }
}

private func makeContext(prefix: String, expectedTypeNames: Set<String> = []) -> CompletionContext {
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
        range: TextRange(start: position, end: position),
        expectedTypeNames: expectedTypeNames
    )
}

private func makeItem(
    label: String, kind: CompletionItemKind, source: String, priority: Double = 0,
    sortText: String? = nil, detail: String? = nil, preselect: Bool = false
) -> CompletionItem {
    let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
    return CompletionItem(
        label: label,
        insertText: label,
        kind: kind,
        range: TextRange(start: position, end: position),
        source: source,
        sortText: sortText,
        detail: detail,
        priority: priority,
        preselect: preselect
    )
}
