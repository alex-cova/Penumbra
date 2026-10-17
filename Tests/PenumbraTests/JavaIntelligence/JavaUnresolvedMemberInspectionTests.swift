import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// `JavaUnresolvedMemberInspection`: qualified and implicit-`this` member accesses whose
/// receiver class is fully indexed but declares no member of that name.
final class JavaUnresolvedMemberInspectionTests: XCTestCase {
    private var scratch: URL!
    private let url = URL(fileURLWithPath: "/proj/T.java")

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("java-unresolved-member-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// An index holding the classes declared in `libraries`, then the `unresolved-member`
    /// findings for `source`. Each library source is one package and is written to the
    /// scratch directory, because the closed-hierarchy check reads each declaring file's
    /// imports from disk. As in Umbra with an unsaved buffer, the file under test is not
    /// in the index.
    private func findings(_ source: String, libraries: [String]) async throws -> [JavaInspection] {
        let index = try await makeIndex(libraries: libraries)
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        let context = try XCTUnwrap(JavaInspectionContext(source: source, tree: tree, url: url, index: index))
        let all = await JavaInspectionRunner.runTyped(context: context, enabled: [.unresolvedMember])
        return all.filter { $0.id == JavaInspectionRule.unresolvedMember.code }
    }

    private func makeIndex(libraries: [String]) async throws -> JavaIndex {
        var stubs: [JavaClassStub] = []
        for (number, library) in libraries.enumerated() {
            let file = scratch.appendingPathComponent("Lib\(number).java")
            try library.write(to: file, atomically: true, encoding: .utf8)
            stubs.append(contentsOf: JavaSourceStubBuilder.build(source: library, url: file).classes)
        }
        let shard = scratch.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: shard))])
        return index
    }

    private func range(of name: String, in source: String, finding: JavaInspection) -> Bool {
        let expected = (source as NSString).range(of: name)
        return finding.range.start.utf16Offset == expected.location
            && finding.range.end.utf16Offset == expected.location + expected.length
    }

    private let objectLib = """
    package java.lang;
    public class Object {
        public String toString() { return null; }
        public boolean equals(Object o) { return false; }
        public int hashCode() { return 0; }
        public final Class getClass() { return null; }
    }
    """

    private let stringLib = """
    package java.lang;
    public class String {
        public int length() { return 0; }
        public char charAt(int i) { return 'a'; }
    }
    """

    private let runsLib = """
    class Runs {
        void forEach(Runnable r) { }
    }
    """

    // MARK: - Reports

    func testTypoOnDeclaredReceiver() async throws {
        let source = "class T { void f(Runs runs) { runs.forach(null); } }"
        let found = try await findings(source, libraries: [objectLib, runsLib])
        XCTAssertEqual(found.map(\.message), ["Cannot resolve method 'forach' in 'Runs'"])
        XCTAssertTrue(range(of: "forach", in: source, finding: try XCTUnwrap(found.first)))
    }

    func testPrefixOfMethodStillReportsOnInvocation() async throws {
        let lib = "class MyList { void add(Object o) { } }"
        let source = "class T { void f(MyList list, Object x) { list.ad(x); } }"
        let found = try await findings(source, libraries: [objectLib, lib])
        XCTAssertEqual(found.map(\.message), ["Cannot resolve method 'ad' in 'MyList'"])
    }

    func testUnknownStaticOnTypeReceiver() async throws {
        let lib = "class Util { static int twice(int x) { return x * 2; } }"
        let source = "class T { int f() { return Util.twic(1); } }"
        let found = try await findings(source, libraries: [objectLib, lib])
        XCTAssertEqual(found.map(\.message), ["Cannot resolve method 'twic' in 'Util'"])
    }

    func testUnknownMethodOnLiteralReceiver() async throws {
        let source = "class T { int f() { return \"abc\".lengt(); } }"
        let found = try await findings(source, libraries: [objectLib, stringLib])
        XCTAssertEqual(found.map(\.message), ["Cannot resolve method 'lengt' in 'String'"])
    }

    func testImplicitCallNextToHelper() async throws {
        let source = "class T { void helper() { } void f() { helpr(); } }"
        let found = try await findings(source, libraries: [objectLib])
        XCTAssertEqual(found.map(\.message), ["Cannot resolve method 'helpr' in 'T'"])
    }

    func testUnknownFieldOnDeclaredLocal() async throws {
        let lib = "class Point { int x; int y; }"
        let source = "class T { int f(Point p) { return p.zzz; } }"
        let found = try await findings(source, libraries: [objectLib, lib])
        XCTAssertEqual(found.map(\.message), ["Cannot resolve symbol 'zzz'"])
        XCTAssertTrue(range(of: "zzz", in: source, finding: try XCTUnwrap(found.first)))
    }

    func testFieldWhereOnlyMethodExists() async throws {
        let lib = "class MyList { int size() { return 0; } }"
        let source = "class T { int f(MyList list) { return list.size; } }"
        let found = try await findings(source, libraries: [objectLib, lib])
        XCTAssertEqual(found.map(\.message), ["Cannot resolve symbol 'size'"])
    }

    func testUnknownUnboundMethodReference() async throws {
        let source = "class T { void f() { ToString t = String::size; } interface ToString { int get(String s); } }"
        let found = try await findings(source, libraries: [objectLib, stringLib])
        XCTAssertEqual(found.map(\.message), ["Cannot resolve method 'size' in 'String'"])
    }

    func testPartialMethodReferenceStaysSilent() async throws {
        // `lengt` is a strict prefix of `length`: still being typed, not a typo.
        let source = "class T { void f() { ToString t = String::lengt; } interface ToString { int get(String s); } }"
        let found = try await findings(source, libraries: [objectLib, stringLib])
        XCTAssertEqual(found.count, 0)
    }

    // MARK: - Silent

    func testArityMismatchIsJavacsJob() async throws {
        let lib = "class M { void add(int a, int b) { } }"
        let source = "class T { void f(M m) { m.add(1, 2, 3); } }"
        let found = try await findings(source, libraries: [objectLib, lib])
        XCTAssertEqual(found.count, 0)
    }

    func testUnindexedReceiverIsUnknown() async throws {
        let source = "class T { void f(Mystery m) { m.foo(); } }"
        let found = try await findings(source, libraries: [objectLib])
        XCTAssertEqual(found.count, 0)
    }

    func testOpenHierarchyIsUnknown() async throws {
        let lib = "class Sub extends Missing { }"
        let source = "class T { void f(Sub s) { s.foo(); } }"
        let found = try await findings(source, libraries: [objectLib, lib])
        XCTAssertEqual(found.count, 0)
    }

    func testLombokLibraryStaysSilent() async throws {
        let lib = "import lombok.Data;\nclass Bean { String name; }"
        let source = "class T { String f(Bean b) { return b.getName(); } }"
        let found = try await findings(source, libraries: [objectLib, lib])
        XCTAssertEqual(found.count, 0)
    }

    func testInterfaceSeesObjectMethods() async throws {
        let lib = "interface Iface { void go(); }"
        for call in ["iface.getClass()", "iface.hashCode()", "iface.toString()"] {
            let source = "class T { void f(Iface iface) { \(call); } }"
            let found = try await findings(source, libraries: [objectLib, lib])
            XCTAssertEqual(found.count, 0, call)
        }
    }

    func testStaticInterfaceMethod() async throws {
        let lib = "interface Lib { static Lib of(int x) { return null; } }"
        let source = "class T { void f() { Lib.of(1); } }"
        let found = try await findings(source, libraries: [objectLib, lib])
        XCTAssertEqual(found.count, 0)
    }

    func testUnboundMethodReferenceToRealMethod() async throws {
        let source = "class T { void f() { ToString t = String::length; } interface ToString { int get(String s); } }"
        let found = try await findings(source, libraries: [objectLib, stringLib])
        XCTAssertEqual(found.count, 0)
    }

    func testNestedTypeAsFieldAccess() async throws {
        let lib = "class Map { static class Entry { static Object comparingByKey() { return null; } } }"
        let source = "class T { void f() { Map.Entry.comparingByKey(); } }"
        let found = try await findings(source, libraries: [objectLib, lib])
        XCTAssertEqual(found.count, 0)
    }

    func testTypeParameterReceiver() async throws {
        let source = "class Box<T> { void f(T item) { item.foo(); } }"
        let found = try await findings(source, libraries: [objectLib])
        XCTAssertEqual(found.count, 0)
    }

    func testChainOutOfV1IsSkipped() async throws {
        let lib = "class A { B b() { return null; } } class B { void ok() { } }"
        let source = "class T { void f(A a) { a.b().zzz(); } }"
        let found = try await findings(source, libraries: [objectLib, lib])
        XCTAssertEqual(found.count, 0)
    }

    func testAnonymousBodySeesSupertypeMethod() async throws {
        let lib = "class Base { void go() { } }"
        let source = "class T { Object o = new Base() { void m() { go(); } }; }"
        let found = try await findings(source, libraries: [objectLib, lib])
        XCTAssertEqual(found.count, 0)
    }

    func testRecordBodySeesComponentAccessor() async throws {
        let source = "record R(int x) { int y() { return x(); } }"
        let found = try await findings(source, libraries: [objectLib])
        XCTAssertEqual(found.count, 0)
    }

    func testEnumSeesValuesAndOrdinal() async throws {
        let enumLib = "package java.lang; public class Enum<E> { public int ordinal() { return 0; } }"
        let source = "enum E { A, B; static void m() { Object[] all = values(); int n = A.ordinal(); } }"
        let found = try await findings(source, libraries: [objectLib, enumLib])
        XCTAssertEqual(found.count, 0)
    }

    func testFieldPrefixGuardWhileTyping() async throws {
        let lib = "class P { int size() { return 0; } }"
        let source = "class T { void foo(int x) { } void f(P p) { foo(p.si); } }"
        let found = try await findings(source, libraries: [objectLib, lib])
        XCTAssertEqual(found.count, 0)
    }

    func testSyntaxErrorSkipsTheWholePass() throws {
        let source = "class T { void f(Runs runs) { runs.forE } }"
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        XCTAssertTrue(tree.rootNode.hasError)
        XCTAssertNil(JavaInspectionContext(source: source, tree: tree, url: url, index: JavaIndex()))
    }

    func testThisCallSeesEnclosingMethod() async throws {
        let source = "class T { void helper() { } void f() { this.helper(); } }"
        let found = try await findings(source, libraries: [objectLib])
        XCTAssertEqual(found.count, 0)
    }

    func testInheritedMethodThroughSuperclass() async throws {
        let lib = "class Base { void go() { } } class Sub extends Base { }"
        let source = "class T { void f(Sub s) { s.go(); } }"
        let found = try await findings(source, libraries: [objectLib, lib])
        XCTAssertEqual(found.count, 0)
    }

    func testInheritedImplicitCallThroughSuperclass() async throws {
        let lib = "class Base { void go() { } }"
        let source = "class Sub extends Base { void f() { go(); } }"
        let found = try await findings(source, libraries: [objectLib, lib])
        XCTAssertEqual(found.count, 0)
    }

    func testLombokInCurrentFileSkipsImplicitPath() async throws {
        let source = "import lombok.Data;\nclass T { void f() { helpr(); } }"
        let found = try await findings(source, libraries: [objectLib])
        XCTAssertEqual(found.count, 0)
    }

    // MARK: - Bookkeeping

    func testRegistration() {
        XCTAssertTrue(JavaInspectionRegistry.typedInspections.contains { $0.rule == .unresolvedMember })
        let rule = JavaInspectionRule.unresolvedMember
        XCTAssertEqual(rule.code, "unresolved-member")
        XCTAssertTrue(rule.isEnabledByDefault)
        XCTAssertEqual(rule.defaultSeverity, .error)
        XCTAssertEqual(rule.group, .compilerIssues)
    }

    func testSuppressWarningsSilencesRule() async throws {
        let index = try await makeIndex(libraries: [objectLib, runsLib])
        let bad = "class T { void f(Runs runs) { runs.forach(null); } }"
        let quiet = "class T { @SuppressWarnings(\"unresolved-member\") void f(Runs runs) { runs.forach(null); } }"
        for (source, expected) in [(bad, 1), (quiet, 0)] {
            let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
            let inspected = await JavaInspectionPipeline.inspect(
                text: source, url: url, tree: tree, index: index,
                enabled: [.unresolvedMember], thresholds: .standard
            ).filter { $0.id == JavaInspectionRule.unresolvedMember.code }
            let found = JavaInspectionPipeline.suppressionFiltered(inspected, text: source)
            XCTAssertEqual(found.count, expected, source)
        }
    }

    func testRepeatedBadCallsReportEachTime() async throws {
        let calls = Array(repeating: "u.bad();", count: 500).joined(separator: " ")
        let source = "class T { void f(Util u) { \(calls) } }"
        let lib = "class Util { void ok() { } }"
        let found = try await findings(source, libraries: [objectLib, lib])
        XCTAssertEqual(found.count, 500)
    }

    func testResolutionBudgetBoundsDistinctReceivers() async throws {
        var lib = ""
        var body = ""
        for number in 0..<400 {
            lib += "class C\(number) { void ok() { } }\n"
            body += "C\(number) c\(number) = null; c\(number).bad(); "
        }
        let source = "class T { void f() { \(body) } }"
        let found = try await findings(source, libraries: [objectLib, lib])
        XCTAssertEqual(found.count, 300)
    }
}
