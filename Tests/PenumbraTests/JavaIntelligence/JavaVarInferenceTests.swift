import XCTest
import EditorIntelligence
@testable import JavaIntelligence
@testable import LanguageSyntax

/// `var` (JLS 14.4.1) as completion sees it. The receiver type is what member completion and the
/// receiver audit use (`JavaExpressionTyper.typeOfReceiver`). A declaration javac rejects stays
/// untyped: the tests expect `nil` there, not a stand-in type.
final class JavaVarInferenceTests: XCTestCase {
    private func makeIndex(withStubs stubs: [JavaClassStub]) async throws -> JavaIndex {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: try JavaIndexShardReader(url: url))])
        return index
    }

    private func classType(_ name: String, _ arguments: [JavaTypeRef] = []) -> JavaTypeRef {
        .classType(qualifiedName: name, arguments: arguments.map { .type($0) }, outer: nil)
    }

    private func stub(
        _ qualifiedName: String, kind: JavaTypeKind = .classKind, modifiers: JavaModifiers = [.publicFlag],
        typeParameters: [JavaTypeParameter] = [], methods: [JavaMethodStub] = [], fields: [JavaFieldStub] = []
    ) -> JavaClassStub {
        let simpleName = String(qualifiedName.split(separator: ".").last!)
        let packageName = qualifiedName.split(separator: ".").dropLast().joined(separator: ".")
        return JavaClassStub(
            binaryName: qualifiedName, qualifiedName: qualifiedName, simpleName: simpleName, packageName: packageName,
            kind: kind, modifiers: modifiers, typeParameters: typeParameters, fields: fields, methods: methods,
            origin: .jdkModule("test")
        )
    }

    private func method(
        _ name: String, parameters: [JavaTypeRef] = [], returns: JavaTypeRef = .void,
        typeParameters: [String] = [], modifiers: JavaModifiers = [.publicFlag]
    ) -> JavaMethodStub {
        JavaMethodStub(
            name: name,
            typeParameters: typeParameters.map { JavaTypeParameter(name: $0, bounds: []) },
            parameters: parameters.enumerated().map { JavaParameterStub(name: "p\($0.offset)", type: $0.element) },
            returnType: returns, modifiers: modifiers
        )
    }

    private func stringStub() -> JavaClassStub {
        stub("java.lang.String", modifiers: [.publicFlag, .finalFlag], methods: [
            method("trim", returns: classType("java.lang.String")),
            method("length", returns: .primitive(.int))
        ])
    }

    private func objectStub() -> JavaClassStub {
        stub("java.lang.Object")
    }

    /// `Optional<T>` with the real shapes completion cares about: `of` binds `T` from the argument,
    /// `get` returns the receiver's `T`.
    private func optionalStub() -> JavaClassStub {
        let variable = JavaTypeRef.typeVariable(name: "T")
        let optionalOfT = classType("java.util.Optional", [variable])
        return stub(
            "java.util.Optional", typeParameters: [JavaTypeParameter(name: "T", bounds: [])],
            methods: [
                JavaMethodStub(
                    name: "of", typeParameters: [JavaTypeParameter(name: "T", bounds: [])],
                    parameters: [JavaParameterStub(name: "value", type: variable)],
                    returnType: optionalOfT, modifiers: [.publicFlag, .staticFlag]
                ),
                method("get", returns: variable),
                method("empty", returns: optionalOfT, modifiers: [.publicFlag, .staticFlag])
            ]
        )
    }

    private func listStub() -> JavaClassStub {
        let element = JavaTypeRef.typeVariable(name: "E")
        return stub(
            "java.util.List", kind: .interfaceKind, typeParameters: [JavaTypeParameter(name: "E", bounds: [])],
            methods: [
                JavaMethodStub(
                    name: "of", typeParameters: [JavaTypeParameter(name: "E", bounds: [])],
                    parameters: [JavaParameterStub(name: "element", type: element)],
                    returnType: classType("java.util.List", [element]), modifiers: [.publicFlag, .staticFlag]
                ),
                method(
                    "iterator",
                    returns: classType("java.util.Iterator", [element])
                )
            ]
        )
    }

    private func mapStub() -> JavaClassStub {
        let key = JavaTypeRef.typeVariable(name: "K")
        let value = JavaTypeRef.typeVariable(name: "V")
        return stub(
            "java.util.Map", kind: .interfaceKind,
            typeParameters: [JavaTypeParameter(name: "K", bounds: []), JavaTypeParameter(name: "V", bounds: [])],
            methods: [
                JavaMethodStub(
                    name: "of", typeParameters: [JavaTypeParameter(name: "K", bounds: []), JavaTypeParameter(name: "V", bounds: [])],
                    parameters: [JavaParameterStub(name: "key", type: key), JavaParameterStub(name: "value", type: value)],
                    returnType: .classType(
                        qualifiedName: "java.util.Map", arguments: [.type(key), .type(value)], outer: nil
                    ),
                    modifiers: [.publicFlag, .staticFlag]
                )
            ]
        )
    }

    private func supportStubs() -> [JavaClassStub] {
        [
            objectStub(), stringStub(), optionalStub(), listStub(), mapStub(),
            stub("java.util.Iterator", kind: .interfaceKind, typeParameters: [JavaTypeParameter(name: "E", bounds: [])]),
            stub("Point", methods: [method("magnitude", returns: .primitive(.int))]),
            stub("java.util.function.Function", kind: .interfaceKind, typeParameters: [
                JavaTypeParameter(name: "T", bounds: []), JavaTypeParameter(name: "R", bounds: [])
            ], methods: [method("apply", parameters: [.typeVariable(name: "T")], returns: .typeVariable(name: "R"))]),
            stub("Foo", methods: [
                method("n", returns: .primitive(.int))
            ], fields: [
                JavaFieldStub(name: "n", type: .primitive(.int), modifiers: []),
                // Field lookup reads the index stub. The enhanced-for case iterates this field.
                JavaFieldStub(
                    name: "items",
                    type: classType("java.util.List", [classType("java.lang.String")]),
                    modifiers: []
                )
            ])
        ]
    }

    /// `€` sits immediately before the `.` whose receiver is typed.
    private func typeOfReceiver(_ source: String, index: JavaIndex) async -> JavaTypeRef? {
        let marker = source.range(of: "€")!
        precondition(source[marker.upperBound] == ".", "marker € must immediately precede '.'")
        let withoutMarker = source.replacingOccurrences(of: "€", with: "")
        let dotOffset = source.utf8.distance(from: source.utf8.startIndex, to: marker.lowerBound.samePosition(in: source.utf8)!)
        let tree = JavaSyntaxParser().parse(withoutMarker)!
        let file = JavaSourceStubBuilder.build(source: withoutMarker, url: URL(fileURLWithPath: "/tmp/Var.java"))
        let enclosing = file.classes.first.map { [$0.qualifiedName] } ?? []
        let context = JavaResolutionContext(
            packageName: file.packageName, imports: file.imports, enclosingTypeQualifiedNames: enclosing
        )
        return await JavaExpressionTyper.typeOfReceiver(
            source: withoutMarker, realTree: tree, dotOffset: dotOffset, context: context, index: index
        )
    }

    private func storedDocument(_ source: String, version: Int, url: URL) -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            url: url, displayName: url.lastPathComponent,
            contentSnapshot: TextSnapshot(version: version, text: source),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
        )
    }

    private func declarationEnds(in tree: JavaSyntaxTree, source: String) -> [String: Int] {
        let dot = source.range(of: "item.")!
        let offset = source.utf8.distance(from: source.utf8.startIndex, to: dot.upperBound.samePosition(in: source.utf8)!)
        return Dictionary(uniqueKeysWithValues: tree.visibleLocals(atByteOffset: offset).compactMap { local in
            local.declarationEnd.map { (local.name, $0) }
        })
    }

    private func receiver(in tree: JavaSyntaxTree, source: String, index: JavaIndex) async -> JavaTypeRef? {
        let dot = source.range(of: "item.")!
        let dotOffset = source.utf8.distance(from: source.utf8.startIndex, to: dot.upperBound.samePosition(in: source.utf8)!) - 1
        let file = JavaSourceStubBuilder.build(source: source, url: URL(fileURLWithPath: "/tmp/Var.java"))
        let enclosing = file.classes.first.map { [$0.qualifiedName] } ?? []
        let context = JavaResolutionContext(
            packageName: file.packageName, imports: file.imports, enclosingTypeQualifiedNames: enclosing
        )
        return await JavaExpressionTyper.typeOfReceiver(
            source: source, realTree: tree, dotOffset: dotOffset, context: context, index: index
        )
    }

    private func visible(_ source: String) -> [JavaLocalVariable] {
        let marker = source.range(of: "€")!
        let withoutMarker = source.replacingOccurrences(of: "€", with: "")
        let offset = source.utf8.distance(from: source.utf8.startIndex, to: marker.lowerBound.samePosition(in: source.utf8)!)
        return JavaSyntaxParser().parse(withoutMarker)!.visibleLocals(atByteOffset: offset)
    }

    private func argumentName(_ type: JavaTypeRef) -> String? {
        argumentNames(type).first
    }

    private func argumentNames(_ type: JavaTypeRef?) -> [String] {
        guard case .classType(_, let arguments, _) = type else { return [] }
        return arguments.compactMap { argument in
            switch argument {
            case .type(.classType(let name, _, _)): return name
            case .type(.primitive(let primitive)): return primitive.rawValue
            case .type(.unresolved(let name, _)): return name
            default: return nil
            }
        }
    }

    // MARK: - The two real misses: Optional.get() on an earlier local

    func testOptionalGetOnAnEarlierLocalIsTheTypeArgument() async throws {
        let index = try await makeIndex(withStubs: supportStubs())
        let source = """
        import java.util.Optional;
        class Foo { void m() {
            Optional<String> itemOptional = Optional.empty();
            var item = itemOptional.get();
            item€.
        } }
        """
        let locals = visible(source)
        let item = try XCTUnwrap(locals.first { $0.name == "item" })
        let earlier = try XCTUnwrap(locals.first { $0.name == "itemOptional" })
        XCTAssertEqual(item.initializerText, "itemOptional.get()", "registration keeps the initializer")
        XCTAssertTrue(item.isVarDeclaration)
        XCTAssertLessThan(try XCTUnwrap(earlier.declarationEnd), try XCTUnwrap(item.declarationEnd))

        let type = await typeOfReceiver(source, index: index)
        XCTAssertEqual(type, classType("java.lang.String"))
    }

    func testChainedVarThroughOptionalGet() async throws {
        let index = try await makeIndex(withStubs: supportStubs())
        let source = """
        import java.util.Optional;
        class Foo { void m() {
            var held = Optional.of("x");
            var item = held.get();
            item€.
        } }
        """
        let type = await typeOfReceiver(source, index: index)
        XCTAssertEqual(type, classType("java.lang.String"))
    }

    func testStandaloneOptionalGetChain() async throws {
        let index = try await makeIndex(withStubs: supportStubs())
        let source = """
        import java.util.Optional;
        class Foo { void m() { var item = Optional.of("x").get(); item€. } }
        """
        let type = await typeOfReceiver(source, index: index)
        XCTAssertEqual(type, classType("java.lang.String"))
    }

    func testCompletionOffersTheInferredMembers() async throws {
        let index = try await makeIndex(withStubs: supportStubs())
        let source = """
        import java.util.Optional;
        class Foo { void m() {
            Optional<String> itemOptional = Optional.empty();
            var item = itemOptional.get();
            item.€
        } }
        """
        let items = await complete(source, index: index)
        XCTAssertTrue(Set(items.map(\.label)).contains("trim"))
    }

    // MARK: - What javac rejects stays untyped

    func testForwardReferenceIsNotTypedFromTheLaterLocal() async throws {
        let index = try await makeIndex(withStubs: supportStubs())
        let source = """
        class Foo { void m() {
            var a = b;
            var b = 1;
            a€.
        } }
        """
        let type = await typeOfReceiver(source, index: index)
        XCTAssertNil(type)
        let locals = visible(source)
        let resolved = await JavaExpressionTyper.resolvingVarLocals(locals, context: JavaResolutionContext(packageName: "", imports: []), index: index)
        XCTAssertTrue(resolved.first { $0.name == "a" }?.isVarDeclaration == true)
        XCTAssertEqual(resolved.first { $0.name == "b" }?.type, .primitive(.int))
    }

    func testLaterVarStillHasItsOwnType() async throws {
        let index = try await makeIndex(withStubs: supportStubs())
        let source = """
        class Foo { void m() {
            var a = b;
            var b = 1;
            b€.
        } }
        """
        let type = await typeOfReceiver(source, index: index)
        XCTAssertEqual(type, .primitive(.int))
    }

    func testSelfReferenceDoesNotUseTheField() async throws {
        let index = try await makeIndex(withStubs: supportStubs())
        let bare = await typeOfReceiver("class Foo { int n = 1; void m() { var n = n; n€. } }", index: index)
        XCTAssertNil(bare)
        let added = await typeOfReceiver("class Foo { int n = 1; void m() { var n = n + 1; n€. } }", index: index)
        XCTAssertNil(added)
    }

    func testFieldAndMethodOfTheSameNameAreNotSelfReferences() async throws {
        let index = try await makeIndex(withStubs: supportStubs())
        let field = await typeOfReceiver("class Foo { int n = 1; void m() { var n = this.n; n€. } }", index: index)
        XCTAssertEqual(field, .primitive(.int))
        let call = await typeOfReceiver("class Foo { int n() { return 1; } void m() { var n = n(); n€. } }", index: index)
        XCTAssertEqual(call, .primitive(.int))
    }

    func testPolyInitializersStayUntyped() async throws {
        let index = try await makeIndex(withStubs: supportStubs())
        let lambda = await typeOfReceiver(
            "class Foo { void m() { var f = (String s) -> s.length(); f€. } }", index: index)
        XCTAssertNil(lambda)
        let reference = await typeOfReceiver(
            "class Foo { void m() { var g = String::length; g€. } }", index: index)
        XCTAssertNil(reference)
        let null = await typeOfReceiver("class Foo { void m() { var n = null; n€. } }", index: index)
        XCTAssertNil(null)
        let braces = await typeOfReceiver("class Foo { void m() { var ys = { 1, 2 }; ys€. } }", index: index)
        XCTAssertNil(braces)
    }

    func testCastAroundALambdaUsesTheCastType() async throws {
        let index = try await makeIndex(withStubs: supportStubs())
        let source = """
        import java.util.function.Function;
        class Foo { void m() {
            var f = (Function<String, Integer>) (s -> s.length());
            f€.
        } }
        """
        let inferred = await typeOfReceiver(source, index: index)
        let type = try XCTUnwrap(inferred)
        XCTAssertEqual(type.erasedQualifiedName, "java.util.function.Function")
        XCTAssertEqual(argumentName(type), "java.lang.String")
    }

    func testBrokenInitializerStaysUntyped() async throws {
        let index = try await makeIndex(withStubs: supportStubs())
        let source = """
        import java.util.Optional;
        class Foo { void m() {
            Optional<String> itemOptional = Optional.empty();
            var item = itemOptional.get(
            item€.
        } }
        """
        let type = await typeOfReceiver(source, index: index)
        XCTAssertNil(type)
    }

    // MARK: - Coverage

    func testPrimitiveAndReferenceInitializers() async throws {
        let index = try await makeIndex(withStubs: supportStubs())
        let cases: [(String, JavaTypeRef)] = [
            ("class Foo { void m() { var i = 1; i€. } }", .primitive(.int)),
            ("class Foo { void m() { var n = 1L; n€. } }", .primitive(.long)),
            ("class Foo { void m() { var n = 1.0; n€. } }", .primitive(.double)),
            ("class Foo { void m() { var n = true; n€. } }", .primitive(.boolean)),
            ("class Foo { void m() { var s = \"a\"; s€. } }", classType("java.lang.String")),
            ("class Foo { void m(String name) { var copy = name; copy€. } }", classType("java.lang.String"))
        ]
        for (source, expected) in cases {
            let type = await typeOfReceiver(source, index: index)
            XCTAssertEqual(type, expected, source)
        }
    }

    func testGenericFactoriesAndConstructors() async throws {
        let index = try await makeIndex(withStubs: supportStubs())
        let list = await typeOfReceiver(
            "import java.util.List; class Foo { void m() { var list = List.of(\"a\"); list€. } }", index: index)
        XCTAssertEqual(list?.erasedQualifiedName, "java.util.List")
        XCTAssertEqual(list.map(argumentName), "java.lang.String")

        let map = await typeOfReceiver(
            "import java.util.Map; class Foo { void m() { var map = Map.of(\"a\", 1); map€. } }", index: index)
        XCTAssertEqual(map?.erasedQualifiedName, "java.util.Map")
        XCTAssertEqual(argumentNames(map), ["java.lang.String", "java.lang.Integer"])

        let point = await typeOfReceiver(
            "class Foo { void m() { var p = new Point(); p€. } }", index: index)
        XCTAssertEqual(point?.erasedQualifiedName, "Point")

        let array = await typeOfReceiver(
            "class Foo { void m() { var xs = new String[] { \"a\" }; xs€. } }", index: index)
        XCTAssertEqual(array, .array(element: classType("java.lang.String")))
    }

    func testConditionalAndSwitchInitializers() async throws {
        let index = try await makeIndex(withStubs: supportStubs())
        let text = await typeOfReceiver(
            "class Foo { void m() { boolean flag = true; var s = flag ? \"a\" : \"b\"; s€. } }", index: index)
        XCTAssertEqual(text, classType("java.lang.String"))
        let promoted = await typeOfReceiver(
            "class Foo { void m() { boolean flag = true; var n = flag ? 1 : 2.5; n€. } }", index: index)
        XCTAssertEqual(promoted, .primitive(.double))
        let switched = await typeOfReceiver(
            "class Foo { void m() { var s = switch (1) { case 1 -> \"a\"; default -> \"b\"; }; s€. } }", index: index)
        XCTAssertEqual(switched, classType("java.lang.String"))
    }

    func testLoopsNestedLocalsAndResources() async throws {
        let index = try await makeIndex(withStubs: supportStubs())
        let enhanced = await typeOfReceiver(
            "import java.util.List; class Foo { void m(List<String> items) { for (var s : items) { s€. } } }",
            index: index)
        XCTAssertEqual(enhanced, classType("java.lang.String"))
        let classic = await typeOfReceiver(
            "class Foo { void m() { int n = 0; for (var i = n; i < 3; i++) { i€. } } }", index: index)
        XCTAssertEqual(classic, .primitive(.int))
        let nested = await typeOfReceiver(
            "class Foo { void m() { int n = 1; { var x = n; x€. } } }", index: index)
        XCTAssertEqual(nested, .primitive(.int))
        let resource = await typeOfReceiver(
            "class Foo { void m() { try (var input = new Point()) { input€. } } }", index: index)
        XCTAssertEqual(resource?.erasedQualifiedName, "Point")
        let field = await typeOfReceiver(
            "import java.util.List; class Foo { List<String> items; void m() { for (var item : items) { item€. } } }",
            index: index)
        XCTAssertEqual(field, classType("java.lang.String"))
    }

    func testAnonymousClassInitializerKeepsItsMembers() async throws {
        let index = try await makeIndex(withStubs: supportStubs())
        let source = "class Foo { void m() { var box = new Object() { int value = 1; }; box€. } }"
        let fileURL = URL(fileURLWithPath: "/tmp/Var.java")
        let context = JavaResolutionContext(packageName: "", imports: [], enclosingTypeQualifiedNames: ["Foo"])
        // The anonymous stub lives only for the request that types the initializer.
        let found = await JavaAnonymousClass.$registry.withValue(JavaAnonymousClass.Registry(fileURL: fileURL)) {
            let type = await typeOfReceiver(source, index: index)
            let members: [JavaResolvedMember]
            if let type {
                members = await JavaMemberLookup.members(of: type, mode: .instance, context: context, index: index)
            } else {
                members = []
            }
            return (type, members)
        }
        let type = try XCTUnwrap(found.0)
        XCTAssertTrue(type.erasedQualifiedName?.contains(JavaAnonymousClass.marker) == true)
        XCTAssertTrue(found.1.contains { member in
            if case .field(let field, _) = member { return field.name == "value" }
            return false
        })
        let diagnosis = await diagnose(source.replacingOccurrences(of: "€.", with: ".€"), index: index)
        XCTAssertEqual(diagnosis?.receiverType?.erasedQualifiedName, type.erasedQualifiedName)
    }

    func testInlayResolutionAgreesWithTheReceiver() async throws {
        let index = try await makeIndex(withStubs: supportStubs())
        let source = """
        import java.util.Optional;
        class Foo { void m() {
            Optional<String> itemOptional = Optional.empty();
            var item = itemOptional.get();
            item€.
        } }
        """
        let locals = visible(source)
        let file = JavaSourceStubBuilder.build(source: source.replacingOccurrences(of: "€", with: ""), url: URL(fileURLWithPath: "/tmp/Var.java"))
        let context = JavaResolutionContext(packageName: "", imports: file.imports, enclosingTypeQualifiedNames: ["Foo"])
        let resolved = await JavaExpressionTyper.resolvingVarLocals(locals, context: context, index: index)
        XCTAssertEqual(resolved.first { $0.name == "item" }?.type, classType("java.lang.String"))
        let receiver = await typeOfReceiver(source, index: index)
        XCTAssertEqual(receiver, resolved.first { $0.name == "item" }?.type)
    }

    /// Several declarators share one statement. Each name ends at its own UTF-8 offset, so a later
    /// declarator sees an earlier one and a forward reference does not. A multi-byte name, a CRLF
    /// line break, and an incremental reparse that inserts both keep that order.
    func testDeclaratorOrderSurvivesUnicodeCRLFAndIncrementalEdits() async throws {
        let index = try await makeIndex(withStubs: supportStubs())
        let second = await typeOfReceiver(
            "class Foo { void m() { var a = \"x\", b = a; b€. } }", index: index)
        XCTAssertEqual(second, classType("java.lang.String"))
        let first = await typeOfReceiver(
            "class Foo { void m() { var a = \"x\", b = a; a€. } }", index: index)
        XCTAssertEqual(first, classType("java.lang.String"))
        let forward = await typeOfReceiver(
            "class Foo { void m() { var a = b, b = 1; a€. } }", index: index)
        XCTAssertNil(forward)
        let laterInStatement = await typeOfReceiver(
            "class Foo { void m() { var a = b, b = 1; b€. } }", index: index)
        XCTAssertEqual(laterInStatement, .primitive(.int))
        let forPair = await typeOfReceiver(
            "class Foo { void m() { for (var i = 0, j = i; j < 2; j++) { j€. } } }", index: index)
        XCTAssertEqual(forPair, .primitive(.int))
        let unicodeName = await typeOfReceiver(
            """
            import java.util.List;
            class Foo { void m(List<String> café) { for (var item : café) { item€. } } }
            """,
            index: index)
        XCTAssertEqual(unicodeName, classType("java.lang.String"))
        let crlf = await typeOfReceiver(
            "import java.util.Optional;\r\nclass Foo { void m() {\r\n    Optional<String> itemOptional = Optional.empty();\r\n    var item = itemOptional.get();\r\n    item€.\r\n} }\r\n",
            index: index)
        XCTAssertEqual(crlf, classType("java.lang.String"))

        let url = URL(fileURLWithPath: "/tmp/VarIncremental.java")
        let cache = JavaDocumentParseCache()
        let prefix = "import java.util.Optional;\nclass Foo { void m() {\n"
        let body = "    Optional<String> itemOptional = Optional.empty();\n    var item = itemOptional.get();\n    item.\n} }\n"
        let original = prefix + body
        let parsed = await cache.tree(for: storedDocument(original, version: 0, url: url))
        let firstTree = try XCTUnwrap(parsed)
        let before = declarationEnds(in: firstTree, source: original)
        XCTAssertLessThan(try XCTUnwrap(before["itemOptional"]), try XCTUnwrap(before["item"]))
        let beforeReceiver = await receiver(in: firstTree, source: original, index: index)
        XCTAssertEqual(beforeReceiver, classType("java.lang.String"))

        let insertion = "    // café\r\n"
        let utf16 = (prefix as NSString).length
        let line = prefix.components(separatedBy: "\n").count - 1
        let column = (prefix.components(separatedBy: "\n").last ?? "").utf16.count
        let position = TextPosition(line: line, column: column, utf16Offset: utf16)
        let edit = TextEdit(range: TextRange(start: position, end: position), replacement: insertion)
        let edited = prefix + insertion + body
        let reparsed = await cache.tree(for: storedDocument(edited, version: 1, url: url), edits: [edit])
        let secondTree = try XCTUnwrap(reparsed)
        XCTAssertFalse(firstTree === secondTree)
        let after = declarationEnds(in: secondTree, source: edited)
        let shift = insertion.utf8.count
        XCTAssertEqual(try XCTUnwrap(after["itemOptional"]), try XCTUnwrap(before["itemOptional"]) + shift)
        XCTAssertEqual(try XCTUnwrap(after["item"]), try XCTUnwrap(before["item"]) + shift)
        XCTAssertLessThan(try XCTUnwrap(after["itemOptional"]), try XCTUnwrap(after["item"]))
        let afterReceiver = await receiver(in: secondTree, source: edited, index: index)
        XCTAssertEqual(afterReceiver, classType("java.lang.String"))
        let statistics = await cache.statistics
        XCTAssertEqual(statistics.incremental, 1)
        XCTAssertEqual(statistics.fullParses, 1)
    }

    // MARK: - Completion helpers

    private func document(_ source: String) -> Document {
        let marker = source.range(of: "€")!
        let text = source.replacingOccurrences(of: "€", with: "")
        let offset = source.utf16.distance(from: source.utf16.startIndex, to: marker.lowerBound.samePosition(in: source.utf16)!)
        let lines = String(text.utf16.prefix(offset))!.components(separatedBy: "\n")
        let position = TextPosition(line: lines.count - 1, column: (lines.last ?? "").utf16.count, utf16Offset: offset)
        return Document(
            id: DocumentID(), url: URL(fileURLWithPath: "/tmp/Var.java"), displayName: "Var.java",
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
        )
    }

    private func complete(_ source: String, index: JavaIndex) async -> [CompletionItem] {
        await JavaCompletionProvider(index: index).provide(context: makeCompletionContext(document: document(source), trigger: .keystroke(".")))
    }

    private func diagnose(_ source: String, index: JavaIndex) async -> JavaCompletionProvider.Diagnosis? {
        await JavaCompletionProvider(index: index).diagnose(context: makeCompletionContext(document: document(source), trigger: .keystroke(".")))
    }
}
