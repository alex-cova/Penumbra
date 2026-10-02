import XCTest
@testable import JavaIntelligence

final class JavaDataFlowInspectionTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/proj/T.java")

    private func run(_ source: String, _ rules: Set<JavaInspectionRule> = JavaInspectionRunner.flowRules.subtracting([.unusedAssignment]), file: StaticString = #filePath, line: UInt = #line) throws -> [JavaInspection] {
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source), file: file, line: line)
        let context = try XCTUnwrap(JavaInspectionContext(source: source, tree: tree, url: url, index: JavaIndex()), "source must parse", file: file, line: line)
        return JavaInspectionRunner.runFlow(context: context, enabled: rules)
    }

    private func codes(_ body: String, params: String = "String p, int n", members: String = "", file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let source = "import java.io.*;\nimport java.util.*;\nclass T {\n\(members)\n    int f(\(params)) throws Exception {\n\(body)\n        return 0;\n    }\n}\n"
        return try run(source, file: file, line: line).map(\.id)
    }

    // MARK: Null dereference

    func testDereferenceOfNull() throws {
        XCTAssertEqual(try codes("        String s = null;\n        s.length();"), ["null-dereference"])
        let findings = try run("class T {\n    void f() {\n        String s = null;\n        s.length();\n    }\n}\n")
        XCTAssertEqual(findings.first?.severity, .error)
        XCTAssertEqual(try codes("        String s = null;\n        if (n > 0) { s = \"a\"; }\n        s.length();"), ["nullable-dereference"])
        XCTAssertEqual(try codes("        String s = null;\n        if (p != null) { s = p; }\n        s.length();"), ["nullable-dereference"])
        XCTAssertEqual(try codes("        String s = null;\n        if (s == null) { s.length(); }").sorted(), ["null-dereference", "redundant-null-check"])
    }

    func testNoDereferenceFindingWhenSafe() throws {
        XCTAssertEqual(try codes("        String s = null;\n        s = \"a\";\n        s.length();"), [])
        XCTAssertEqual(try codes("        String s = p;\n        s.length();"), [])
        XCTAssertEqual(try codes("        String s = null;\n        if (n > 0) { s = \"a\"; } else { s = \"b\"; }\n        s.length();"), [])
        XCTAssertEqual(try codes("        String s = null;\n        for (int i = 0; i < n; i++) { s = \"a\"; }\n        s.length();"), [])
        XCTAssertEqual(try codes("        String s = null;\n        try { s = \"a\"; } catch (RuntimeException e) { }\n        s.length();"), [])
        XCTAssertEqual(try codes("        String s = null;\n        if (p == null) { return 1; }\n        s = p;\n        s.length();"), [])
        XCTAssertEqual(try codes("        String s = p;\n        if (s != null && s.length() > 0) { return 2; }"), [])
        XCTAssertEqual(try codes("        String line;\n        BufferedReader r = open();\n        while ((line = r.readLine()) != null) { line.length(); }", members: "    BufferedReader open() { return null; }"), [])
        XCTAssertEqual(try codes("        Runnable r = () -> { String s = null; };\n        r.run();"), [])
    }

    // MARK: Conditions

    func testRedundantNullCheck() throws {
        XCTAssertEqual(try codes("        String s = \"a\";\n        if (s != null) { n++; }"), ["redundant-null-check"])
        XCTAssertEqual(try codes("        String s = new String();\n        if (s == null) { n++; }"), ["redundant-null-check"])
        XCTAssertEqual(try codes("        if (p == null) { return 1; }\n        if (p != null) { n++; }"), ["redundant-null-check"])
        XCTAssertEqual(try codes("        String s = p;\n        if (s != null) { n++; }"), [])
        XCTAssertEqual(try codes("        String s = \"a\";\n        if (n > 0) { s = null; }\n        if (s != null) { n++; }"), [])
        XCTAssertEqual(try codes("        require(p != null);\n        p.length();", members: "    void require(boolean b) {}"), [])
        XCTAssertEqual(try codes("        int len = p != null ? p.length() : 0;\n        p.length();"), [])
        XCTAssertEqual(try codes("        for (int i = 0; i < 250; i++) { n++; }"), [])
        XCTAssertEqual(try codes("        for (int i = 0, j = 5; i < j; i++, j--) { n++; }"), [])
    }

    func testConstantCondition() throws {
        XCTAssertEqual(try codes("        boolean b = true;\n        if (b) { n++; }"), ["condition-always-constant"])
        XCTAssertEqual(try codes("        int x = 3;\n        if (x > 5) { n++; }"), ["condition-always-constant"])
        XCTAssertEqual(try codes("        int x = 3;\n        int y = x + 2;\n        boolean z = y == 5;"), ["condition-always-constant"])
        XCTAssertEqual(try codes("        boolean b = true;\n        while (n > 0) { b = false; n--; }\n        if (b) { n++; }"), [])
        XCTAssertEqual(try codes("        if (true) { n++; }"), [])
        XCTAssertEqual(try codes("        while (true) { if (n > 3) break; n++; }"), [])
        XCTAssertEqual(try codes("        int x = 0;\n        for (int i = 0; i < n; i++) { x++; }\n        if (x == 0) { n++; }"), [])
    }

    // MARK: Unreachable

    func testUnreachableCode() throws {
        XCTAssertEqual(try codes("        return 1;\n        n++;").filter { $0 == "unreachable-code" }, ["unreachable-code"])
        XCTAssertEqual(try codes("        throw new RuntimeException();\n        n++;").filter { $0 == "unreachable-code" }, ["unreachable-code"])
        XCTAssertEqual(try codes("        while (true) { n++; }\n        n++;").filter { $0 == "unreachable-code" }.count, 1)
        XCTAssertEqual(try codes("        for (int i = 0; i < n; i++) { break; }\n        n++;"), [])
        XCTAssertEqual(try codes("        outer: while (true) { while (true) { break outer; } }\n        n++;"), [])
        XCTAssertEqual(try codes("        switch (n) { case 1: return 1; default: return 2; }").filter { $0 == "unreachable-code" }, ["unreachable-code"])
        XCTAssertEqual(try codes("        switch (n) { case 1: return 1; default: break; }").filter { $0 == "unreachable-code" }, [])
        XCTAssertEqual(try codes("        if (n > 1) { return 1; } else { return 2; }\n        n++;").filter { $0 == "unreachable-code" }, ["unreachable-code"])
        XCTAssertEqual(try codes("        try { return 1; } finally { n++; }\n        n++;").filter { $0 == "unreachable-code" }, ["unreachable-code"])
        // The facts say the branch always returns, but the language does not: following code is reachable.
        XCTAssertEqual(try codes("        String s = null;\n        if (s == null) { return 1; }\n        n++;").filter { $0 == "unreachable-code" }, [])
    }

    // MARK: Resources

    func testResourceNotClosed() throws {
        XCTAssertEqual(try codes("        FileReader r = new FileReader(p);\n        r.read();"), ["resource-not-closed"])
        XCTAssertEqual(try codes("        FileReader r = new FileReader(p);\n        r.read();\n        r.close();"), [])
        XCTAssertEqual(try codes("        FileReader r = new FileReader(p);\n        try { r.read(); } finally { r.close(); }"), [])
        XCTAssertEqual(try codes("        FileReader r = new FileReader(p);\n        if (n > 0) { r.close(); }"), ["resource-not-closed"])
        XCTAssertEqual(try codes("        FileReader r = new FileReader(p);\n        return r.read();").filter { $0 == "resource-not-closed" }, ["resource-not-closed"])
        XCTAssertEqual(try codes("        FileReader r = new FileReader(p);\n        keep(r);", members: "    void keep(Reader r) {}"), [])
        XCTAssertEqual(try codes("        FileReader r = new FileReader(p);\n        for (int i = 0; i < n; i++) { r.read(); }\n        r.close();"), [])
        XCTAssertEqual(try codes("        try (FileReader r = new FileReader(p)) { r.read(); }"), [])
        XCTAssertEqual(try codes("        Scanner sc = new Scanner(System.in);\n        sc.nextLine();"), [])
        XCTAssertEqual(try codes("        FileReader r = new FileReader(p);\n        return new BufferedReader(r).read();").filter { $0 == "resource-not-closed" }, [])
    }

    func testFlowRulesCanBeDisabled() throws {
        let source = "class T {\n    void f() {\n        String s = null;\n        s.length();\n    }\n}\n"
        XCTAssertEqual(try run(source, [.redundantNullCheck]).count, 0)
        XCTAssertEqual(try run(source, [.nullDereference]).count, 1)
    }
}
