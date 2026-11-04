import EditorIntelligence
import TestTreeSitterLanguages
import TreeSitter
import XCTest
@testable import Penumbra

/// F19: the workspace-index parser reuses a document's previous tree when the document is edited.
final class TreeSitterLanguageParserIncrementalTests: XCTestCase {
    private func document(_ text: String, id: DocumentID, version: Int) -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            id: id,
            url: URL(fileURLWithPath: "/tmp/\(id).js"),
            displayName: "t.js",
            contentSnapshot: TextSnapshot(version: version, text: text),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "javascript"
        )
    }

    private func signature(_ tree: SyntaxTree) -> [String] {
        tree.symbols.map { "\($0.name)|\($0.kind)|\($0.range.start.utf16Offset)-\($0.range.end.utf16Offset)|\($0.range.start.line):\($0.range.start.column)" }
            + ["words:" + tree.words.joined(separator: ",")]
            + ["imports:" + tree.imports.joined(separator: ",")]
    }

    private let base = """
    import { a } from 'alpha';
    function greet(name) { return "héllo " + name; }
    class Person {
      constructor(first) { this.first = first; }
      shout() { return `日本語 ${this.first} 😀`; }
    }
    const list = [1, 2, 3].map(x => x * 2);

    """

    func testAnEditedDocumentIsReparsedAgainstItsPreviousTree() async {
        let parser = TreeSitterLanguageParser(language: makeJavaScript())
        let id = DocumentID()
        _ = await parser.parse(document: document(base, id: id, version: 1))
        _ = await parser.parse(document: document(base.replacingOccurrences(of: "greet", with: "greeting"), id: id, version: 2))
        let full = await parser.fullParseCount
        let incremental = await parser.incrementalParseCount
        XCTAssertEqual(full, 1)
        XCTAssertEqual(incremental, 1)
    }

    func testAnUnchangedDocumentParsesNothing() async {
        let parser = TreeSitterLanguageParser(language: makeJavaScript())
        let id = DocumentID()
        let first = await parser.parse(document: document(base, id: id, version: 1))
        let second = await parser.parse(document: document(base, id: id, version: 2))
        XCTAssertEqual(signature(first), signature(second))
        let full = await parser.fullParseCount
        let incremental = await parser.incrementalParseCount
        XCTAssertEqual(full, 1)
        XCTAssertEqual(incremental, 0)
    }

    /// Every result of the incremental path equals a from-scratch parse of the same text, over a
    /// long run of random edits: insertions, deletions and replacements of text with newlines,
    /// quotes, braces, CJK, emoji and combining marks.
    func testIncrementalResultsEqualAFreshParseOverRandomEdits() async {
        let incremental = TreeSitterLanguageParser(language: makeJavaScript())
        let id = DocumentID()
        var generator = SeededGenerator(seed: 7)
        let fragments = ["x", " ", "\n", "\n\n", "{", "}", "(", ")", "'", "\"", "`", "😀", "日本", "é", "e\u{0301}", "function f(){}", "import { q } from 'z';\n", "// c\n", "/*", "*/", ";", "class K {}", "a.b.c", "\t"]
        var text = base
        _ = await incremental.parse(document: document(text, id: id, version: 0))
        for step in 1 ... 150 {
            let scalars = Array(text.unicodeScalars)
            let start = Int.random(in: 0 ... scalars.count, using: &generator)
            let removeCount = Bool.random(using: &generator) ? 0 : Int.random(in: 0 ... min(12, scalars.count - start), using: &generator)
            let insertion = Bool.random(using: &generator) ? fragments[Int.random(in: 0 ..< fragments.count, using: &generator)] : ""
            var updated = String.UnicodeScalarView()
            updated.append(contentsOf: scalars[..<start])
            updated.append(contentsOf: insertion.unicodeScalars)
            updated.append(contentsOf: scalars[(start + removeCount)...])
            text = String(updated)
            let fresh = TreeSitterLanguageParser(language: makeJavaScript())
            let expected = await fresh.parse(document: document(text, id: id, version: step))
            let actual = await incremental.parse(document: document(text, id: id, version: step))
            XCTAssertEqual(signature(actual), signature(expected), "step \(step) after editing at \(start) (-\(removeCount) +\(insertion.debugDescription))")
        }
        let reused = await incremental.incrementalParseCount
        XCTAssertGreaterThan(reused, 100, "the edits should have been reparsed incrementally")
    }

    func testTheCacheIsBounded() async {
        let parser = TreeSitterLanguageParser(language: makeJavaScript())
        let saved = TreeSitterLanguageParser.maxEntries
        TreeSitterLanguageParser.maxEntries = 3
        defer { TreeSitterLanguageParser.maxEntries = saved }
        let ids = (0 ..< 6).map { _ in DocumentID() }
        for id in ids { _ = await parser.parse(document: document(base, id: id, version: 1)) }
        let cached = await parser.cachedDocumentCount
        XCTAssertEqual(cached, 3)
        // The oldest was evicted: parsing it again is a from-scratch parse, the newest is still reused.
        _ = await parser.parse(document: document(base + "//", id: ids[0], version: 2))
        _ = await parser.parse(document: document(base + "//", id: ids[5], version: 2))
        let incremental = await parser.incrementalParseCount
        XCTAssertEqual(incremental, 1)
    }

    func testTextChangeRegionNeverSplitsAScalar() {
        let edit = TextChangeRegion.edit(from: "a😀b", to: "a😁b")
        XCTAssertEqual(edit?.startByte.value, 2) // after "a" (one UTF-16 unit, two bytes)
        XCTAssertEqual(edit?.oldEndByte.value, 2 + 4)
        XCTAssertEqual(edit?.newEndByte.value, 2 + 4)
        XCTAssertNil(TextChangeRegion.edit(from: "same", to: "same"))
        let lines = TextChangeRegion.edit(from: "ab\ncd", to: "ab\nXY\ncd")
        XCTAssertEqual(lines?.startPoint.row, 1)
        XCTAssertEqual(lines?.startPoint.column, 0)
        XCTAssertEqual(lines?.newEndPoint.row, 2)
    }
}

private func makeJavaScript() -> TreeSitterLanguage {
    TreeSitterLanguage(tree_sitter_javascript(), highlightsQuery: nil, injectionsQuery: nil, indentationScopes: nil)
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
