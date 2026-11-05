import XCTest
import EditorIntelligence

/// Foundation's TextKit `TextRange` leaks in through XCTest; pin the EIP one for this file.
private typealias TextRange = EditorIntelligence.TextRange

/// The workspace symbol index is the one tree-sitter parse shared by completion (F-02): this
/// covers the structure half of F-16 — an outline for languages with no dedicated
/// `StructureProviding`, built from the same symbols the index already holds, with no new parse.
final class SymbolStructureProviderTests: XCTestCase {
    func testAllStructureNestsMembersUnderTypes() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let typeRange = range(0, 100)
        let forum = await setup(
            index, documentID,
            [
                makeSymbol(name: "Widget", kind: .type, nameAt: 5, body: typeRange, documentID: documentID),
                makeSymbol(name: "render", kind: .function, nameAt: 20, body: range(15, 60), documentID: documentID),
                makeSymbol(name: "title", kind: .property, nameAt: 65, body: range(65, 72), documentID: documentID),
                makeSymbol(name: "main", kind: .function, nameAt: 120, body: range(115, 150), documentID: documentID),
            ]
        )
        let provider = SymbolStructureProvider(index: index)
        guard let roots = await provider.allStructure(forSource: "", document: forum) else {
            return XCTFail("expected an outline from indexed symbols")
        }
        XCTAssertEqual(roots.map(\.title), ["Widget", "main"])
        XCTAssertEqual(roots[0].kind, .type)
        XCTAssertEqual(roots[0].children.map(\.title), ["render", "title"])
        // A free tree-sitter function nested under a type is a method, not a free function.
        XCTAssertEqual(roots[0].children.map(\.kind), [.method, .field])
        XCTAssertEqual(roots[1].kind, .function)
    }

    func testStructureAtCaretFindsInnermostMember() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let forum = await setup(
            index, documentID,
            [
                makeSymbol(name: "Widget", kind: .type, nameAt: 5, body: range(0, 100), documentID: documentID),
                makeSymbol(name: "render", kind: .function, nameAt: 20, body: range(15, 60), documentID: documentID),
            ]
        )
        let provider = SymbolStructureProvider(index: index)
        let member = await provider.structure(forSource: "", document: forum, atUTF16Offset: 25)
        XCTAssertEqual(member?.title, "render")
        // Outside every body the first top-level type answers, matching the protocol contract.
        let outside = await provider.structure(forSource: "", document: forum, atUTF16Offset: 150)
        XCTAssertEqual(outside?.title, "Widget")
    }

    func testWordsImportsAndFileNamesAreExcluded() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let forum = await setup(
            index, documentID,
            [
                makeSymbol(name: "hello", kind: .word, nameAt: 0, body: range(0, 5), documentID: documentID),
                makeSymbol(name: "os", kind: .importStatement, nameAt: 6, body: range(6, 8), documentID: documentID),
            ]
        )
        let provider = SymbolStructureProvider(index: index)
        let roots = await provider.allStructure(forSource: "", document: forum)
        XCTAssertNil(roots)
    }

    func testColdIndexReadsThroughTheSharedParser() async {
        let index = SymbolIndex()
        let parser = StubParser(symbols: [
            makeSymbol(name: "late", kind: .function, nameAt: 0, body: range(0, 10), documentID: DocumentID()),
        ])
        let provider = SymbolStructureProvider(index: index, parser: parser)
        // The document below was never indexed and its bridged snapshot is elided (no text, as a
        // freshly opened file is): the outline still appears, parsed from the live settle text.
        let forum = makeDocument(id: DocumentID(), text: "")
        let roots = await provider.allStructure(forSource: "def late(): ...", document: forum)
        XCTAssertEqual(roots?.map(\.title), ["late"])
        XCTAssertEqual(parser.calls, 1)
        XCTAssertEqual(parser.lastText, "def late(): ...")
    }

    func testWarmIndexNeverTouchesTheParser() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let forum = await setup(
            index, documentID,
            [makeSymbol(name: "early", kind: .function, nameAt: 0, body: range(0, 10), documentID: documentID)]
        )
        let parser = StubParser(symbols: [])
        let provider = SymbolStructureProvider(index: index, parser: parser)
        let roots = await provider.allStructure(forSource: "", document: forum)
        XCTAssertEqual(roots?.map(\.title), ["early"])
        XCTAssertEqual(parser.calls, 0, "the indexed fast path must not parse")
    }

    /// Same-span declarations contain each other (a module root spans its only child): the forest
    /// must still show every symbol instead of dropping the cycle into nothing.
    func testSameSpanDeclarationsDoNotCycleIntoNothing() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let forum = await setup(
            index, documentID,
            [
                makeSymbol(name: "namespace", kind: .type, nameAt: 0, body: range(0, 31), documentID: documentID),
                makeSymbol(name: "greet", kind: .function, nameAt: 4, body: range(0, 31), documentID: documentID),
            ]
        )
        let provider = SymbolStructureProvider(index: index)
        guard let roots = await provider.allStructure(forSource: "", document: forum) else {
            return XCTFail("same-span declarations must still outline")
        }
        let titles = roots.map(\.title) + roots.flatMap(\.children).map(\.title)
        XCTAssertEqual(titles.sorted(), ["greet", "namespace"])
    }

    func testNilDocumentReturnsNil() async {
        let provider = SymbolStructureProvider(index: SymbolIndex())
        let all = await provider.allStructure(forSource: "func f() {}", document: nil)
        XCTAssertNil(all)
        let one = await provider.structure(forSource: "func f() {}", document: nil, atUTF16Offset: 0)
        XCTAssertNil(one)
    }

    // MARK: - Helpers

    private func range(_ lower: Int, _ upper: Int) -> TextRange {
        TextRange(
            start: TextPosition(line: 0, column: 0, utf16Offset: lower),
            end: TextPosition(line: 0, column: 0, utf16Offset: upper)
        )
    }

    private final class StubParser: LanguageParser, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }
        private var _lastText: String?
        var lastText: String? { lock.withLock { _lastText } }
        let symbols: [Symbol]

        init(symbols: [Symbol]) {
            self.symbols = symbols
        }

        func parse(document: Document) async -> SyntaxTree {
            lock.withLock {
                _calls += 1
                _lastText = document.contentSnapshot.text
            }
            return StubTree(symbols: symbols)
        }
    }

    private struct StubTree: SyntaxTree {
        let symbols: [Symbol]
        let words: [String] = []
        let imports: [String] = []
    }

    private func makeSymbol(
        name: String, kind: SymbolKind, nameAt: Int, body: TextRange, documentID: DocumentID
    ) -> Symbol {
        let namePosition = TextPosition(line: 0, column: 0, utf16Offset: nameAt)
        return Symbol(
            name: name,
            kind: kind,
            documentID: documentID,
            range: TextRange(start: namePosition, end: namePosition),
            containerRange: body
        )
    }

    private func setup(
        _ index: SymbolIndex, _ documentID: DocumentID, _ symbols: [Symbol]
    ) async -> Document {
        await index.index(symbols, for: documentID)
        return makeDocument(id: documentID, text: "")
    }

    private func makeDocument(id: DocumentID, text: String) -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let point = TextRange(start: position, end: position)
        return Document(
            id: id,
            displayName: "fixture",
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: point),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 0, height: 0)
        )
    }
}
