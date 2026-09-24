import XCTest
import EditorIntelligence
@testable import JavaIntelligence

final class JavaInlayHintProviderTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("java-inlay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private let lib = """
    class Lib {
        Lib(int capacity, String label) {}
        static int area(int width, int height) { return 0; }
        static void log(String message, int level) {}
        static void setSize(int size) {}
        static void run(Runnable task, int times) {}
        static void many(String first, int... rest) {}
        static void over(int a) {}
        static void over(int a, int b) {}
        static void over(String s, int b) {}
    }
    """

    /// Applies each hint as `label ` inserted at its offset, so a test can read the result.
    private func rendered(_ source: String, _ hints: [InlayHint]) -> String {
        var result = source as NSString
        for hint in hints.sorted(by: { $0.utf16Offset > $1.utf16Offset }) {
            result = result.replacingCharacters(in: NSRange(location: hint.utf16Offset, length: 0), with: hint.label + " ") as NSString
        }
        return result as String
    }

    private func hints(_ source: String, range: Range<Int>? = nil) async throws -> [InlayHint] {
        let libURL = scratch.appendingPathComponent("Lib.java")
        try lib.write(to: libURL, atomically: true, encoding: .utf8)
        let shard = scratch.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(
            JavaSourceStubBuilder.build(source: lib, url: libURL).classes,
            stamp: JavaStamp(size: 0, modificationDate: 0), to: shard
        )
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: shard))])
        let provider = JavaInlayHintProvider(index: index, indexPaths: JavaIndexPaths(root: scratch.appendingPathComponent("cache")))
        let length = (source as NSString).length
        let bounds = range ?? 0..<length
        let document = Document(
            url: scratch.appendingPathComponent("T.java"), displayName: "T.java",
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: EditorIntelligence.TextRange(start: JavaNavigationText.position(utf16Offset: 0, in: source), end: JavaNavigationText.position(utf16Offset: 0, in: source))),
            cursor: Cursor(position: JavaNavigationText.position(utf16Offset: 0, in: source)),
            viewport: Viewport(x: 0, y: 0, width: 10, height: 10),
            languageIdentifier: "java"
        )
        return await provider.inlayHints(for: document, in: EditorIntelligence.TextRange(
            start: JavaNavigationText.position(utf16Offset: bounds.lowerBound, in: source),
            end: JavaNavigationText.position(utf16Offset: bounds.upperBound, in: source)
        ))
    }

    func testLabelsLiteralArgumentsOfAMethodCall() async throws {
        let source = "class T { void m() { Lib.area(3, 4); } }"
        let result = try await hints(source)
        XCTAssertEqual(rendered(source, result), "class T { void m() { Lib.area(width: 3, height: 4); } }")
    }

    func testLabelsConstructorArguments() async throws {
        let source = "class T { void m() { new Lib(10, \"x\"); } }"
        let result = try await hints(source)
        XCTAssertEqual(rendered(source, result), "class T { void m() { new Lib(capacity: 10, label: \"x\"); } }")
    }

    func testSkipsIdentifiersNamedLikeTheParameterAndLambdas() async throws {
        let source = "class T { void m(int width, int other) { Lib.area(width, other); Lib.run(() -> {}, 2); } }"
        let result = try await hints(source)
        XCTAssertEqual(rendered(source, result), "class T { void m(int width, int other) { Lib.area(width, height: other); Lib.run(() -> {}, times: 2); } }")
    }

    func testSkipsObviousSingleArgumentCalls() async throws {
        let source = "class T { void m() { Lib.setSize(5); } }"
        let result = try await hints(source)
        XCTAssertTrue(result.isEmpty)
    }

    func testVarargsAreLeftUnlabeledAfterTheFixedParameters() async throws {
        let source = "class T { void m() { Lib.many(\"a\", 1, 2, 3); } }"
        let result = try await hints(source)
        XCTAssertEqual(rendered(source, result), "class T { void m() { Lib.many(first: \"a\", 1, 2, 3); } }")
    }

    func testAmbiguousOverloadsGetNoHints() async throws {
        let source = "class T { void m() { Lib.over(1, 2); Lib.over(\"s\", 2); } }"
        // `over(int, int)` and `over(String, int)` share an arity, so neither call is labeled by a guess.
        let result = try await hints(source)
        XCTAssertTrue(result.isEmpty)
    }

    func testUnresolvedCallsAndStubsWithoutNamesGetNoHints() async throws {
        let source = "class T { void m() { Missing.call(1, 2); } }"
        let unresolved = try await hints(source)
        XCTAssertTrue(unresolved.isEmpty)
        let noNames = JavaMethodStub(name: "f", parameters: [JavaParameterStub(name: nil, type: .primitive(.int))], returnType: .void, modifiers: [])
        let tree = JavaSyntaxParser().parse("class X { void m() { f(1, 2); } }")!
        var calls: [SyntaxNode] = []
        func walk(_ n: SyntaxNode) { if n.type == "method_invocation" { calls.append(n) }; n.namedChildren.forEach(walk) }
        walk(tree.rootNode)
        let args = calls[0].child(byFieldName: "arguments")!.namedChildren
        XCTAssertTrue(JavaInlayHints.hints(arguments: args, method: noNames, source: "class X { void m() { f(1, 2); } }").isEmpty)
    }

    func testOnlyCallsInTheRequestedRangeAreResolved() async throws {
        let source = "class T { void m() { Lib.area(1, 2);\nLib.area(3, 4); } }"
        let secondLine = (source as NSString).range(of: "\n").location + 1
        let result = try await hints(source, range: secondLine..<(source as NSString).length)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.utf16Offset >= secondLine })
    }

    func testOffsetsAreUTF16WithMultibyteTextBefore() async throws {
        let source = "class T { String s = \"café ☕\"; void m() { Lib.area(3, 4); } }"
        let result = try await hints(source)
        XCTAssertEqual(rendered(source, result), "class T { String s = \"café ☕\"; void m() { Lib.area(width: 3, height: 4); } }")
    }

    func testNonJavaDocumentsGetNothing() async throws {
        let source = "Lib.area(3, 4)"
        let provider = JavaInlayHintProvider(index: JavaIndex(), indexPaths: JavaIndexPaths(root: scratch))
        let position = JavaNavigationText.position(utf16Offset: 0, in: source)
        let document = Document(
            displayName: "x", contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position), viewport: Viewport(x: 0, y: 0, width: 1, height: 1),
            languageIdentifier: "swift"
        )
        let result = await provider.inlayHints(for: document, in: EditorIntelligence.TextRange(start: position, end: position))
        XCTAssertTrue(result.isEmpty)
    }
}
