import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// `JavaCompletionProvider` reparses incrementally from its previous request's tree. Typing a
/// statement one character at a time with one provider must give the same items, at every step,
/// as a fresh provider that parses from scratch.
final class JavaCompletionIncrementalParseTests: XCTestCase {
    private func makeIndex() async throws -> JavaIndex {
        let bar = JavaClassStub(
            binaryName: "Bar", qualifiedName: "Bar", simpleName: "Bar", packageName: "", kind: .classKind, modifiers: [.publicFlag],
            fields: [JavaFieldStub(name: "value", type: .primitive(.int), modifiers: [.publicFlag])],
            methods: [
                JavaMethodStub(name: "getValue", parameters: [], returnType: .primitive(.int), modifiers: [.publicFlag]),
                JavaMethodStub(name: "getName", parameters: [], returnType: .unresolved(simpleName: "String", arguments: []), modifiers: [.publicFlag])
            ],
            origin: .jdkModule("test")
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write([bar], stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: try JavaIndexShardReader(url: url))])
        return index
    }

    private func context(before: String, after: String, version: Int) -> CompletionContext {
        let text = before + after
        let lines = before.components(separatedBy: "\n")
        let position = TextPosition(line: lines.count - 1, column: (lines.last ?? "").utf16.count, utf16Offset: (before as NSString).length)
        let document = Document(
            id: DocumentID(), url: URL(fileURLWithPath: "/tmp/Incremental.java"), displayName: "Incremental.java",
            contentSnapshot: TextSnapshot(version: version, text: text),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
        )
        return makeCompletionContext(document: document, trigger: .manual)
    }

    func testTypingWithOneProviderMatchesFreshParses() async throws {
        let index = try await makeIndex()
        let reused = JavaCompletionProvider(index: index)
        let head = "class Foo {\n    int count;\n    void m(Bar bar) {\n        int local = 1;\n        "
        let tail = "\n    }\n\n    void other() { }\n}\n"
        let typed = "bar.getN"
        for length in 1...typed.count {
            let before = head + String(typed.prefix(length))
            let request = context(before: before, after: tail, version: length)
            let incremental = await reused.provide(context: request).map(\.label).sorted()
            let fresh = await JavaCompletionProvider(index: index).provide(context: request).map(\.label).sorted()
            XCTAssertEqual(incremental, fresh, "after typing \(typed.prefix(length))")
        }
        // An edit elsewhere in the file (a new line above) followed by completion again.
        let edited = head.replacingOccurrences(of: "int local = 1;", with: "int local = 1;\n        int other = 2;") + "bar."
        let request = context(before: edited, after: tail, version: 100)
        let incremental = await reused.provide(context: request).map(\.label).sorted()
        let fresh = await JavaCompletionProvider(index: index).provide(context: request).map(\.label).sorted()
        XCTAssertEqual(incremental, fresh)
        XCTAssertTrue(incremental.contains("getValue"))
    }
}
