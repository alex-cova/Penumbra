import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// IntelliJ-style Java completion contexts: packaged files, overloads, local scopes, `super`,
/// `var`, nested types, imports, `new`, annotations, `case`, static context, auto-import,
/// expected type, override stubs, and parameter info.
final class JavaCompletionProviderContextTests: XCTestCase {
    private let fileURL = URL(fileURLWithPath: "/tmp/penumbra-tests/Foo.java")

    /// JDK-like stubs go into a shard; `indexedSource` (a complete version of the file) is
    /// indexed as the live overlay, the way Umbra indexes open documents.
    private func makeIndex(stubs: [JavaClassStub], indexedSource: String? = nil) async throws -> JavaIndex {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: try JavaIndexShardReader(url: url))])
        if let indexedSource {
            let fileStubs = JavaSourceStubBuilder.build(source: indexedSource, url: fileURL)
            await index.setOverlay(Dictionary(uniqueKeysWithValues: fileStubs.classes.map { ($0.qualifiedName, $0) }))
        }
        return index
    }

    private func context(_ source: String, trigger: RequestTrigger = .manual) -> CompletionContext {
        let marker = source.range(of: "€")!
        let text = source.replacingOccurrences(of: "€", with: "")
        let offset = source.utf16.distance(from: source.utf16.startIndex, to: marker.lowerBound.samePosition(in: source.utf16)!)
        let lines = String(text.utf16.prefix(offset))!.components(separatedBy: "\n")
        let position = TextPosition(line: lines.count - 1, column: (lines.last ?? "").utf16.count, utf16Offset: offset)
        let document = Document(
            id: DocumentID(), url: fileURL, displayName: "Foo.java", contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
        )
        return makeCompletionContext(document: document, trigger: trigger)
    }

    private func complete(_ source: String, index: JavaIndex, trigger: RequestTrigger = .manual) async -> [CompletionItem] {
        await JavaCompletionProvider(index: index).provide(context: context(source, trigger: trigger))
    }

    private func ranked(_ items: [CompletionItem], prefix: String) -> [String] {
        DefaultRanker().rankSynchronously(items: items, prefix: prefix).map(\.item.label)
    }

    private func labels(_ items: [CompletionItem]) -> Set<String> {
        Set(items.map(\.label))
    }

    private func classType(_ name: String, _ arguments: [JavaTypeRef] = []) -> JavaTypeRef {
        .classType(qualifiedName: name, arguments: arguments.map { .type($0) }, outer: nil)
    }

    private func stub(
        _ qualifiedName: String, kind: JavaTypeKind = .classKind, modifiers: JavaModifiers = [.publicFlag],
        typeParameters: [JavaTypeParameter] = [], superclass: JavaTypeRef? = nil, fields: [JavaFieldStub] = [],
        methods: [JavaMethodStub] = [], inner: [String] = [], outer: String? = nil
    ) -> JavaClassStub {
        let simpleName = String(qualifiedName.split(separator: ".").last!)
        let packageName: String
        if let outer {
            packageName = String(outer.split(separator: ".").dropLast().joined(separator: "."))
        } else {
            packageName = qualifiedName.split(separator: ".").dropLast().joined(separator: ".")
        }
        return JavaClassStub(
            binaryName: qualifiedName, qualifiedName: qualifiedName, simpleName: simpleName, packageName: packageName,
            outerQualifiedName: outer, kind: kind, modifiers: modifiers, typeParameters: typeParameters, superclass: superclass,
            fields: fields, methods: methods, innerTypeNames: inner, origin: .jdkModule("test")
        )
    }

    private func method(_ name: String, _ parameters: [(String?, JavaTypeRef)] = [], returns: JavaTypeRef = .void, modifiers: JavaModifiers = [.publicFlag]) -> JavaMethodStub {
        JavaMethodStub(name: name, parameters: parameters.map { JavaParameterStub(name: $0.0, type: $0.1) }, returnType: returns, modifiers: modifiers)
    }

    private var stringStub: JavaClassStub {
        stub("java.lang.String", modifiers: [.publicFlag, .finalFlag], methods: [
            method("length", returns: .primitive(.int)),
            method("trim", returns: classType("java.lang.String"))
        ])
    }

    // MARK: - Packaged files (enclosing types must be package-qualified)

    func testThisMembersInPackagedFile() async throws {
        let source = "package com.acme;\nclass Foo { private int secret; void run() {} void m() { this.€ } }"
        let index = try await makeIndex(stubs: [], indexedSource: source.replacingOccurrences(of: "this.€", with: ""))
        let items = await complete(source, index: index)
        XCTAssertTrue(labels(items).contains("secret"))
        XCTAssertTrue(labels(items).contains("run"))
    }

    func testImplicitThisMembersInPackagedFile() async throws {
        let source = "package com.acme;\nclass Foo { private int secret; void m() { sec€ } }"
        let index = try await makeIndex(stubs: [], indexedSource: source.replacingOccurrences(of: "sec€", with: ""))
        let items = await complete(source, index: index)
        XCTAssertEqual(ranked(items, prefix: "sec").first, "secret")
    }

    func testStaticContextOffersOnlyStaticMembers() async throws {
        let source = "class Foo { int inst; static int stat; static void m() { €} }"
        let index = try await makeIndex(stubs: [], indexedSource: source.replacingOccurrences(of: "€", with: ""))
        let items = await complete(source, index: index)
        XCTAssertTrue(labels(items).contains("stat"))
        XCTAssertFalse(labels(items).contains("inst"))
    }

    // MARK: - Items

    func testOverloadsAreSeparateRowsWithSignatures() async throws {
        let printer = stub("Printer", methods: [
            method("print", [("s", classType("java.lang.String"))]),
            method("print", [("i", .primitive(.int))]),
            method("flush")
        ])
        let index = try await makeIndex(stubs: [printer, stringStub])
        let items = await complete("class Foo { void m(Printer p) { p.€ } }", index: index)
        let prints = items.filter { $0.label == "print" }
        XCTAssertEqual(Set(prints.compactMap(\.labelDetail)), ["(String s)", "(int i)"])
        XCTAssertTrue(prints.allSatisfy { $0.caretOffset == 6 && $0.triggersSignatureHelp })
        let flush = try XCTUnwrap(items.first { $0.label == "flush" })
        XCTAssertNil(flush.caretOffset)
        XCTAssertFalse(flush.triggersSignatureHelp)

        let engine = CompletionEngine(providers: [JavaCompletionProvider(index: index)], debounceInterval: 0)
        let results = try await engine.complete(context: context("class Foo { void m(Printer p) { p.pr€ } }"))
        XCTAssertEqual(results.filter { $0.label == "print" }.count, 2)
    }

    func testOwnMembersRankAboveObjectMembers() async throws {
        let object = stub("java.lang.Object", methods: [method("hashCode", returns: .primitive(.int)), method("equals", [("o", classType("java.lang.Object"))], returns: .primitive(.boolean))])
        let bar = stub("Bar", methods: [method("halt")])
        let index = try await makeIndex(stubs: [object, bar])
        let items = await complete("class Foo { void m(Bar bar) { bar.h€ } }", index: index)
        XCTAssertEqual(ranked(items, prefix: "h"), ["halt", "hashCode"])
    }

    func testDeprecatedMembersAreMarkedAndRankLower() async throws {
        let bar = stub("Bar", methods: [
            method("getOld", modifiers: [.publicFlag, .deprecatedFlag]),
            method("getNew")
        ])
        let index = try await makeIndex(stubs: [bar])
        let items = await complete("class Foo { void m(Bar bar) { bar.get€ } }", index: index)
        XCTAssertEqual(ranked(items, prefix: "get"), ["getNew", "getOld"])
        XCTAssertTrue(try XCTUnwrap(items.first { $0.label == "getOld" }).isDeprecated)
    }

    func testCamelHumpFindsMembers() async throws {
        let bar = stub("Bar", methods: [method("getName", returns: classType("java.lang.String")), method("getNumber", returns: .primitive(.int))])
        let index = try await makeIndex(stubs: [bar, stringStub])
        let items = await complete("class Foo { void m(Bar bar) { bar.gNa€ } }", index: index)
        XCTAssertEqual(ranked(items, prefix: "gNa"), ["getName"])
    }

    // MARK: - Local scopes

    func testClassicForLoopVariable() async throws {
        let index = try await makeIndex(stubs: [])
        let items = await complete("class Foo { void m() { for (int index = 0; index < 3; index++) { ind€ } } }", index: index)
        XCTAssertTrue(labels(items).contains("index"))
    }

    func testImplicitlyTypedLambdaParameters() async throws {
        let index = try await makeIndex(stubs: [])
        let items = await complete("class Foo { void m() { run((alpha, beta) -> al€); } }", index: index)
        XCTAssertTrue(labels(items).contains("alpha"))
        XCTAssertTrue(labels(items).contains("beta"))
    }

    func testCatchParameterAndPatternBinding() async throws {
        let index = try await makeIndex(stubs: [])
        let caught = await complete("class Foo { void m() { try { } catch (RuntimeException failure) { fa€ } } }", index: index)
        XCTAssertTrue(labels(caught).contains("failure"))
        let pattern = await complete("class Foo { void m(Object o) { if (o instanceof String text) { te€ } } }", index: index)
        XCTAssertTrue(labels(pattern).contains("text"))
    }

    // MARK: - Receivers

    func testSuperMembers() async throws {
        let base = stub("p.Base", methods: [method("baseMethod")])
        let source = "package p;\nclass Foo extends Base { void m() { super.€ } }"
        let index = try await makeIndex(stubs: [base], indexedSource: source.replacingOccurrences(of: "super.€", with: ""))
        let items = await complete(source, index: index)
        XCTAssertTrue(labels(items).contains("baseMethod"))
    }

    func testVarLocalIsTypedFromInitializer() async throws {
        let bar = stub("Bar", methods: [method("getValue", returns: .primitive(.int))])
        let index = try await makeIndex(stubs: [bar])
        let items = await complete("class Foo { void m() { var b = new Bar(); b.€ } }", index: index)
        XCTAssertTrue(labels(items).contains("getValue"))
    }

    func testNestedTypeThroughQualifier() async throws {
        let map = stub("java.util.Map", kind: .interfaceKind, inner: ["java.util.Map.Entry"])
        let entry = stub("java.util.Map.Entry", kind: .interfaceKind, methods: [
            method("comparingByKey", modifiers: [.publicFlag, .staticFlag]),
            method("getKey")
        ], outer: "java.util.Map")
        let index = try await makeIndex(stubs: [map, entry])
        let items = await complete("import java.util.Map;\nclass Foo { void m() { Map.Entry.€ } }", index: index)
        XCTAssertTrue(labels(items).contains("comparingByKey"))
        XCTAssertFalse(labels(items).contains("getKey"))

        let onMap = await complete("import java.util.Map;\nclass Foo { void m() { Map.€ } }", index: index)
        XCTAssertTrue(labels(onMap).contains("Entry"))
        XCTAssertTrue(labels(onMap).contains("class"))
    }

    func testFullyQualifiedReceiver() async throws {
        let collections = stub("java.util.Collections", methods: [method("emptyList", modifiers: [.publicFlag, .staticFlag])])
        let index = try await makeIndex(stubs: [collections])
        let items = await complete("class Foo { void m() { java.util.Collections.€ } }", index: index)
        XCTAssertTrue(labels(items).contains("emptyList"))
        let packageItems = await complete("class Foo { void m() { java.util.€ } }", index: index)
        XCTAssertTrue(labels(packageItems).contains("Collections"))
    }

    func testGenericMethodReturnTypeIsInferredFromArgument() async throws {
        let optional = stub("java.util.Optional", typeParameters: [JavaTypeParameter(name: "T", bounds: [])], methods: [
            JavaMethodStub(
                name: "of", typeParameters: [JavaTypeParameter(name: "T", bounds: [])],
                parameters: [JavaParameterStub(name: "value", type: .typeVariable(name: "T"))],
                returnType: .classType(qualifiedName: "java.util.Optional", arguments: [.type(.typeVariable(name: "T"))], outer: nil),
                modifiers: [.publicFlag, .staticFlag]
            ),
            method("get", returns: .typeVariable(name: "T"))
        ])
        let index = try await makeIndex(stubs: [optional, stringStub])
        let items = await complete("import java.util.Optional;\nclass Foo { void m() { Optional.of(\"x\").get().€ } }", index: index)
        XCTAssertTrue(labels(items).contains("trim"))
    }

    // MARK: - Sites

    func testImportCompletion() async throws {
        let list = stub("java.util.ArrayList")
        let index = try await makeIndex(stubs: [list])
        let packages = await complete("import java.u€", index: index)
        XCTAssertTrue(labels(packages).contains("util"))
        XCTAssertEqual(packages.first { $0.label == "util" }?.kind, .package)
        let classes = await complete("import java.util.€", index: index)
        XCTAssertTrue(labels(classes).contains("ArrayList"))
        XCTAssertTrue(classes.allSatisfy(\.additionalEdits.isEmpty))
    }

    func testNewExpressionOffersConstructorWithDiamondAndImport() async throws {
        let arrayList = stub("java.util.ArrayList", typeParameters: [JavaTypeParameter(name: "E", bounds: [])], methods: [
            JavaMethodStub(name: "<init>", parameters: [], returnType: .void, modifiers: [.publicFlag], isConstructor: true),
            JavaMethodStub(name: "<init>", parameters: [JavaParameterStub(name: "capacity", type: .primitive(.int))], returnType: .void, modifiers: [.publicFlag], isConstructor: true)
        ])
        let index = try await makeIndex(stubs: [arrayList])
        let items = await complete("package com.acme;\n\nclass Foo { void m() { Object o = new ArrLi€ } }", index: index)
        let item = try XCTUnwrap(items.first { $0.label == "ArrayList" })
        XCTAssertEqual(item.insertText, "ArrayList<>()")
        XCTAssertEqual(item.caretOffset, 12)
        XCTAssertEqual(item.additionalEdits.map(\.replacement), ["\n\nimport java.util.ArrayList;"])
        XCTAssertEqual(ranked(items, prefix: "ArrLi").first, "ArrayList")
    }

    func testAnnotationCompletion() async throws {
        let override = stub("java.lang.Override", kind: .annotationKind)
        let list = stub("java.util.ArrayList")
        let index = try await makeIndex(stubs: [override, list])
        let items = await complete("class Foo { @Over€ void m() {} }", index: index)
        XCTAssertTrue(labels(items).contains("Override"))
        XCTAssertFalse(labels(items).contains("ArrayList"))
        let empty = await complete("class Foo { @€ void m() {} }", index: index)
        XCTAssertTrue(labels(empty).contains("Override"))
    }

    func testCaseLabelOffersEnumConstants() async throws {
        let color = stub("Color", kind: .enumKind, fields: [
            JavaFieldStub(name: "RED", type: classType("Color"), modifiers: [.publicFlag, .staticFlag, .finalFlag, .enumConstant]),
            JavaFieldStub(name: "GREEN", type: classType("Color"), modifiers: [.publicFlag, .staticFlag, .finalFlag, .enumConstant])
        ])
        let index = try await makeIndex(stubs: [color])
        let items = await complete("class Foo { void m(Color c) { switch (c) { case €} } }", index: index)
        XCTAssertEqual(labels(items), ["RED", "GREEN"])
        XCTAssertTrue(items.allSatisfy { $0.kind == .enumMember })
    }

    func testStringAndCommentPositionsOfferNothing() async throws {
        let index = try await makeIndex(stubs: [stringStub])
        let inString = await complete("class Foo { void m() { String s = \"Str€\"; } }", index: index)
        XCTAssertEqual(inString, [])
        let inComment = await complete("class Foo { // Str€\n }", index: index)
        XCTAssertEqual(inComment, [])
    }

    // MARK: - Auto-import

    func testClassCompletionAddsSortedImport() async throws {
        let arrayList = stub("java.util.ArrayList")
        let index = try await makeIndex(stubs: [arrayList])
        let source = "package com.acme;\n\nimport java.util.List;\n\nclass Foo { void m() { ArrayL€ } }"
        let items = await complete(source, index: index)
        let item = try XCTUnwrap(items.first { $0.label == "ArrayList" })
        let edit = try XCTUnwrap(item.additionalEdits.first)
        XCTAssertEqual(edit.replacement, "import java.util.ArrayList;\n")
        XCTAssertEqual(edit.range.start.line, 2)
        XCTAssertEqual(edit.range.start.column, 0)
    }

    func testAlreadyImportedOrJavaLangNeedsNoImport() async throws {
        let arrayList = stub("java.util.ArrayList")
        let index = try await makeIndex(stubs: [arrayList, stringStub])
        let imported = await complete("import java.util.*;\nclass Foo { void m() { ArrayL€ } }", index: index)
        XCTAssertEqual(imported.first { $0.label == "ArrayList" }?.additionalEdits, [])
        let javaLang = await complete("class Foo { void m() { Stri€ } }", index: index)
        XCTAssertEqual(javaLang.first { $0.label == "String" }?.additionalEdits, [])
    }

    func testSimpleNameClashInsertsQualifiedName() async throws {
        let awtList = stub("java.awt.List")
        let index = try await makeIndex(stubs: [awtList])
        let items = await complete("import java.util.List;\nclass Foo { void m() { Lis€ } }", index: index)
        XCTAssertEqual(items.first { $0.label == "List" }?.insertText, "java.awt.List")
    }

    // MARK: - Expected type

    func testExpectedTypeFromDeclarationIsPreselected() async throws {
        let index = try await makeIndex(stubs: [stringStub])
        let items = await complete("class Foo { void m() { String name = \"\"; int count = 0; String s = €} }", index: index)
        XCTAssertEqual(items.first { $0.label == "name" }?.preselect, true)
        XCTAssertEqual(items.first { $0.label == "count" }?.preselect, false)
        XCTAssertEqual(ranked(items, prefix: "").first, "name")
    }

    func testExpectedTypeFromMethodArgument() async throws {
        let bar = stub("Bar", methods: [method("take", [("n", .primitive(.int))])])
        let index = try await makeIndex(stubs: [bar, stringStub])
        let items = await complete("class Foo { void m(Bar bar, String text, int size) { bar.take(€) } }", index: index)
        XCTAssertEqual(items.first { $0.label == "size" }?.preselect, true)
        XCTAssertEqual(items.first { $0.label == "text" }?.preselect, false)
    }

    // MARK: - Class body

    func testOverrideCompletionInsertsStub() async throws {
        let base = stub("Base", methods: [
            method("hook", [("count", .primitive(.int))], returns: .primitive(.boolean)),
            method("done", modifiers: [.publicFlag, .finalFlag])
        ])
        let source = "class Foo extends Base {\n    ho€\n}"
        let index = try await makeIndex(stubs: [base], indexedSource: source.replacingOccurrences(of: "ho€", with: ""))
        let items = await complete(source, index: index)
        let hook = try XCTUnwrap(items.first { $0.label == "hook" && $0.insertTextIsSnippet })
        XCTAssertEqual(hook.insertText, "@Override\n    public boolean hook(int count) {\n        return super.hook(count);$0\n    }")
        XCTAssertFalse(items.contains { $0.label == "done" && $0.insertTextIsSnippet })
        XCTAssertTrue(labels(items).contains("private"))
    }

    // MARK: - Parameter info

    func testSignatureHelpListsOverloadsAndActiveParameter() async throws {
        let bar = stub("Bar", methods: [
            method("put", [("key", classType("java.lang.String")), ("value", .primitive(.int))]),
            method("put", [("key", classType("java.lang.String"))])
        ])
        let index = try await makeIndex(stubs: [bar, stringStub])
        let provider = JavaCompletionProvider(index: index)
        let requestContext = context("class Foo { void m(Bar bar) { bar.put(\"a\", €) } }")
        let help = await provider.signatureHelp(for: requestContext.document, at: requestContext.cursor.position)
        let model = try XCTUnwrap(help)
        XCTAssertEqual(model.signatures, ["void put(String key)", "void put(String key, int value)"])
        XCTAssertEqual(model.activeParameter, 1)
        XCTAssertEqual(model.activeSignature, 1)
    }

    func testPrimaryForJavaOnly() {
        let provider = JavaCompletionProvider(index: JavaIndex())
        XCTAssertTrue(provider.isPrimary(for: context("class Foo { €}")))
    }
}
