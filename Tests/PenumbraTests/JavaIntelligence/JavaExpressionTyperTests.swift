import XCTest
@testable import JavaIntelligence

final class JavaExpressionTyperTests: XCTestCase {
    private func tempShardURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).idx")
    }

    private func makeIndex(withStubs stubs: [JavaClassStub]) async throws -> JavaIndex {
        let url = tempShardURL()
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        let reader = try JavaIndexShardReader(url: url)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: reader)])
        return index
    }

    private func classType(_ name: String, args: [JavaTypeArgument] = []) -> JavaTypeRef {
        .classType(qualifiedName: name, arguments: args, outer: nil)
    }

    /// Parses `source` (with a `€` cursor marker right before the trigger `.`, e.g. `"foo€.bar"`),
    /// runs the typer, and returns the inferred receiver type.
    private func typeOfReceiver(_ source: String, context: JavaResolutionContext, index: JavaIndex) async -> JavaTypeRef? {
        let markerRange = source.range(of: "€")!
        precondition(source[markerRange.upperBound] == ".", "marker € must immediately precede the trigger '.'")
        let withoutMarker = source.replacingOccurrences(of: "€", with: "")
        let dotOffset = source.utf8.distance(from: source.utf8.startIndex, to: markerRange.lowerBound.samePosition(in: source.utf8)!)
        let tree = JavaSyntaxParser().parse(withoutMarker)!
        return await JavaExpressionTyper.typeOfReceiver(source: withoutMarker, realTree: tree, dotOffset: dotOffset, context: context, index: index)
    }

    private func objectStub() -> JavaClassStub {
        JavaClassStub(
            binaryName: "java.lang.Object", qualifiedName: "java.lang.Object", simpleName: "Object", packageName: "java.lang",
            kind: .classKind, modifiers: [.publicFlag], origin: .jdkModule("test")
        )
    }

    /// `JavaTypeResolver`'s java.lang fallback only fires when the candidate actually exists in
    /// the index (unlike an explicit import, which is trusted as written) -- so any test whose
    /// expected type is `java.lang.String` needs this stub present, the same way real code needs
    /// `java.lang` classes to actually be indexed from the JDK.
    private func stringStub() -> JavaClassStub {
        JavaClassStub(
            binaryName: "java.lang.String", qualifiedName: "java.lang.String", simpleName: "String", packageName: "java.lang",
            kind: .classKind, modifiers: [.publicFlag, .finalFlag], origin: .jdkModule("test")
        )
    }

    // MARK: - Locals

    func testLocalVariableIdentifier() async throws {
        let index = try await makeIndex(withStubs: [stringStub()])
        let context = JavaResolutionContext(packageName: "", imports: [])
        let type = await typeOfReceiver("class Foo { void m() { String s = \"\"; s€. } }", context: context, index: index)
        XCTAssertEqual(type?.erasedQualifiedName, "java.lang.String")
    }

    func testParameterIdentifier() async throws {
        let index = try await makeIndex(withStubs: [stringStub()])
        let context = JavaResolutionContext(packageName: "", imports: [])
        let type = await typeOfReceiver("class Foo { void m(String name) { name€. } }", context: context, index: index)
        XCTAssertEqual(type?.erasedQualifiedName, "java.lang.String")
    }

    // MARK: - this / implicit fields

    func testThisKeyword() async throws {
        let foo = JavaClassStub(binaryName: "Foo", qualifiedName: "Foo", simpleName: "Foo", packageName: "", kind: .classKind, modifiers: [.publicFlag], origin: .jdkModule("test"))
        let index = try await makeIndex(withStubs: [foo])
        let context = JavaResolutionContext(packageName: "", imports: [], enclosingTypeQualifiedNames: ["Foo"])
        let type = await typeOfReceiver("class Foo { void m() { this€. } }", context: context, index: index)
        XCTAssertEqual(type?.erasedQualifiedName, "Foo")
    }

    func testImplicitFieldAccess() async throws {
        let foo = JavaClassStub(
            binaryName: "Foo", qualifiedName: "Foo", simpleName: "Foo", packageName: "", kind: .classKind, modifiers: [.publicFlag],
            fields: [JavaFieldStub(name: "name", type: classType("java.lang.String"), modifiers: [.privateFlag])],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [foo])
        let context = JavaResolutionContext(packageName: "", imports: [], enclosingTypeQualifiedNames: ["Foo"])
        let type = await typeOfReceiver("class Foo { void m() { name€. } }", context: context, index: index)
        XCTAssertEqual(type?.erasedQualifiedName, "java.lang.String")
    }

    // MARK: - Field chains

    func testFieldAccessChain() async throws {
        let bar = JavaClassStub(
            binaryName: "Bar", qualifiedName: "Bar", simpleName: "Bar", packageName: "", kind: .classKind, modifiers: [.publicFlag],
            fields: [JavaFieldStub(name: "value", type: .primitive(.int), modifiers: [.publicFlag])], origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [bar])
        let context = JavaResolutionContext(packageName: "", imports: [])
        let type = await typeOfReceiver("class Foo { void m(Bar bar) { bar.value€. } }", context: context, index: index)
        XCTAssertEqual(type, .primitive(.int))
    }

    // MARK: - Method calls

    func testUnqualifiedMethodCallResolvesViaImplicitThis() async throws {
        let foo = JavaClassStub(
            binaryName: "Foo", qualifiedName: "Foo", simpleName: "Foo", packageName: "", kind: .classKind, modifiers: [.publicFlag],
            methods: [JavaMethodStub(name: "getName", parameters: [], returnType: classType("java.lang.String"), modifiers: [.publicFlag])],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [foo])
        let context = JavaResolutionContext(packageName: "", imports: [], enclosingTypeQualifiedNames: ["Foo"])
        let type = await typeOfReceiver("class Foo { void m() { getName()€. } }", context: context, index: index)
        XCTAssertEqual(type?.erasedQualifiedName, "java.lang.String")
    }

    func testQualifiedMethodCall() async throws {
        let bar = JavaClassStub(
            binaryName: "Bar", qualifiedName: "Bar", simpleName: "Bar", packageName: "", kind: .classKind, modifiers: [.publicFlag],
            methods: [JavaMethodStub(name: "getValue", parameters: [], returnType: .primitive(.int), modifiers: [.publicFlag])],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [bar])
        let context = JavaResolutionContext(packageName: "", imports: [])
        let type = await typeOfReceiver("class Foo { void m(Bar bar) { bar.getValue()€. } }", context: context, index: index)
        XCTAssertEqual(type, .primitive(.int))
    }

    func testMethodCallChain() async throws {
        let builder = JavaClassStub(
            binaryName: "Builder", qualifiedName: "Builder", simpleName: "Builder", packageName: "", kind: .classKind, modifiers: [.publicFlag],
            methods: [
                JavaMethodStub(name: "withName", parameters: [JavaParameterStub(name: "n", type: classType("java.lang.String"))], returnType: classType("Builder"), modifiers: [.publicFlag]),
                JavaMethodStub(name: "build", parameters: [], returnType: classType("Foo"), modifiers: [.publicFlag])
            ],
            origin: .jdkModule("test")
        )
        let foo = JavaClassStub(binaryName: "Foo", qualifiedName: "Foo", simpleName: "Foo", packageName: "", kind: .classKind, modifiers: [.publicFlag], origin: .jdkModule("test"))
        let index = try await makeIndex(withStubs: [builder, foo])
        let context = JavaResolutionContext(packageName: "", imports: [])
        let type = await typeOfReceiver("class Foo { void m(Builder b) { b.withName(\"x\").build()€. } }", context: context, index: index)
        XCTAssertEqual(type?.erasedQualifiedName, "Foo")
    }

    func testOverloadResolutionByArity() async throws {
        let foo = JavaClassStub(
            binaryName: "Foo", qualifiedName: "Foo", simpleName: "Foo", packageName: "", kind: .classKind, modifiers: [.publicFlag],
            methods: [
                JavaMethodStub(name: "make", parameters: [], returnType: .primitive(.int), modifiers: [.publicFlag]),
                JavaMethodStub(name: "make", parameters: [JavaParameterStub(name: "a", type: .primitive(.int))], returnType: classType("java.lang.String"), modifiers: [.publicFlag])
            ],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [foo])
        let context = JavaResolutionContext(packageName: "", imports: [], enclosingTypeQualifiedNames: ["Foo"])
        let zeroArg = await typeOfReceiver("class Foo { void m() { make()€. } }", context: context, index: index)
        XCTAssertEqual(zeroArg, .primitive(.int))
        let oneArg = await typeOfReceiver("class Foo { void m() { make(1)€. } }", context: context, index: index)
        XCTAssertEqual(oneArg?.erasedQualifiedName, "java.lang.String")
    }

    // MARK: - new / cast / array / literals

    func testObjectCreationExpression() async throws {
        let point = JavaClassStub(binaryName: "Point", qualifiedName: "Point", simpleName: "Point", packageName: "", kind: .classKind, modifiers: [.publicFlag], origin: .jdkModule("test"))
        let index = try await makeIndex(withStubs: [point])
        let context = JavaResolutionContext(packageName: "", imports: [])
        let type = await typeOfReceiver("class Foo { void m() { new Point()€. } }", context: context, index: index)
        XCTAssertEqual(type?.erasedQualifiedName, "Point")
    }

    func testGenericObjectCreationExpression() async throws {
        let index = try await makeIndex(withStubs: [])
        let context = JavaResolutionContext(packageName: "", imports: [])
        let type = await typeOfReceiver("class Foo { void m() { new ArrayList<String>()€. } }", context: context, index: index)
        guard case .unresolved(let simpleName, let args) = type else { return XCTFail("expected unresolved ArrayList<String>") }
        XCTAssertEqual(simpleName, "ArrayList")
        XCTAssertEqual(args.count, 1)
    }

    func testArrayAccessElementType() async throws {
        let index = try await makeIndex(withStubs: [stringStub()])
        let context = JavaResolutionContext(packageName: "", imports: [])
        let type = await typeOfReceiver("class Foo { void m(String[] names) { names[0]€. } }", context: context, index: index)
        XCTAssertEqual(type?.erasedQualifiedName, "java.lang.String")
    }

    func testCastExpression() async throws {
        let index = try await makeIndex(withStubs: [stringStub()])
        let context = JavaResolutionContext(packageName: "com.example", imports: [])
        let type = await typeOfReceiver("class Foo { void m(Object o) { ((String) o)€. } }", context: context, index: index)
        XCTAssertEqual(type?.erasedQualifiedName, "java.lang.String")
    }

    func testStringLiteral() async throws {
        let index = try await makeIndex(withStubs: [])
        let context = JavaResolutionContext(packageName: "", imports: [])
        let type = await typeOfReceiver("class Foo { void m() { \"hello\"€. } }", context: context, index: index)
        XCTAssertEqual(type?.erasedQualifiedName, "java.lang.String")
    }

    func testIntegerLiteral() async throws {
        let index = try await makeIndex(withStubs: [])
        let context = JavaResolutionContext(packageName: "", imports: [])
        let type = await typeOfReceiver("class Foo { void m() { (5)€. } }", context: context, index: index)
        XCTAssertEqual(type, .primitive(.int))
    }

    // MARK: - Type-qualifier (static) receiver

    func testBareTypeNameIsStaticOnlyReceiver() async throws {
        let mathClass = JavaClassStub(
            binaryName: "java.lang.Math", qualifiedName: "java.lang.Math", simpleName: "Math", packageName: "java.lang", kind: .classKind, modifiers: [.publicFlag],
            methods: [
                JavaMethodStub(name: "max", parameters: [JavaParameterStub(name: "a", type: .primitive(.int)), JavaParameterStub(name: "b", type: .primitive(.int))], returnType: .primitive(.int), modifiers: [.publicFlag, .staticFlag]),
                JavaMethodStub(name: "instanceOnly", parameters: [], returnType: .primitive(.int), modifiers: [.publicFlag])
            ],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [mathClass])
        let context = JavaResolutionContext(packageName: "", imports: [])
        let type = await typeOfReceiver("class Foo { void m() { Math.max(1, 2)€. } }", context: context, index: index)
        XCTAssertEqual(type, .primitive(.int))
    }

    // MARK: - Failure cases return nil rather than guessing

    func testUnknownIdentifierReturnsNil() async throws {
        let index = try await makeIndex(withStubs: [])
        let context = JavaResolutionContext(packageName: "", imports: [])
        let type = await typeOfReceiver("class Foo { void m() { totallyUnknownThing€. } }", context: context, index: index)
        XCTAssertNil(type)
    }

    func testUnknownMemberReturnsNil() async throws {
        let bar = JavaClassStub(binaryName: "Bar", qualifiedName: "Bar", simpleName: "Bar", packageName: "", kind: .classKind, modifiers: [.publicFlag], origin: .jdkModule("test"))
        let index = try await makeIndex(withStubs: [bar])
        let context = JavaResolutionContext(packageName: "", imports: [])
        let type = await typeOfReceiver("class Foo { void m(Bar bar) { bar.nope€. } }", context: context, index: index)
        XCTAssertNil(type)
    }

    func testNothingBeforeDotReturnsNil() async throws {
        let index = try await makeIndex(withStubs: [])
        let context = JavaResolutionContext(packageName: "", imports: [])
        let type = await typeOfReceiver("class Foo { void m() { €. } }", context: context, index: index)
        XCTAssertNil(type)
    }

    // MARK: - Real JDK, end-to-end (opt-in)

    func testRealChainedStreamMethodCall() async throws {
        guard let found = TestJDK.discovered, let installation = ReleaseFileParser.parse(found.home), installation.hasCtSym else {
            throw XCTSkip("No JDK with ct.sym found on this machine")
        }
        let stubs = try JDKCtSymRoot(installation: installation).readStubs()
        let url = tempShardURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: try JavaIndexShardReader(url: url))])
        let context = JavaResolutionContext(
            packageName: "",
            imports: [
                JavaImportDeclaration(qualifiedName: "java.util.List", isStatic: false, isOnDemand: false),
                JavaImportDeclaration(qualifiedName: "java.util.ArrayList", isStatic: false, isOnDemand: false)
            ]
        )
        // `list` is a parameter, not a local declared earlier in the same statement: a receiver
        // chain (`list.get(0)`, a method_invocation) ending in a bare trigger `.` reliably
        // collapses tree-sitter's error recovery for the *whole* enclosing declaration (see
        // JavaReceiverScanner's and JavaLocalScope's doc comments), and in that collapse only a
        // `parameters:` field survives -- an earlier local_variable_declaration in the same
        // corrupted body does not. Using a parameter here exercises the real, supported path.
        let type = await typeOfReceiver(
            "class Foo { void m(List<String> list) { String s = list.get(0)€. } }",
            context: context, index: index
        )
        XCTAssertEqual(type?.erasedQualifiedName, "java.lang.String")
    }

}
