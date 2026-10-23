import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaInspectionServiceTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("java-inspections-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeIndex(stubs: [JavaClassStub] = []) async throws -> JavaIndex {
        let shard = scratch.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: shard))])
        return index
    }

    private func document(_ source: String, url: URL = URL(fileURLWithPath: "/proj/T.java")) -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            url: url, displayName: url.lastPathComponent,
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
    }

    func testUnusedImportInspectionFlagsRemovableImports() {
        let source = """
        import java.util.List;
        import java.util.Map;

        class T { List<String> names; }
        """
        let inspections = JavaUnusedImportInspection.inspect(source: source)
        XCTAssertEqual(inspections.map(\.id), ["unused-import"])
        XCTAssertEqual(inspections.first?.message, "Unused import 'java.util.Map'")
    }

    func testMissingOverrideInspectionFlagsOverridingMethodsWithoutAnnotation() async throws {
        let baseURL = scratch.appendingPathComponent("Base.java")
        try "class Base { void run() { } }".write(to: baseURL, atomically: true, encoding: .utf8)
        let childURL = scratch.appendingPathComponent("Child.java")
        let source = "class Child extends Base { void run() { } }"
        try source.write(to: childURL, atomically: true, encoding: .utf8)
        var stubs: [JavaClassStub] = []
        stubs.append(contentsOf: JavaSourceStubBuilder.build(source: try String(contentsOf: baseURL), url: baseURL).classes)
        stubs.append(contentsOf: JavaSourceStubBuilder.build(source: source, url: childURL).classes)
        let index = try await makeIndex(stubs: stubs)
        let inspections = await JavaMissingOverrideInspection.inspect(source: source, url: childURL, index: index)
        XCTAssertEqual(inspections.map(\.id), ["missing-override"])
        XCTAssertEqual(inspections.first?.fixTitle, "Add @Override")
    }

    func testMissingOverrideInspectionAcceptsAnnotatedOverride() async throws {
        let baseURL = scratch.appendingPathComponent("Handler.java")
        let baseSource = "interface Handler { void handleMessage(String event) throws Exception; }"
        try baseSource.write(to: baseURL, atomically: true, encoding: .utf8)
        let childURL = scratch.appendingPathComponent("Impl.java")
        let source = """
        class Impl implements Handler {
            @Override
            public void handleMessage(@NotNull String event) throws Exception { }
        }
        """
        try source.write(to: childURL, atomically: true, encoding: .utf8)
        var stubs: [JavaClassStub] = []
        stubs.append(contentsOf: JavaSourceStubBuilder.build(source: baseSource, url: baseURL).classes)
        stubs.append(contentsOf: JavaSourceStubBuilder.build(source: source, url: childURL).classes)
        let index = try await makeIndex(stubs: stubs)
        let inspections = await JavaMissingOverrideInspection.inspect(source: source, url: childURL, index: index)
        XCTAssertTrue(inspections.isEmpty)
    }

    private func missingOverrides(supertypes: [String], checking source: String) async throws -> [JavaInspection] {
        var stubs: [JavaClassStub] = []
        for (offset, text) in (supertypes + [source]).enumerated() {
            let url = scratch.appendingPathComponent("Source\(offset).java")
            stubs.append(contentsOf: JavaSourceStubBuilder.build(source: text, url: url).classes)
        }
        let index = try await makeIndex(stubs: stubs)
        return await JavaMissingOverrideInspection.inspect(source: source, url: scratch.appendingPathComponent("Checked.java"), index: index)
    }

    func testMissingOverrideInspectionIgnoresStaticAndPrivateMethods() async throws {
        let base = "class Base { static void util() { } private void hidden() { } }"
        let source = "class Child extends Base { static void util() { } private void hidden() { } }"
        let inspections = try await missingOverrides(supertypes: [base], checking: source)
        XCTAssertTrue(inspections.isEmpty)
    }

    func testMissingOverrideInspectionIgnoresStaticAndPrivateSuperMethods() async throws {
        let base = "class Base { static void util() { } private void hidden() { } }"
        let source = "class Child extends Base { void util() { } void hidden() { } }"
        let inspections = try await missingOverrides(supertypes: [base], checking: source)
        XCTAssertTrue(inspections.isEmpty)
    }

    func testMissingOverrideInspectionFollowsTheWholeSupertypeChain() async throws {
        let supertypes = ["class Base { void run() { } }", "class Mid extends Base { }"]
        let source = "class Leaf extends Mid { void run() { } }"
        let inspections = try await missingOverrides(supertypes: supertypes, checking: source)
        XCTAssertEqual(inspections.map(\.id), ["missing-override"])
    }

    func testMissingOverrideInspectionDoesNotAttributeNestedTypeMethodsToTheOuterType() async throws {
        let base = "class Base { void run() { } }"
        let source = """
        class Outer extends Base {
            @Override void run() { }
            class Inner { void run() { } }
            Runnable r = new Runnable() { public void run() { } };
        }
        """
        let inspections = try await missingOverrides(supertypes: [base], checking: source)
        XCTAssertTrue(inspections.isEmpty)
    }

    func testMissingOverrideFlagsGenericInterfaceOverride() async throws {
        let base = "interface Comparable<T> { int compareTo(T o); }"
        let source = "class Foo implements Comparable<Foo> { int compareTo(Foo o) { return 0; } }"
        let inspections = try await missingOverrides(supertypes: [base], checking: source)
        XCTAssertEqual(inspections.map(\.id), ["missing-override"])
    }

    func testMissingOverrideIgnoresOverloadAgainstGenericSupertype() async throws {
        let base = "interface Comparable<T> { int compareTo(T o); }"
        let source = "class Foo implements Comparable<Foo> { int compareTo(Bar o) { return 0; } }"
        let inspections = try await missingOverrides(supertypes: [base], checking: source)
        XCTAssertTrue(inspections.isEmpty)
    }

    func testMissingOverrideFlagsRawGenericSupertype() async throws {
        let base = "interface Comparable<T> { int compareTo(T o); }"
        let source = "class Foo implements Comparable { int compareTo(Object o) { return 0; } }"
        let inspections = try await missingOverrides(supertypes: [base], checking: source)
        XCTAssertEqual(inspections.map(\.id), ["missing-override"])
    }

    func testMissingOverrideIgnoresRawGenericOverload() async throws {
        let base = "interface Comparable<T> { int compareTo(T o); }"
        let source = "class Foo implements Comparable { int compareTo(String o) { return 0; } }"
        let inspections = try await missingOverrides(supertypes: [base], checking: source)
        XCTAssertTrue(inspections.isEmpty)
    }

    func testMissingOverrideFollowsGenericChainTwoLevels() async throws {
        let supertypes = ["class Base<T> { void put(T t) { } }", "class Mid<U> extends Base<List<U>> { }"]
        let source = "class Leaf extends Mid<String> { void put(List<String> l) { } }"
        let inspections = try await missingOverrides(supertypes: supertypes, checking: source)
        XCTAssertEqual(inspections.map(\.id), ["missing-override"])
    }

    func testMissingOverrideFlagsGenericMethodOverride() async throws {
        let base = "class Base { <U> void m(U u) { } }"
        let source = "class Child extends Base { <V> void m(V v) { } }"
        let inspections = try await missingOverrides(supertypes: [base], checking: source)
        XCTAssertEqual(inspections.map(\.id), ["missing-override"])
    }

    func testMissingOverrideIgnoresGenericMethodCountMismatch() async throws {
        let base = "class Base { <U> void m(U u) { } }"
        let source = "class Child extends Base { void m(Object o) { } }"
        let inspections = try await missingOverrides(supertypes: [base], checking: source)
        XCTAssertTrue(inspections.isEmpty)
    }

    func testMissingOverrideFlagsEnumConstantBody() async throws {
        let source = "enum E { A { void run() { } }; abstract void run(); }"
        let inspections = try await missingOverrides(supertypes: [], checking: source)
        XCTAssertEqual(inspections.map(\.id), ["missing-override"])
    }

    func testMissingOverrideFlagsAnonymousClass() async throws {
        let base = "interface Comparator<T> { int compare(T a, T b); }"
        let source = "class C { Comparator<String> c = new Comparator<String>() { public int compare(String a, String b) { return 0; } }; }"
        let inspections = try await missingOverrides(supertypes: [base], checking: source)
        XCTAssertEqual(inspections.map(\.id), ["missing-override"])
    }

    func testMissingOverrideIgnoresUnresolvableAnonymousType() async throws {
        let source = "class C { Object c = new Unknown() { void run() { } }; }"
        let inspections = try await missingOverrides(supertypes: [], checking: source)
        XCTAssertTrue(inspections.isEmpty)
    }

    func testMissingOverrideFlagsInterfaceObjectMethod() async throws {
        // JLS 9.2 gives interfaces Object's public methods; redeclaring one is an override.
        let object = "package java.lang; public class Object { public boolean equals(Object o) { return true; } }"
        let source = "interface C { boolean equals(Object o); }"
        let inspections = try await missingOverrides(supertypes: [object], checking: source)
        XCTAssertEqual(inspections.map(\.id), ["missing-override"])
    }

    func testUnresolvedTypeInspectionWarnsWhenNoCandidateExists() async throws {
        let index = try await makeIndex()
        let source = "class T { UnknownType value; }"
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        let walker = JavaSemanticWalker(tree: tree, source: source)
        XCTAssertTrue(walker.run())
        let inspections = await JavaUnresolvedTypeInspection.inspect(
            source: source,
            url: scratch.appendingPathComponent("T.java"),
            index: index,
            walker: walker
        )
        XCTAssertEqual(inspections.map(\.id), ["unresolved-type"])
        XCTAssertEqual(inspections.first?.message, "Cannot resolve type 'UnknownType'")
    }

    func testEditedTextIsMarkedStaleUntilThePassLands() async throws {
        let index = try await makeIndex()
        let service = JavaInspectionService(
            index: index,
            enabledRules: [.unusedImport],
            idleDelay: .milliseconds(1)
        )
        let url = scratch.appendingPathComponent("T.java")
        let valid = "import java.util.Map;\n\nclass T { int x; }\n"
        let box = ResultBox()
        await service.setResultHandler { url, diagnostics in box.append(url, diagnostics) }
        await service.analyzeNow(document(valid, url: url), force: true)

        let (freshDiagnostics, freshStale) = await service.diagnosticsWithFreshness(for: document(valid, url: url))
        XCTAssertEqual(freshStale, [])
        XCTAssertEqual(freshDiagnostics.map(\.code), ["unused-import"])

        // The edit schedules a new pass; until it lands the previous text's findings
        // are reported stale instead of drawn at dead positions.
        let edited = valid + "// typed\n"
        let (staleDiagnostics, stale) = await service.diagnosticsWithFreshness(for: document(edited, url: url))
        XCTAssertEqual(stale, ["java-inspection"])
        XCTAssertEqual(staleDiagnostics.map(\.code), ["unused-import"])

        let deadline = Date().addingTimeInterval(5)
        while await !service.isFresh(document(edited, url: url)), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let (_, landedStale) = await service.diagnosticsWithFreshness(for: document(edited, url: url))
        XCTAssertEqual(landedStale, [])
    }

    func testDependencySourceIsNeverInspected() async throws {
        let index = try await makeIndex()
        let service = JavaInspectionService(index: index, enabledRules: [.unusedImport], idleDelay: .milliseconds(1))
        let box = ResultBox()
        await service.setResultHandler { url, diagnostics in box.append(url, diagnostics) }
        let library = document(
            "import java.util.Map;\n\nclass T { int x; }\n",
            url: URL(fileURLWithPath: "/cache/JavaIndex/attached-sources/decompiled/ab12/org/x/T.java")
        )
        XCTAssertTrue(library.isDependencySource)

        await service.analyzeNow(library, force: true)
        await service.runProjectInspections(for: library)
        let diagnostics = await service.diagnostics(for: library)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(diagnostics.isEmpty)
        XCTAssertTrue(box.results.isEmpty)
        let fresh = await service.isFresh(library)
        XCTAssertTrue(fresh, "a dependency file is never pending, so the Problems panel never marks it stale")
        XCTAssertFalse(document("class T {}", url: URL(fileURLWithPath: "/proj/src/T.java")).isDependencySource)
    }

    func testInspectionServiceAnalyzeNowPublishesDiagnostics() async throws {
        let index = try await makeIndex()
        let service = JavaInspectionService(
            index: index,
            enabledRules: [.unusedImport, .duplicateImport, .missingOverride, .unresolvedType, .classFileNameMismatch],
            idleDelay: .milliseconds(10)
        )
        let url = scratch.appendingPathComponent("T.java")
        let source = """
        import java.util.Map;

        class T { int x; }
        """
        let box = ResultBox()
        await service.setResultHandler { url, diagnostics in box.append(url, diagnostics) }
        await service.analyzeNow(document(source, url: url), force: true)
        let diagnostics = box.results.last?.1 ?? []
        XCTAssertEqual(diagnostics.map(\.code), ["unused-import"])
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(URL, [Diagnostic])] = []
    func append(_ url: URL, _ diagnostics: [Diagnostic]) { lock.lock(); stored.append((url, diagnostics)); lock.unlock() }
    var results: [(URL, [Diagnostic])] { lock.lock(); defer { lock.unlock() }; return stored }
}
