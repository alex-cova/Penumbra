import XCTest
@testable import JavaIntelligence

final class JavaSemanticTokenProviderTests: XCTestCase {
    private struct Found {
        let text: String
        let token: JavaSemanticToken
    }

    private func classify(_ source: String, index: JavaIndex? = nil) async -> [Found] {
        let tokens = await JavaSemanticTokenProvider(index: index).tokens(for: source) ?? []
        let ns = source as NSString
        return tokens.map { Found(text: ns.substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)), token: $0) }
    }

    private func kinds(_ found: [Found], _ text: String) -> [JavaSemanticTokenKind] {
        found.filter { $0.text == text }.map(\.token.kind)
    }

    private let sample = """
    import static java.lang.Math.max;
    @interface Marker {}
    interface Shape { double area(); }
    enum Color { RED, GREEN }
    record Point(int x, int y) {}
    @Marker
    class Box<T> implements Shape {
        static final int LIMIT = 10;
        static int counter;
        private int size;
        Box(int size) { this.size = size; }
        static Box<String> make() { return new Box<>(1); }
        public double area() { return size; }
        <U> void run(U value, int size) {
            int local = size + LIMIT;
            for (int i = 0; i < local; i++) { counter++; }
            T item = null;
            Color c = Color.RED;
            Math.abs(local);
            helper(local);
            max(1, 2);
            this.size = size;
        }
        static void helper(int n) {}
    }
    """

    func testTypesAreClassifiedByKind() async {
        let found = await classify(sample)
        XCTAssertEqual(kinds(found, "Marker"), [.annotationType, .annotationType])
        XCTAssertTrue(kinds(found, "Shape").allSatisfy { $0 == .interfaceType })
        XCTAssertTrue(kinds(found, "Color").allSatisfy { $0 == .enumType })
        XCTAssertTrue(kinds(found, "Point").allSatisfy { $0 == .recordType })
        XCTAssertTrue(kinds(found, "Box").allSatisfy { $0 == .classType || $0 == .constructor })
    }

    func testMethodDeclarationsCallsAndConstructors() async {
        let found = await classify(sample)
        XCTAssertEqual(found.filter { $0.text == "area" }.map(\.token.kind), [.methodDeclaration, .methodDeclaration])
        let helper = found.filter { $0.text == "helper" }
        XCTAssertEqual(helper.map(\.token.kind), [.methodCall, .methodDeclaration])
        XCTAssertTrue(helper.first?.token.isStatic == true, "a call to a static method of this file is static")
        let abs = found.first { $0.text == "abs" }
        XCTAssertEqual(abs?.token.kind, .methodCall)
        XCTAssertEqual(abs?.token.isStatic, true, "Type.method() is a static call")
        XCTAssertEqual(found.first { $0.text == "max" }?.token.isStatic, true, "statically imported")
        let constructor = found.first { $0.text == "Box" && $0.token.kind == .constructor }
        XCTAssertNotNil(constructor)
        XCTAssertTrue(constructor?.token.isDeclaration == true)
    }

    func testFieldsStaticnessAndConstants() async {
        let found = await classify(sample)
        let limit = found.filter { $0.text == "LIMIT" }
        XCTAssertTrue(limit.allSatisfy { $0.token.kind == .field && $0.token.isStatic && $0.token.isFinal })
        XCTAssertEqual(limit.first?.token.highlightName, "constant.static")
        let counter = found.filter { $0.text == "counter" }
        XCTAssertTrue(counter.allSatisfy { $0.token.kind == .field && $0.token.isStatic && !$0.token.isFinal })
        let thisSize = found.last { $0.text == "size" }
        XCTAssertEqual(thisSize?.token.kind, .parameter, "the last `size` is the right-hand side, the parameter")
        XCTAssertTrue(found.contains { $0.text == "size" && $0.token.kind == .field && !$0.token.isStatic })
    }

    func testParametersLocalsAndTypeParameters() async {
        let found = await classify(sample)
        XCTAssertTrue(found.contains { $0.text == "value" && $0.token.kind == .parameter && $0.token.isDeclaration })
        XCTAssertTrue(found.contains { $0.text == "local" && $0.token.kind == .localVariable && $0.token.isDeclaration })
        XCTAssertTrue(found.contains { $0.text == "local" && $0.token.kind == .localVariable && !$0.token.isDeclaration })
        XCTAssertTrue(found.contains { $0.text == "i" && $0.token.kind == .localVariable })
        XCTAssertTrue(found.contains { $0.text == "U" && $0.token.kind == .typeParameter && $0.token.isDeclaration })
        XCTAssertTrue(found.filter { $0.text == "T" }.allSatisfy { $0.token.kind == .typeParameter })
    }

    func testEnumConstantsAndRecordComponents() async {
        let found = await classify(sample)
        XCTAssertTrue(found.filter { $0.text == "RED" }.allSatisfy { $0.token.kind == .enumConstant || $0.token.kind == .field })
        XCTAssertTrue(found.contains { $0.text == "RED" && $0.token.kind == .enumConstant })
        XCTAssertTrue(found.contains { $0.text == "GREEN" && $0.token.kind == .enumConstant })
        XCTAssertTrue(found.contains { $0.text == "x" && $0.token.kind == .field && $0.token.isDeclaration })
    }

    func testAParameterShadowsAFieldAndALocalShadowsBoth() async {
        let source = """
        class A {
            int v;
            void a() { use(v); }
            void b(int v) { use(v); }
            void c() { int v = 1; use(v); }
        }
        """
        let found = await classify(source)
        let uses = found.filter { $0.text == "v" && !$0.token.isDeclaration }
        XCTAssertEqual(uses.map(\.token.kind), [.field, .parameter, .localVariable])
    }

    func testTokensAreOrderedAndInBounds() async {
        let found = await classify(sample)
        let starts = found.map(\.token.range.lowerBound)
        XCTAssertEqual(starts, starts.sorted())
        let length = (sample as NSString).length
        XCTAssertTrue(found.allSatisfy { $0.token.range.upperBound <= length })
    }

    func testRangesAreUTF16EvenAfterNonASCIIText() async {
        let source = "// café ☕ 😀\nclass A { int n; void m() { n = 1; } }\n"
        let found = await classify(source)
        XCTAssertTrue(found.contains { $0.text == "n" && $0.token.kind == .field && !$0.token.isDeclaration })
        XCTAssertTrue(found.contains { $0.text == "m" && $0.token.kind == .methodDeclaration })
    }

    func testExternalTypesUseTheIndexToTellInterfacesFromClasses() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stubs = [
            JavaClassStub(binaryName: "java.util.List", qualifiedName: "java.util.List", simpleName: "List", packageName: "java.util", kind: .interfaceKind, modifiers: [.publicFlag], origin: .jdkModule("java.base")),
            JavaClassStub(binaryName: "java.lang.String", qualifiedName: "java.lang.String", simpleName: "String", packageName: "java.lang", kind: .classKind, modifiers: [.publicFlag], origin: .jdkModule("java.base"))
        ]
        let shard = dir.appendingPathComponent("s.idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: shard))])
        let found = await classify("import java.util.List;\nclass A { List<String> l; Unknown u; }\n", index: index)
        XCTAssertEqual(kinds(found, "List"), [.interfaceType])
        XCTAssertEqual(kinds(found, "String"), [.classType])
        XCTAssertEqual(kinds(found, "Unknown"), [.classType])
    }

    func testSyntaxErrorsDoNotCrashAndStillClassifyWhatIsThere() async {
        let found = await classify("class A { int n; void m( { n = ; } }\n class")
        XCTAssertTrue(found.contains { $0.text == "A" && $0.token.kind == .classType })
        _ = await classify("")
        _ = await classify("@@@ ((( }}}")
    }

    func testHighlightNamesPeelToBaseNames() {
        let all = JavaSemanticTokenKind.allCases.map { JavaSemanticToken(range: 0..<1, kind: $0).highlightName }
        let bases = ["type", "attribute", "function", "constructor", "property", "constant", "variable"]
        for name in all { XCTAssertTrue(bases.contains { name == $0 || name.hasPrefix($0 + ".") }, name) }
    }

    func testALargeFileIsClassifiedQuickly() async {
        var source = "package big;\nimport java.util.*;\npublic class Big {\n    private int total;\n"
        for i in 0..<1_000 {
            source += """
                /** doc \(i) */
                public int method\(i)(int a, String b) {
                    int x = a + total;
                    for (int j = 0; j < x; j++) { total += helper\(i)(j); }
                    List<String> l = new ArrayList<>();
                    return Math.max(x, b.length());
                }
                static int helper\(i)(int v) { return v * 2; }

            """
        }
        source += "}\n"
        let start = Date()
        let tokens = await JavaSemanticTokenProvider().tokens(for: source)
        let seconds = Date().timeIntervalSince(start)
        print("SEMANTIC lines=\(source.utf8.filter { $0 == 10 }.count) tokens=\(tokens?.count ?? -1) seconds=\(seconds)")
        XCTAssertGreaterThan(tokens?.count ?? 0, 10_000)
        XCTAssertLessThan(seconds, 3.0)
    }

    func testCancellationAbandonsThePass() async {
        var source = "class A {\n"
        for i in 0..<20_000 { source += "  int f\(i) = \(i);\n" }
        source += "}\n"
        let provider = JavaSemanticTokenProvider()
        let task = Task { await provider.tokens(for: source) }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
    }
}
