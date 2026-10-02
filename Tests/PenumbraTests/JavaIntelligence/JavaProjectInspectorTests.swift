import XCTest
@testable import JavaIntelligence

final class JavaProjectInspectorTests: XCTestCase {
    private func inspect(
        _ fixture: JavaReferenceFixture, file: String, publicApiIsUsed: Bool = false, rules: Set<JavaInspectionRule> = Set(JavaInspectionRegistry.projectRules)
    ) async throws -> [String] {
        let environment = try await fixture.build()
        let provider = JavaFindUsagesProvider(index: environment.index, indexPaths: JavaIndexPaths(root: fixture.root.appendingPathComponent("cache")))
        await provider.setProjectRoots([fixture.root])
        let source = try XCTUnwrap(fixture.sources[file])
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        let found = await JavaProjectInspector.inspect(
            source: source, url: fixture.url(file), tree: tree, provider: provider, enabled: rules,
            options: JavaProjectInspectionOptions(treatsPublicApiAsUsed: publicApiIsUsed)
        )
        return found.map { "\($0.id): \($0.message)" }.sorted()
    }

    func testUnusedDeclarations() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "public class A {\n    int used;\n    int idle;\n    void work() {}\n    void spare() {}\n    static class Helper {}\n    static class Spare {}\n}\n")
        try fixture.add("B.java", "class B { void go(A a) { a.used = 1; a.work(); A.Helper h = null; } }")
        let found = try await inspect(fixture, file: "A.java", rules: [.unusedDeclaration])
        XCTAssertEqual(found, [
            "unused-declaration: Class 'Spare' is never used",
            "unused-declaration: Field 'idle' is never used",
            "unused-declaration: Method 'spare' is never used",
        ])
    }

    func testPublicApiIsLeftAloneByDefault() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "public class A {\n    public void spare() {}\n    void quiet() {}\n}\n")
        let withApi = try await inspect(fixture, file: "A.java", publicApiIsUsed: true, rules: [.unusedDeclaration])
        XCTAssertEqual(withApi, ["unused-declaration: Method 'quiet' is never used"])
        let without = try await inspect(fixture, file: "A.java", publicApiIsUsed: false, rules: [.unusedDeclaration])
        XCTAssertEqual(without.count, 3)
    }

    func testEntryPointsAreSkipped() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class A {\n    public static void main(String[] args) {}\n    @Test void check() {}\n    @Override public String toString() { return \"\"; }\n    static final long serialVersionUID = 1L;\n}\n")
        let found = try await inspect(fixture, file: "A.java", rules: [.unusedDeclaration])
        XCTAssertEqual(found, [])
    }

    func testRecursionDoesNotCountAsUse() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class A {\n    int loop(int n) { return n == 0 ? 0 : loop(n - 1); }\n}\n")
        let found = try await inspect(fixture, file: "A.java", rules: [.unusedDeclaration])
        XCTAssertEqual(found, ["unused-declaration: Class 'A' is never used", "unused-declaration: Method 'loop' is never used"])
    }

    func testAccessCanBeWeaker() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class A {\n    int local;\n    int shared;\n    void run() { local++; }\n}\n")
        try fixture.add("B.java", "class B { int f(A a) { return a.shared; } }")
        let found = try await inspect(fixture, file: "A.java", rules: [.declarationAccessCanBeWeaker])
        XCTAssertEqual(found, ["declaration-access-can-be-weaker: Field 'local' can be private"])
    }

    func testMethodCanBeVoid() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class A {\n    int ignored() { return 1; }\n    int read() { return 2; }\n    int chained() { return 3; }\n}\n")
        try fixture.add("B.java", "class B { int go(A a) { a.ignored(); a.ignored(); int x = a.read(); a.read(); return a.chained() + 1; } }")
        let found = try await inspect(fixture, file: "A.java", rules: [.methodCanBeVoid])
        XCTAssertEqual(found, ["method-can-be-void: Return value of 'ignored' is never used"])
    }

    func testParameterAlwaysSameValue() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class A {\n    void set(String mode, int level) {}\n}\n")
        try fixture.add("B.java", "class B { void go(A a, int n) { a.set(\"fast\", 1); a.set(\"fast\", n); } }")
        let found = try await inspect(fixture, file: "A.java", rules: [.parameterAlwaysSameValue])
        XCTAssertEqual(found, ["parameter-always-same-value: Parameter 'mode' always receives \"fast\""])
    }

    func testMethodReferencesAndOverridesStopTheValueRules() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class A {\n    int tick() { return 1; }\n    int base() { return 1; }\n}\n")
        try fixture.add("B.java", "class B extends A { int base() { return 2; } void go(A a) { Runnable r = a::tick; a.base(); a.base(); } }")
        let found = try await inspect(fixture, file: "A.java", rules: [.methodCanBeVoid, .parameterAlwaysSameValue])
        XCTAssertEqual(found, [])
    }
}
