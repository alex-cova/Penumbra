import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// The index-backed rules (deprecated constructors and fields, collection arguments, hidden fields)
/// and the syntactic rules of the last batch.
final class JavaFifthBatchInspectionsTests: XCTestCase {
    private var scratch: URL!
    private let url = URL(fileURLWithPath: "/proj/com/example/T.java")

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("java-fifth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Harness

    /// The typed findings for `source` against an index holding the classes of `libraries`.
    /// `deprecatedMembers` marks constructors (`<init>` stands for any) and fields by name.
    private func typed(
        _ rule: JavaInspectionRule, _ source: String, libraries: String, deprecated: Set<String> = [], file: StaticString = #filePath, line: UInt = #line
    ) async throws -> [JavaInspection] {
        let shard = scratch.appendingPathComponent("\(UUID().uuidString).idx")
        let built = JavaSourceStubBuilder.build(source: libraries, url: scratch.appendingPathComponent("Lib.java")).classes
        let stubs = built.map { stub in
            JavaClassStub(
                binaryName: stub.binaryName, qualifiedName: stub.qualifiedName, simpleName: stub.simpleName, packageName: stub.packageName,
                outerQualifiedName: stub.outerQualifiedName, kind: stub.kind, modifiers: stub.modifiers, typeParameters: stub.typeParameters,
                superclass: stub.superclass, interfaces: stub.interfaces,
                fields: stub.fields.map { field in
                    deprecated.contains(field.name)
                        ? JavaFieldStub(name: field.name, type: field.type, modifiers: field.modifiers.union(.deprecatedFlag), javadoc: field.javadoc)
                        : field
                },
                methods: stub.methods.map { method in
                    guard deprecated.contains(method.isConstructor ? "<init>" : method.name) else { return method }
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
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source), file: file, line: line)
        let context = try XCTUnwrap(JavaInspectionContext(source: source, tree: tree, url: url, index: index), file: file, line: line)
        return await JavaInspectionRunner.runTyped(context: context, enabled: [rule])
    }

    private func findings(_ rule: JavaInspectionRule, _ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> [JavaInspection] {
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source), file: file, line: line)
        let context = try XCTUnwrap(JavaInspectionContext(source: source, tree: tree, url: url, index: JavaIndex()), "source must parse", file: file, line: line)
        return JavaInspectionRunner.run(context: context, enabled: [rule])
    }

    private func count(_ rule: JavaInspectionRule, _ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        try findings(rule, source, file: file, line: line).count
    }

    private func method(_ body: String, params: String = "", members: String = "") -> String {
        "class T {\n\(members)\n    void f(\(params)) {\n\(body)\n    }\n}\n"
    }

    // MARK: Index-backed

    func testDeprecatedConstructorUsage() async throws {
        let library = "package lib;\npublic class Old {\n    public Old() { }\n    public Old(int a) { }\n}\npublic class Mixed {\n    public Mixed() { }\n}\n"
        let both = try await typed(
            .deprecatedConstructorUsage, "import lib.Old;\nclass T { void f() { Object o = new Old(1); } }\n",
            libraries: library, deprecated: ["<init>"]
        )
        XCTAssertEqual(both.map(\.id), ["deprecated-constructor-usage"])
        let none = try await typed(
            .deprecatedConstructorUsage, "import lib.Old;\nclass T { void f() { Object o = new Old(1); } }\n", libraries: library
        )
        XCTAssertTrue(none.isEmpty)
        // A deprecated declaration may use what it wraps.
        let inside = try await typed(
            .deprecatedConstructorUsage, "import lib.Old;\nclass T {\n    @Deprecated\n    void f() { Object o = new Old(1); }\n}\n",
            libraries: library, deprecated: ["<init>"]
        )
        XCTAssertTrue(inside.isEmpty)
    }

    func testDeprecatedFieldUsage() async throws {
        let library = "package lib;\npublic class Consts {\n    public static final int OLD = 1;\n    public static final int NEW = 2;\n}\n"
        let found = try await typed(
            .deprecatedFieldUsage, "import lib.Consts;\nclass T { int f() { return Consts.OLD + Consts.NEW; } }\n",
            libraries: library, deprecated: ["OLD"]
        )
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found.first?.message.contains("OLD") == true)
    }

    func testSuspiciousCollectionArgument() async throws {
        let library = """
        package java.util;
        public interface Collection<E> { boolean contains(Object o); boolean remove(Object o); }
        public interface List<E> extends Collection<E> { int indexOf(Object o); E remove(int index); }
        public interface Map<K, V> { V get(Object key); boolean containsKey(Object key); boolean containsValue(Object value); }
        """
        func run(_ body: String, params: String) async throws -> [JavaInspection] {
            try await typed(
                .suspiciousCollectionArgument,
                "import java.util.List;\nimport java.util.Map;\nclass T { void f(\(params)) {\n\(body)\n} }\n", libraries: library
            )
        }
        let found = try await run("        boolean b = names.contains(1);", params: "List<String> names")
        XCTAssertEqual(found.count, 1)
        let mapKey = try await run("        Object v = byName.get(1);", params: "Map<String, String> byName")
        XCTAssertEqual(mapKey.count, 1)
        let mapValue = try await run("        boolean b = byName.containsValue(1);", params: "Map<String, String> byName")
        XCTAssertEqual(mapValue.count, 1)
        let boxed = try await run("        boolean b = numbers.contains(1);", params: "List<Long> numbers")
        XCTAssertEqual(boxed.count, 1)
        let matching = try await run("        boolean b = names.contains(\"a\");", params: "List<String> names")
        XCTAssertTrue(matching.isEmpty)
        // List.remove(int) is an index, not a lookup.
        let byIndex = try await run("        names.remove(0);", params: "List<String> names")
        XCTAssertTrue(byIndex.isEmpty)
        let unknown = try await run("        boolean b = names.contains(other);", params: "List<String> names")
        XCTAssertTrue(unknown.isEmpty)
    }

    func testFieldHidesSuperclassField() async throws {
        let library = "package lib;\npublic class Base {\n    protected int count;\n    private int secret;\n}\n"
        let hides = try await typed(
            .fieldHidesSuperclassField, "import lib.Base;\nclass T extends Base {\n    int count;\n}\n", libraries: library
        )
        XCTAssertEqual(hides.map(\.id), ["field-hides-superclass-field"])
        let privateOne = try await typed(
            .fieldHidesSuperclassField, "import lib.Base;\nclass T extends Base {\n    int secret;\n}\n", libraries: library
        )
        XCTAssertTrue(privateOne.isEmpty)
        let unrelated = try await typed(
            .fieldHidesSuperclassField, "import lib.Base;\nclass T extends Base {\n    int other;\n}\n", libraries: library
        )
        XCTAssertTrue(unrelated.isEmpty)
        let noSuper = try await typed(.fieldHidesSuperclassField, "class T {\n    int count;\n}\n", libraries: library)
        XCTAssertTrue(noSuper.isEmpty)
    }

    // MARK: Syntactic

    func testPackageDirectoryMismatch() throws {
        XCTAssertEqual(try count(.packageDirectoryMismatch, "package com.example;\nclass T { }\n"), 0)
        XCTAssertEqual(try count(.packageDirectoryMismatch, "package com.other;\nclass T { }\n"), 1)
        XCTAssertEqual(try count(.packageDirectoryMismatch, "class T { }\n"), 0)
    }

    func testNotifyInsteadOfNotifyAll() throws {
        XCTAssertEqual(try count(.notifyInsteadOfNotifyAll, method("        notify();")), 1)
        XCTAssertEqual(try count(.notifyInsteadOfNotifyAll, method("        lock.notify();")), 1)
        XCTAssertEqual(try count(.notifyInsteadOfNotifyAll, method("        notifyAll();")), 0)
    }

    func testUnsafeThreadMethod() throws {
        XCTAssertEqual(try count(.unsafeThreadMethod, method("        t.stop();", params: "Thread t")), 1)
        XCTAssertEqual(try count(.unsafeThreadMethod, method("        t.suspend();", params: "Thread t")), 1)
        XCTAssertEqual(try count(.unsafeThreadMethod, method("        Thread.currentThread().stop();")), 1)
        XCTAssertEqual(try count(.unsafeThreadMethod, method("        timer.stop();", params: "Timer timer")), 0)
        XCTAssertEqual(try count(.unsafeThreadMethod, method("        t.interrupt();", params: "Thread t")), 0)
    }

    func testVolatileArrayField() throws {
        XCTAssertEqual(try count(.volatileArrayField, "class T {\n    private volatile int[] data;\n}\n"), 1)
        XCTAssertEqual(try count(.volatileArrayField, "class T {\n    private volatile int data;\n}\n"), 0)
        XCTAssertEqual(try count(.volatileArrayField, "class T {\n    private int[] data;\n}\n"), 0)
    }

    func testCloneWithoutSuperCall() throws {
        XCTAssertEqual(try count(.cloneWithoutSuperCall, "class T {\n    public Object clone() { return new T(); }\n}\n"), 1)
        XCTAssertEqual(try count(.cloneWithoutSuperCall, "class T {\n    public Object clone() throws CloneNotSupportedException { return super.clone(); }\n}\n"), 0)
        XCTAssertEqual(try count(.cloneWithoutSuperCall, "class T {\n    public Object clone() throws CloneNotSupportedException { throw new CloneNotSupportedException(); }\n}\n"), 0)
        XCTAssertEqual(try count(.cloneWithoutSuperCall, "class T {\n    public T clone(int depth) { return new T(); }\n}\n"), 0)
        // A final class cannot be subclassed.
        XCTAssertEqual(try count(.cloneWithoutSuperCall, "final class T {\n    public Object clone() { return new T(); }\n}\n"), 0)
    }

    func testEqualsWithoutTypeCheck() throws {
        XCTAssertEqual(try count(.equalsWithoutTypeCheck, "class T {\n    int x;\n    public boolean equals(Object o) {\n        T other = (T) o;\n        return x == other.x;\n    }\n}\n"), 1)
        XCTAssertEqual(try count(.equalsWithoutTypeCheck, "class T {\n    int x;\n    public boolean equals(Object o) {\n        if (!(o instanceof T)) return false;\n        T other = (T) o;\n        return x == other.x;\n    }\n}\n"), 0)
        XCTAssertEqual(try count(.equalsWithoutTypeCheck, "class T {\n    int x;\n    public boolean equals(Object o) {\n        if (o == null || getClass() != o.getClass()) return false;\n        T other = (T) o;\n        return x == other.x;\n    }\n}\n"), 0)
        XCTAssertEqual(try count(.equalsWithoutTypeCheck, "class T {\n    public boolean equals(Object o) { return this == o; }\n}\n"), 0)
        XCTAssertEqual(try count(.equalsWithoutTypeCheck, "class T {\n    int x;\n    public boolean equals(Object o) {\n        if (!sameClassAs(o)) return false;\n        T other = (T) o;\n        return x == other.x;\n    }\n}\n"), 0)
    }

    func testToStringReturnsNull() throws {
        XCTAssertEqual(try count(.toStringReturnsNull, "class T {\n    public String toString() { return null; }\n}\n"), 1)
        XCTAssertEqual(try count(.toStringReturnsNull, "class T {\n    public String toString() { return \"T\"; }\n}\n"), 0)
        XCTAssertEqual(try count(.toStringReturnsNull, "class T {\n    String name() { return null; }\n}\n"), 0)
    }

    func testSystemExitCall() throws {
        XCTAssertEqual(try count(.systemExitCall, method("        System.exit(1);")), 1)
        XCTAssertEqual(try count(.systemExitCall, method("        Runtime.getRuntime().halt(1);")), 1)
        XCTAssertEqual(try count(.systemExitCall, method("        other.exit(1);")), 0)
    }

    func testOctalLiteral() throws {
        XCTAssertEqual(try count(.octalLiteral, method("        int mode = 0644;")), 1)
        XCTAssertEqual(try count(.octalLiteral, method("        int zero = 0;")), 0)
        XCTAssertEqual(try count(.octalLiteral, method("        int ten = 10;\n        int hex = 0x1F;")), 0)
    }

    func testParameterHidesField() throws {
        let members = "    private int count;"
        XCTAssertEqual(try count(.parameterHidesField, "class T {\n    private int count;\n    void add(int count) { }\n}\n"), 1)
        XCTAssertEqual(try count(.parameterHidesField, "class T {\n    private int count;\n    void setCount(int count) { }\n}\n"), 0)
        XCTAssertEqual(try count(.parameterHidesField, "class T {\n    private int count;\n    T(int count) { this.count = count; }\n}\n"), 0)
        XCTAssertEqual(try count(.parameterHidesField, method("", params: "int other", members: members)), 0)
    }

    func testStaticFieldWrittenFromInstance() throws {
        let source = "class T {\n    private static int total;\n    void add(int n) {\n        total += n;\n    }\n}\n"
        XCTAssertEqual(try count(.staticFieldWrittenFromInstance, source), 1)
        XCTAssertEqual(try count(.staticFieldWrittenFromInstance, "class T {\n    private static int total;\n    static void add(int n) {\n        total += n;\n    }\n}\n"), 0)
        XCTAssertEqual(try count(.staticFieldWrittenFromInstance, "class T {\n    private static final int total = 1;\n    void add() { total++; }\n}\n"), 0)
        XCTAssertEqual(try count(.staticFieldWrittenFromInstance, "class T {\n    private int total;\n    void add() { total++; }\n}\n"), 0)
        XCTAssertEqual(try count(.staticFieldWrittenFromInstance, "class T {\n    private static int total;\n    void add() { int total = 0; total++; }\n}\n"), 0)
    }

    func testRegistrationAndDefaults() {
        let added: [JavaInspectionRule] = [
            .deprecatedConstructorUsage, .deprecatedFieldUsage, .suspiciousCollectionArgument, .fieldHidesSuperclassField,
            .packageDirectoryMismatch, .notifyInsteadOfNotifyAll, .unsafeThreadMethod, .volatileArrayField, .cloneWithoutSuperCall,
            .equalsWithoutTypeCheck, .toStringReturnsNull, .systemExitCall, .octalLiteral, .parameterHidesField,
            .staticFieldWrittenFromInstance,
        ]
        let typed: Set<JavaInspectionRule> = [.deprecatedConstructorUsage, .deprecatedFieldUsage, .suspiciousCollectionArgument, .fieldHidesSuperclassField]
        let off: Set<JavaInspectionRule> = [.notifyInsteadOfNotifyAll, .systemExitCall, .octalLiteral, .parameterHidesField, .staticFieldWrittenFromInstance]
        for rule in added {
            let registered = typed.contains(rule)
                ? JavaInspectionRegistry.typedInspection(for: rule) != nil
                : JavaInspectionRegistry.inspection(for: rule) != nil
            XCTAssertTrue(registered, "\(rule.code) is not registered")
            XCTAssertEqual(rule.isEnabledByDefault, !off.contains(rule), "\(rule.code) default state")
            XCTAssertFalse(rule.hasQuickFix, "\(rule.code) has no fix")
        }
    }
}
