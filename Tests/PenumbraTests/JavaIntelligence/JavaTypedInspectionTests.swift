import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// Rules that resolve types through the index: static access via an instance, redundant varargs arrays.
final class JavaTypedInspectionTests: XCTestCase {
    private var scratch: URL!
    private let url = URL(fileURLWithPath: "/proj/T.java")

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("java-typed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// An index holding the classes declared in `libraries`, then the typed findings for `source`.
    private func findings(_ source: String, libraries: String, deprecated: Set<String> = []) async throws -> [JavaInspection] {
        let shard = scratch.appendingPathComponent("\(UUID().uuidString).idx")
        let built = JavaSourceStubBuilder.build(source: libraries, url: scratch.appendingPathComponent("Lib.java")).classes
        // Source stubs do not carry `@Deprecated`, which class-file stubs do; mark the named methods.
        let stubs = built.map { stub in
            JavaClassStub(
                binaryName: stub.binaryName, qualifiedName: stub.qualifiedName, simpleName: stub.simpleName, packageName: stub.packageName,
                outerQualifiedName: stub.outerQualifiedName, kind: stub.kind, modifiers: stub.modifiers, typeParameters: stub.typeParameters,
                superclass: stub.superclass, interfaces: stub.interfaces, fields: stub.fields,
                methods: stub.methods.map { method in
                    guard deprecated.contains(method.name) else { return method }
                    return JavaMethodStub(
                        name: method.name, typeParameters: method.typeParameters, parameters: method.parameters, returnType: method.returnType,
                        thrownTypes: method.thrownTypes, modifiers: method.modifiers.union(.deprecatedFlag), isConstructor: method.isConstructor
                    )
                },
                innerTypeNames: stub.innerTypeNames, origin: stub.origin
            )
        }
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: shard))])
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        let context = try XCTUnwrap(JavaInspectionContext(source: source, tree: tree, url: url, index: index))
        return await JavaInspectionRunner.runTyped(context: context, enabled: Set(JavaInspectionRule.allCases))
    }

    private func fixed(_ source: String, _ inspection: JavaInspection) throws -> String? {
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        guard let action = JavaInspectionRegistry.fixes(for: inspection.asDiagnostic(), tree: tree, source: source).first else { return nil }
        var text = source as NSString
        for edit in action.edits {
            let range = NSRange(location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset)
            text = text.replacingCharacters(in: range, with: edit.replacement) as NSString
        }
        return text as String
    }

    private let util = """
    class Util {
        static int twice(int x) { return x * 2; }
        int plain() { return 1; }
        static void both() { }
        void both(int a) { }
    }
    """

    func testStaticMethodCalledThroughAnInstance() async throws {
        let source = "class T { int f(Util u) { u.plain(); u.both(1); u.both(); return u.twice(2); } }"
        let found = try await findings(source, libraries: util)
        XCTAssertEqual(found.map(\.id), ["access-static-via-instance", "access-static-via-instance"])
        XCTAssertEqual(found.map(\.message), [
            "Static method 'both()' is accessed via instance reference 'u'",
            "Static method 'twice()' is accessed via instance reference 'u'",
        ])
        let twice = try XCTUnwrap(found.last)
        XCTAssertEqual(try fixed(source, twice), "class T { int f(Util u) { u.plain(); u.both(1); u.both(); return Util.twice(2); } }")
    }

    func testStaticCallsThroughTheTypeAndUnknownReceiversAreLeftAlone() async throws {
        let direct = "class T { int f(Util u) { Util.both(); return Util.twice(2); } }"
        let unknownType = "class T { int f(Mystery m) { return m.twice(2); } }"
        let chained = "class T { int f(Util u) { return u.plain() + make().twice(2); } Util make() { return null; } }"
        let directFindings = try await findings(direct, libraries: util)
        let unknownFindings = try await findings(unknownType, libraries: util)
        let chainedFindings = try await findings(chained, libraries: util)
        XCTAssertEqual(directFindings.count, 0)
        XCTAssertEqual(unknownFindings.count, 0)
        XCTAssertEqual(chainedFindings.count, 0)
    }

    private let varargs = """
    class V {
        static void log(String... parts) { }
        static void pair(String... parts) { }
        static void pair(String a, String b) { }
        static void objects(Object... values) { }
    }
    """

    func testRedundantArrayCreationForAVarargsCall() async throws {
        let source = "class T { void f() { V.log(new String[]{\"a\", \"b\"}); } }"
        let found = try await findings(source, libraries: varargs)
        XCTAssertEqual(found.map(\.id), ["redundant-array-creation"])
        XCTAssertEqual(try fixed(source, try XCTUnwrap(found.first)), "class T { void f() { V.log(\"a\", \"b\"); } }")
    }

    func testRedundantArrayCreationStaysQuietWhenUnwrappingCouldChangeTheCall() async throws {
        // `pair("a", "b")` would bind to the two-String overload instead.
        let rival = "class T { void f() { V.pair(new String[]{\"a\", \"b\"}); } }"
        // A lone element of `Object[]` may itself be an array.
        let wrapped = "class T { void f(Object[] arr) { V.objects(new Object[]{arr}); } }"
        // Not an array of the varargs element type.
        let mismatch = "class T { void f() { V.objects(new String[]{\"a\", \"b\"}); } }"
        let empty = "class T { void f() { V.log(new String[]{}); } }"
        let rivalFindings = try await findings(rival, libraries: varargs)
        let wrappedFindings = try await findings(wrapped, libraries: varargs)
        let mismatchFindings = try await findings(mismatch, libraries: varargs)
        let emptyFindings = try await findings(empty, libraries: varargs)
        XCTAssertEqual(rivalFindings.count, 0)
        XCTAssertEqual(wrappedFindings.count, 0)
        XCTAssertEqual(mismatchFindings.count, 0)
        XCTAssertEqual(emptyFindings.count, 0)
    }

    private let bag = """
    class Bag { int size() { return 0; } boolean isEmpty() { return true; } }
    class Counter { int size() { return 0; } }
    """

    func testSizeComparedWithZeroOnATypeWithIsEmpty() async throws {
        let source = "class T { boolean f(Bag b, Counter c) { return b.size() == 0 || b.size() > 0 || b.size() >= 1 || b.size() < 1 || b.size() == 5 || c.size() == 0; } }"
        let found = try await findings(source, libraries: bag)
        XCTAssertEqual(found.map(\.id), Array(repeating: "size-comparison-with-zero", count: 4))
        XCTAssertEqual(found.map(\.message), [
            "'size()' compared with zero; use 'b.isEmpty()'", "'size()' compared with zero; use '!b.isEmpty()'",
            "'size()' compared with zero; use '!b.isEmpty()'", "'size()' compared with zero; use 'b.isEmpty()'",
        ])
        let negated = "class T { boolean f(Bag b) { return b.size() != 0; } }"
        let negatedFindings = try await findings(negated, libraries: bag)
        XCTAssertEqual(try fixed(negated, try XCTUnwrap(negatedFindings.first)), "class T { boolean f(Bag b) { return !b.isEmpty(); } }")
    }

    func testDeprecatedMethodsOnTypedReceivers() async throws {
        let library = "class Util { void old() { } void fresh() { } static void legacy() { } }"
        let source = "class T { void f(Util u) { u.old(); u.fresh(); Util.legacy(); } @Deprecated void g(Util u) { u.old(); } }"
        let found = try await findings(source, libraries: library, deprecated: ["old", "legacy"])
        XCTAssertEqual(found.map(\.id), ["deprecated-api-usage", "deprecated-api-usage"])
        XCTAssertEqual(found.map(\.message), ["'old()' is deprecated", "'legacy()' is deprecated"])
        let none = try await findings(source, libraries: library)
        XCTAssertEqual(none.count, 0)
    }

    func testTypedRulesSkipVeryLargeFiles() async throws {
        let filler = String(repeating: "\n", count: JavaInspectionRunner.maxTypedLineCount + 1)
        let source = "class T { int f(Util u) { return u.twice(2); } }" + filler
        let found = try await findings(source, libraries: util)
        XCTAssertEqual(found.count, 0)
    }

    private let functional = """
    interface Job { int run(int n); }
    interface Two { void a(); void b(); }
    interface Base { void go(); }
    interface Derived extends Base { String toString(); boolean equals(Object o); default void more() { } }
    abstract class Task { abstract void run(); }
    """

    func testAnonymousClassOfAFunctionalInterfaceCanBeALambda() async throws {
        let source = "class T { Job j = new Job() { @Override public int run(int n) { return n + 1; } }; }"
        let found = try await findings(source, libraries: functional).filter { $0.id == "anonymous-can-be-lambda" }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(try fixed(source, try XCTUnwrap(found.first)), "class T { Job j = n -> n + 1; }")
        let inherited = "class T { Derived d = new Derived() { public void go() { System.out.println(1); } }; }"
        let derived = try await findings(inherited, libraries: functional).filter { $0.id == "anonymous-can-be-lambda" }
        XCTAssertEqual(derived.count, 1)
        XCTAssertEqual(try fixed(inherited, try XCTUnwrap(derived.first)), "class T { Derived d = () -> System.out.println(1); }")
    }

    func testAnonymousClassStaysWhenALambdaCannotReplaceIt() async throws {
        let bodies = [
            "new Two() { public void a() { } }",
            "new Task() { void run() { } }",
            "new Mystery() { public void run() { } }",
            "new Job() { public int run(int n) { return this.hashCode(); } }",
            "new Job() { int calls; public int run(int n) { return n; } }",
            "new Job() { public int run(int n) { return n; } public void extra() { } }",
            "new Job() { public int run(int k) { return k; } }",
            "new Base() { public void go() { } void other() { } }",
        ]
        for body in bodies {
            let source = "class T { void f(int k) { Object o = \(body); } }"
            let found = try await findings(source, libraries: functional).filter { $0.id == "anonymous-can-be-lambda" }
            XCTAssertEqual(found.count, 0, body)
        }
    }
}
