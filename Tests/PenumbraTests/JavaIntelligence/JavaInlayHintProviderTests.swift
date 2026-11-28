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
        static int count() { return 0; }
        static Lib make() { return null; }
        static String[] words() { return null; }
        interface Visitor { void visit(String item, int depth); }
        static void walk(Visitor visitor) {}
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

    private func hints(
        _ source: String, range: Range<Int>? = nil, options: JavaInlayHintOptions? = nil,
        documentParseCache: JavaDocumentParseCache? = nil, extraLibrary: String = ""
    ) async throws -> [InlayHint] {
        let libURL = scratch.appendingPathComponent("Lib.java")
        let library = lib + "\n" + extraLibrary
        try library.write(to: libURL, atomically: true, encoding: .utf8)
        let shard = scratch.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(
            JavaSourceStubBuilder.build(source: library, url: libURL).classes,
            stamp: JavaStamp(size: 0, modificationDate: 0), to: shard
        )
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: shard))])
        let provider = JavaInlayHintProvider(
            index: index, indexPaths: JavaIndexPaths(root: scratch.appendingPathComponent("cache")),
            documentParseCache: documentParseCache
        )
        if let options { await provider.setOptions(options) }
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

    func testSymbolExclusionsMatchQualifiedOwnersAndWildcards() {
        XCTAssertTrue(JavaInlayHints.matchesExclusion("java.lang.Math.*", symbol: "java.lang.Math.min"))
        XCTAssertTrue(JavaInlayHints.matchesExclusion("java.lang.String.substring", symbol: "java.lang.String.substring"))
        XCTAssertFalse(JavaInlayHints.matchesExclusion("java.lang.Math.*", symbol: "example.java.lang.Math.min"))
        XCTAssertFalse(JavaInlayHints.matchesExclusion("example.Api.get", symbol: "example.Api.getAll"))
    }

    private let records = """
    record Item(String name, int quantity) {}
    record Order(Item first, java.util.List<String> notes) {}
    record Pair<A, B>(A left, B right) {}
    """

    func testATypeHintLinksTheClassNameToItsDeclarationWhenTheClassIsTheProjects() async throws {
        let libURL = scratch.appendingPathComponent("Lib.java")
        try lib.write(to: libURL, atomically: true, encoding: .utf8)
        let shard = scratch.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(
            JavaSourceStubBuilder.build(source: lib, url: libURL).classes, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard
        )
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: shard))])
        let provider = JavaInlayHintProvider(index: index, indexPaths: JavaIndexPaths(root: scratch.appendingPathComponent("cache")))
        await provider.setOptions(JavaInlayHintOptions(parameterNames: false, variableTypes: true))
        let source = "class T { void m() { var made = Lib.make(); } }"
        let start = JavaNavigationText.position(utf16Offset: 0, in: source)
        let end = JavaNavigationText.position(utf16Offset: (source as NSString).length, in: source)
        let document = Document(
            url: scratch.appendingPathComponent("T.java"), displayName: "T.java",
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: EditorIntelligence.TextRange(start: start, end: start)), cursor: Cursor(position: start),
            viewport: Viewport(x: 0, y: 0, width: 10, height: 10), languageIdentifier: "java"
        )
        let hints = await provider.inlayHints(for: document, in: EditorIntelligence.TextRange(start: start, end: end))
        let hint = try XCTUnwrap(hints.first)
        XCTAssertEqual(hint.label, ": Lib")
        let part = try XCTUnwrap(hint.parts.first)
        XCTAssertEqual(part.range, NSRange(location: 2, length: 3), "the class name, after the colon")

        // Nothing is read or resolved until the click.
        let activation = await provider.activateInlayHintPart(part, of: hint, in: document)
        XCTAssertEqual(activation, .open(
            uri: libURL.absoluteString,
            range: LSPRange(start: LSPPosition(line: 0, character: 6), end: LSPPosition(line: 0, character: 9))
        ), "the name in `class Lib {`")

        // A class the project has no source for, an unknown token and another provider's hint do nothing.
        let jdk = InlayHintLabelPart(range: part.range, target: .token(Data("java.type:java.lang.String".utf8)))
        let missing = await provider.activateInlayHintPart(jdk, of: hint, in: document)
        XCTAssertEqual(missing, .unhandled)
        let foreign = await provider.activateInlayHintPart(InlayHintLabelPart(range: part.range, target: .token(Data("x".utf8))), of: hint, in: document)
        XCTAssertEqual(foreign, .unhandled)
        let other = InlayHint(utf16Offset: 0, label: ": Lib", providerID: "lsp", parts: [part])
        let notOurs = await provider.activateInlayHintPart(part, of: other, in: document)
        XCTAssertEqual(notOurs, .unhandled)
    }

    func testVarComponentsOfARecordPatternTakeTheComponentTypes() async throws {
        let source = "class T { boolean m(Object o) { return o instanceof Order(var first, var notes); } }"
        let result = try await hints(
            source, options: JavaInlayHintOptions(parameterNames: false, variableTypes: true), extraLibrary: records
        )
        XCTAssertEqual(result.map(\.label), [": Item", ": List<String>"])
        XCTAssertEqual(
            rendered(source, result),
            "class T { boolean m(Object o) { return o instanceof Order(var first: Item , var notes: List<String> ); } }"
        )
    }

    func testNestedRecordPatternsResolveEachRecordOnItsOwn() async throws {
        let source = "class T { boolean m(Object o) { return o instanceof Order(Item(var name, var quantity), var notes); } }"
        let result = try await hints(
            source, options: JavaInlayHintOptions(parameterNames: false, variableTypes: true), extraLibrary: records
        )
        // The controller sorts hints by position; the provider returns them in discovery order.
        XCTAssertEqual(result.sorted { $0.utf16Offset < $1.utf16Offset }.map(\.label), [": String", ": int", ": List<String>"])
    }

    func testRecordPatternHintsAreSkippedForGenericAndUnknownRecordsAndTypedComponents() async throws {
        let options = JavaInlayHintOptions(parameterNames: false, variableTypes: true)
        let generic = try await hints(
            "class T { boolean m(Object o) { return o instanceof Pair(var left, var right); } }",
            options: options, extraLibrary: records
        )
        XCTAssertEqual(generic, [], "a generic record needs the scrutinee's type arguments")
        let unknown = try await hints(
            "class T { boolean m(Object o) { return o instanceof Missing(var x); } }", options: options, extraLibrary: records
        )
        XCTAssertEqual(unknown, [])
        let typed = try await hints(
            "class T { boolean m(Object o) { return o instanceof Item(String name, int quantity); } }",
            options: options, extraLibrary: records
        )
        XCTAssertEqual(typed, [], "a written type needs no hint")
        let off = try await hints(
            "class T { boolean m(Object o) { return o instanceof Item(var name, var quantity); } }",
            options: JavaInlayHintOptions(parameterNames: false, variableTypes: false), extraLibrary: records
        )
        XCTAssertEqual(off, [])
    }

    func testLabelsLiteralArgumentsOfAMethodCall() async throws {
        let source = "class T { void m() { Lib.area(3, 4); } }"
        let result = try await hints(source)
        XCTAssertEqual(rendered(source, result), "class T { void m() { Lib.area(width: 3, height: 4); } }")
    }

    func testAnOversizedFileReusesTheExistingDocumentParse() async throws {
        let cache = JavaDocumentParseCache()
        let source = "class T { void m() { Lib.area(3, 4); } } /*"
            + String(repeating: "x", count: JavaParseMemo.maximumEntryBytes) + "*/"
        let start = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let viewport = Viewport(x: 0, y: 0, width: 10, height: 10)
        let document = Document(
            url: scratch.appendingPathComponent("T.java"), displayName: "T.java",
            contentSnapshot: TextSnapshot(version: 1, text: source), selection: Selection(range: TextRange(start: start, end: start)),
            cursor: Cursor(position: start), viewport: viewport, languageIdentifier: "java"
        )
        _ = await cache.tree(for: document)
        let result = try await hints(source, range: 0..<40, documentParseCache: cache)
        let stats = await cache.statistics
        XCTAssertEqual(result.map(\.label), ["width:", "height:"])
        XCTAssertEqual(stats.fullParses, 1)
        XCTAssertEqual(stats.hits, 1)
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

    func testOverloadsOfOneArityAreChosenByTheArgumentTypes() async throws {
        let source = "class T { void m() { Lib.over(1, 2); Lib.over(\"s\", 2); } }"
        // `over(int, int)` and `over(String, int)` share an arity; the argument types pick one, as javac does
        // (`JavaInlayHintCallOracleTests` checks this against javac).
        let result = try await hints(source)
        XCTAssertEqual(rendered(source, result), "class T { void m() { Lib.over(a: 1, b: 2); Lib.over(s: \"s\", b: 2); } }")
    }

    func testOverloadsStayUnlabeledWhenTheArgumentsCannotChooseOne() async throws {
        // An argument that does not type, a `null` and a lambda say nothing about which overload binds, so no
        // call is labeled by a guess.
        let source = "class T { void m() { Lib.over(missing, 2); Lib.over(null, 2); Lib.over(() -> 1, 2); } }"
        let result = try await hints(source)
        XCTAssertTrue(result.isEmpty, "\(result.map(\.label))")
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

    // MARK: - Type hints

    private let typeHints = JavaInlayHintOptions(parameterNames: false, variableTypes: true, lambdaParameterTypes: false)

    private func labels(_ source: String, options: JavaInlayHintOptions) async throws -> [String] {
        try await hints(source, options: options).sorted { $0.utf16Offset < $1.utf16Offset }.map(\.label)
    }

    func testVarLocalsGetTheirInitializersType() async throws {
        let source = "class T { void m() { var n = Lib.count(); var l = Lib.make(); } }"
        let result = try await labels(source, options: typeHints)
        XCTAssertEqual(result, [": int", ": Lib"])
    }

    func testTypeHintSitsRightAfterTheName() async throws {
        let source = "class T { void m() { var n = Lib.count(); } }"
        let result = try await hints(source, options: typeHints)
        XCTAssertEqual(result.map(\.kind), [.type])
        XCTAssertEqual(result.first?.utf16Offset, (source as NSString).range(of: "n =").location + 1)
    }

    func testObviousInitializersGetNoTypeHint() async throws {
        let source = """
        class T { void m(Object x) {
            var a = new Lib(1, "x"); var b = 5; var c = "s"; var d = (Lib) x; var e = true; var f = Lib.make();
        } }
        """
        let result = try await labels(source, options: typeHints)
        XCTAssertEqual(result, [": Lib"], "only the call says nothing about its type")
    }

    func testExplicitTypesGetNoTypeHint() async throws {
        let source = "class T { void m() { int n = Lib.count(); Lib l = Lib.make(); } }"
        let result = try await labels(source, options: typeHints)
        XCTAssertEqual(result, [])
    }

    func testVarLoopVariablesGetTheElementType() async throws {
        let source = "class T { void m() { for (var w : Lib.words()) { } } }"
        let result = try await labels(source, options: typeHints)
        XCTAssertEqual(result, [": String"])
    }

    func testLaterVarsAreTypedFromEarlierOnes() async throws {
        let source = "class T { void m() { var l = Lib.make(); var again = l; } }"
        let result = try await labels(source, options: typeHints)
        XCTAssertEqual(result, [": Lib", ": Lib"])
    }

    func testLambdaParametersGetTheirFunctionalInterfaceTypes() async throws {
        let source = "class T { void m() { Lib.walk((item, depth) -> { }); } }"
        let both = JavaInlayHintOptions(parameterNames: false, variableTypes: false, lambdaParameterTypes: true)
        let result = try await labels(source, options: both)
        XCTAssertEqual(result, [": String", ": int"])
    }

    func testEachKindFollowsItsOption() async throws {
        let source = "class T { void m() { var n = Lib.count(); Lib.walk((item, depth) -> { }); Lib.area(1, 2); } }"
        let none = JavaInlayHintOptions(parameterNames: false, variableTypes: false, lambdaParameterTypes: false)
        let empty = try await labels(source, options: none)
        XCTAssertEqual(empty, [])
        let onlyParameters = try await labels(source, options: JavaInlayHintOptions())
        XCTAssertEqual(onlyParameters, ["width:", "height:"])
        let onlyVariables = try await labels(source, options: typeHints)
        XCTAssertEqual(onlyVariables, [": int"])
        let all = JavaInlayHintOptions(parameterNames: true, variableTypes: true, lambdaParameterTypes: true)
        let everything = try await labels(source, options: all)
        XCTAssertEqual(everything.count, 5)
    }

    func testUntypeableInitializersGetNoTypeHint() async throws {
        let source = "class T { void m() { var x = unknown(); } }"
        let result = try await labels(source, options: typeHints)
        XCTAssertEqual(result, [])
    }

    func testOnlyDeclarationsInTheRequestedRangeAreTyped() async throws {
        let source = "class T { void m() { var a = Lib.count(); } void n() { var b = Lib.make(); } }"
        let start = (source as NSString).range(of: "void n").location
        let result = try await hints(source, range: start..<source.utf16.count, options: typeHints)
        XCTAssertEqual(result.map(\.label), [": Lib"])
    }
}
