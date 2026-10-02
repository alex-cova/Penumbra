import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaStyleUsageInspectionTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/proj/T.java")

    private func findings(_ source: String, rule: JavaInspectionRule, file: StaticString = #filePath, line: UInt = #line) throws -> [JavaInspection] {
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source), file: file, line: line)
        let context = try XCTUnwrap(JavaInspectionContext(source: source, tree: tree, url: url, index: JavaIndex()), "source must parse", file: file, line: line)
        if JavaInspectionRegistry.flowRules.contains(rule) { return JavaInspectionRunner.runFlow(context: context, enabled: [rule]).filter { $0.id == rule.code } }
        return JavaInspectionRunner.run(context: context, enabled: [rule]).filter { $0.id == rule.code }
    }

    private func messages(_ source: String, rule: JavaInspectionRule, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        try findings(source, rule: rule, file: file, line: line).map(\.message)
    }

    private func fixed(_ source: String, rule: JavaInspectionRule, file: StaticString = #filePath, line: UInt = #line) throws -> String? {
        let inspection = try XCTUnwrap(findings(source, rule: rule, file: file, line: line).first, "no \(rule.code) finding", file: file, line: line)
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        guard let action = JavaInspectionRegistry.fixes(for: inspection.asDiagnostic(), tree: tree, source: source).first else { return nil }
        var text = source as NSString
        for edit in action.edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            let range = NSRange(location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset)
            text = text.replacingCharacters(in: range, with: edit.replacement) as NSString
        }
        return text as String
    }

    private func method(_ body: String, members: String = "") -> String {
        "import java.util.*;\nclass T {\n\(members)\n    void f(List<String> names, String[] args) {\n\(body)\n    }\n}\n"
    }

    // MARK: local-can-be-final

    func testLocalCanBeFinal() throws {
        let rule = JavaInspectionRule.localCanBeFinal
        XCTAssertEqual(try messages(method("        int x = 1;\n        System.out.println(x);"), rule: rule), ["Local variable 'x' can be final"])
        XCTAssertEqual(try messages(method("        int x = 1;\n        x = 2;"), rule: rule), [])
        XCTAssertEqual(try messages(method("        int x = 1;\n        x++;"), rule: rule), [])
        XCTAssertEqual(try messages(method("        final int x = 1;"), rule: rule), [])
        XCTAssertEqual(try messages(method("        int x;\n        x = 1;"), rule: rule), [])
        XCTAssertEqual(try messages(method("        for (int i = 0; i < 3; i++) {}"), rule: rule), [])
        XCTAssertEqual(try fixed(method("        int x = 1;\n        System.out.println(x);"), rule: rule)?.contains("final int x = 1;"), true)
    }

    // MARK: unused-assignment

    func testUnusedAssignment() throws {
        let rule = JavaInspectionRule.unusedAssignment
        XCTAssertEqual(try messages(method("        int x = 1;\n        x = 2;\n        System.out.println(x);"), rule: rule),
                       ["The value assigned to 'x' is overwritten before it is used"])
        XCTAssertEqual(try messages(method("        int x = 0;\n        x = compute();\n        x = 5;\n        System.out.println(x);", members: "    int compute() { return 1; }"), rule: rule).count, 2)
        XCTAssertEqual(try messages(method("        int x = 0;\n        System.out.println(x);\n        x = 5;"), rule: rule),
                       ["The value assigned to 'x' is never used"])
        XCTAssertEqual(try messages(method("        int x = 0;\n        x = x + 1;\n        System.out.println(x);"), rule: rule), [])
        XCTAssertEqual(try messages(method("        int x = 0;\n        if (names.isEmpty()) { x = 1; }\n        System.out.println(x);"), rule: rule), [])
        // The loop reads the second value; only the initializer is dead.
        XCTAssertEqual(try messages(method("        int x = 0;\n        x = 1;\n        while (true) { System.out.println(x); }"), rule: rule).count, 1)
        XCTAssertEqual(try messages(method("        int x = 0;\n        for (String s : names) { x = s.length(); }\n        System.out.println(x);"), rule: rule), [])
    }

    func testUnusedAssignmentAcrossControlFlow() throws {
        let rule = JavaInspectionRule.unusedAssignment
        // Dead on every path: both branches overwrite before any read.
        XCTAssertEqual(try messages(method("        int x = 0;\n        if (names.isEmpty()) { x = 1; } else { x = 2; }\n        System.out.println(x);"), rule: rule).count, 1)
        // Live on the else path.
        XCTAssertEqual(try messages(method("        int x = compute();\n        if (names.isEmpty()) { x = 1; }\n        System.out.println(x);", members: "    int compute() { return 1; }"), rule: rule), [])
        // Overwritten in a loop body, read afterwards.
        XCTAssertEqual(try messages(method("        int x = compute();\n        for (String s : names) { x = s.length(); }\n        System.out.println(x);", members: "    int compute() { return 1; }"), rule: rule), [])
        // Stored, then only read on one exit path.
        XCTAssertEqual(try messages(method("        int x = 0;\n        x = compute();\n        if (names.isEmpty()) { return; }\n        System.out.println(x);", members: "    int compute() { return 1; }"), rule: rule).count, 1)
        XCTAssertEqual(try messages(method("        int x = 0;\n        x = compute();\n        try { System.out.println(x); } finally { }", members: "    int compute() { return 1; }"), rule: rule).count, 1)
        XCTAssertEqual(try messages(method("        int x = 0;\n        try { x = compute(); } catch (RuntimeException e) { }\n        System.out.println(x);", members: "    int compute() { return 1; }"), rule: rule), [])
    }

    // MARK: mismatched-collection-query-update

    func testMismatchedCollectionQueryUpdate() throws {
        let rule = JavaInspectionRule.mismatchedCollectionQueryUpdate
        XCTAssertEqual(try messages(method("        List<String> l = new ArrayList<>();\n        System.out.println(l.size());"), rule: rule),
                       ["Contents of collection 'l' are queried, but never updated"])
        XCTAssertEqual(try messages(method("        List<String> l = new ArrayList<>();\n        l.add(\"a\");"), rule: rule),
                       ["Contents of collection 'l' are updated, but never queried"])
        XCTAssertEqual(try messages(method("        StringBuilder sb = new StringBuilder();\n        sb.append(1);"), rule: rule),
                       ["Contents of StringBuilder 'sb' are updated, but never queried"])
        XCTAssertEqual(try messages(method("        List<String> l = new ArrayList<>();\n        l.add(\"a\");\n        System.out.println(l);"), rule: rule), [])
        XCTAssertEqual(try messages(method("        List<String> l = new ArrayList<>();\n        l.add(\"a\");\n        System.out.println(l.size());"), rule: rule), [])
        XCTAssertEqual(try messages(method("        List<String> l = new ArrayList<>(names);\n        System.out.println(l.size());"), rule: rule), [])
        XCTAssertEqual(try messages(method("        List<String> l = new ArrayList<>();\n        names = l;"), rule: rule), [])
        XCTAssertEqual(try messages(method("        Set<String> s = new HashSet<>();\n        if (s.add(\"a\")) {}"), rule: rule), [])
        XCTAssertEqual(try messages("class T {\n    private final List<String> items = new ArrayList<>();\n    void f() { items.add(\"a\"); }\n}\n", rule: rule),
                       ["Contents of collection 'items' are updated, but never queried"])
        XCTAssertEqual(try messages("class T {\n    private final List<String> items = new ArrayList<>();\n    void f() { items.add(\"a\"); }\n    int g() { return this.items.size(); }\n}\n", rule: rule), [])
        XCTAssertEqual(try messages("class T {\n    final List<String> items = new ArrayList<>();\n    void f() { items.add(\"a\"); }\n}\n", rule: rule), [])
    }

    // MARK: unused-private-member

    func testUnusedPrivateMember() throws {
        let rule = JavaInspectionRule.unusedPrivateMember
        XCTAssertEqual(try messages("class T {\n    private int a;\n    void f() {}\n}\n", rule: rule), ["Private field 'a' is never used"])
        XCTAssertEqual(try messages("class T {\n    private int a;\n    void f() { a = 1; }\n}\n", rule: rule), [])
        XCTAssertEqual(try messages("class T {\n    private void m() {}\n}\n", rule: rule), ["Private method 'm' is never used"])
        XCTAssertEqual(try messages("class T {\n    private void m() {}\n    void f() { this.m(); }\n}\n", rule: rule), [])
        XCTAssertEqual(try messages("class T {\n    private static class N {}\n}\n", rule: rule), ["Private class 'N' is never used"])
        XCTAssertEqual(try messages("class T {\n    private static class N {}\n    N n;\n}\n", rule: rule), [])
        XCTAssertEqual(try messages("class T {\n    private static final long serialVersionUID = 1L;\n}\n", rule: rule), [])
        XCTAssertEqual(try messages("class T {\n    @Inject private int a;\n}\n", rule: rule), [])
        XCTAssertEqual(try messages("@Data class T {\n    private int a;\n}\n", rule: rule), [])
        XCTAssertEqual(try messages("class T {\n    private T() {}\n}\n", rule: rule), [])
        XCTAssertEqual(try messages("class T {\n    private T(int x) {}\n}\n", rule: rule), ["Private constructor 'T' is never used"])
        XCTAssertEqual(try messages("class T {\n    private T(int x) {}\n    static T make() { return new T(1); }\n}\n", rule: rule), [])
        XCTAssertEqual(try fixed("class T {\n    private int a;\n    void f() {}\n}\n", rule: rule), "class T {\n    void f() {}\n}\n")
    }

    // MARK: for-can-be-foreach

    func testForCanBeForeachArray() throws {
        let rule = JavaInspectionRule.forCanBeForeach
        let source = method("        for (int i = 0; i < args.length; i++) {\n            System.out.println(args[i]);\n        }")
        XCTAssertEqual(try findings(source, rule: rule).count, 1)
        let result = try XCTUnwrap(try fixed(source, rule: rule))
        XCTAssertTrue(result.contains("for (String arg : args) {"), result)
        XCTAssertTrue(result.contains("System.out.println(arg);"), result)
        XCTAssertEqual(try findings(method("        for (int i = 0; i < args.length; i++) {\n            args[i] = \"\";\n        }"), rule: rule).count, 0)
        XCTAssertEqual(try findings(method("        for (int i = 0; i < args.length; i++) {\n            System.out.println(i + args[i]);\n        }"), rule: rule).count, 0)
        XCTAssertEqual(try findings(method("        for (int i = 1; i < args.length; i++) {\n            System.out.println(args[i]);\n        }"), rule: rule).count, 0)
        XCTAssertEqual(try findings(method("        for (int i = 0; i < args.length; i += 2) {\n            System.out.println(args[i]);\n        }"), rule: rule).count, 0)
    }

    func testForCanBeForeachList() throws {
        let rule = JavaInspectionRule.forCanBeForeach
        let source = method("        for (int i = 0; i < names.size(); i++) {\n            System.out.println(names.get(i));\n        }")
        XCTAssertEqual(try findings(source, rule: rule).count, 1)
        XCTAssertTrue(try XCTUnwrap(try fixed(source, rule: rule)).contains("for (String name : names) {"))
        XCTAssertEqual(try findings(method("        for (int i = 0; i < names.size(); i++) {\n            names.remove(i);\n        }"), rule: rule).count, 0)
        XCTAssertEqual(try findings(method("        for (int i = 0; i < names.size(); i++) {\n            System.out.println(names.get(i));\n            names.add(\"x\");\n        }"), rule: rule).count, 0)
    }

    func testForCanBeForeachIterator() throws {
        let rule = JavaInspectionRule.forCanBeForeach
        let source = method("        for (Iterator<String> it = names.iterator(); it.hasNext(); ) {\n            String s = it.next();\n            System.out.println(s);\n        }")
        XCTAssertEqual(try findings(source, rule: rule).count, 1)
        let result = try XCTUnwrap(try fixed(source, rule: rule))
        XCTAssertTrue(result.contains("for (String s : names) {"), result)
        XCTAssertFalse(result.contains("it.next()"), result)
        XCTAssertEqual(try findings(method("        for (Iterator<String> it = names.iterator(); it.hasNext(); ) {\n            String s = it.next();\n            it.remove();\n        }"), rule: rule).count, 0)
    }

    // MARK: try-finally-can-be-twr

    func testTryFinallyCanBeTryWithResources() throws {
        let rule = JavaInspectionRule.tryFinallyCanBeTryWithResources
        let source = method("        Scanner sc = new Scanner(System.in);\n        try {\n            sc.nextLine();\n        } finally {\n            sc.close();\n        }")
        XCTAssertEqual(try findings(source, rule: rule).count, 1)
        let result = try XCTUnwrap(try fixed(source, rule: rule))
        XCTAssertTrue(result.contains("try (Scanner sc = new Scanner(System.in)) {"), result)
        XCTAssertFalse(result.contains("finally"), result)
        let guarded = method("        Scanner sc = new Scanner(System.in);\n        try {\n            sc.nextLine();\n        } finally {\n            if (sc != null) { sc.close(); }\n        }")
        XCTAssertEqual(try findings(guarded, rule: rule).count, 1)
        let usedAfter = method("        Scanner sc = new Scanner(System.in);\n        try {\n            sc.nextLine();\n        } finally {\n            sc.close();\n        }\n        sc.hasNext();")
        XCTAssertEqual(try findings(usedAfter, rule: rule).count, 0)
        let notCloseable = method("        Foo f = new Foo();\n        try {\n            f.run();\n        } finally {\n            f.close();\n        }", members: "    static class Foo { void run() {} void close() {} }")
        XCTAssertEqual(try findings(notCloseable, rule: rule).count, 0)
        let more = method("        Scanner sc = new Scanner(System.in);\n        try {\n            sc.nextLine();\n        } finally {\n            sc.close();\n            System.out.println();\n        }")
        XCTAssertEqual(try findings(more, rule: rule).count, 0)
    }

    // MARK: Metrics

    private func metric(_ source: String, rule: JavaInspectionRule, limit: Int) throws -> [String] {
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        let context = try XCTUnwrap(JavaInspectionContext(source: source, tree: tree, url: url, index: JavaIndex(), thresholds: JavaInspectionThresholds([rule: limit])))
        return JavaInspectionRunner.run(context: context, enabled: [rule]).map(\.message)
    }

    func testCyclomaticComplexity() throws {
        let source = "class T {\n    int f(int a, int b) {\n        if (a > 0 && b > 0) { return 1; }\n        for (int i = 0; i < a; i++) { if (i == b || i == 2) { return i; } }\n        switch (a) { case 1: return 1; case 2: return 2; default: return 0; }\n    }\n}\n"
        // 1 + if + && + for + if + || + two cases = 8
        XCTAssertEqual(try metric(source, rule: .cyclomaticComplexity, limit: 7), ["Method 'f' has cyclomatic complexity 8, above the limit of 7"])
        XCTAssertEqual(try metric(source, rule: .cyclomaticComplexity, limit: 8), [])
    }

    func testNestingDepth() throws {
        let source = "class T {\n    void f(int a) {\n        if (a > 0) { for (;;) { while (a > 1) { a--; } } }\n        if (a == 1) {} else if (a == 2) {} else if (a == 3) {}\n    }\n}\n"
        XCTAssertEqual(try metric(source, rule: .nestingDepth, limit: 2).count, 1)
        XCTAssertEqual(try metric(source, rule: .nestingDepth, limit: 3), [])
    }

    func testParameterCount() throws {
        let source = "class T {\n    void f(int a, int b, String... rest) {}\n    T(int a, int b, int c, int d) {}\n}\n"
        XCTAssertEqual(try metric(source, rule: .parameterCount, limit: 3), ["'T' has 4 parameters, above the limit of 3"])
        XCTAssertEqual(try metric(source, rule: .parameterCount, limit: 2).count, 2)
    }

    func testLengths() throws {
        let source = "class T {\n    void f() {\n        int a;\n        int b;\n        int c;\n    }\n}\n"
        XCTAssertEqual(try metric(source, rule: .methodLength, limit: 10), [])
        XCTAssertEqual(try metric(source, rule: .methodLength, limit: 4).count, 1)
        XCTAssertEqual(try metric(source, rule: .classLength, limit: 6).count, 1)
        XCTAssertEqual(try metric(source, rule: .classLength, limit: 7), [])
    }

    // MARK: Javadoc

    func testJavadocMissingParamAndReturn() throws {
        let documented = "class T {\n    /**\n     * Adds.\n     * @param a first\n     */\n    int add(int a, int b) { return a + b; }\n}\n"
        XCTAssertEqual(try messages(documented, rule: .javadocMissingParam), ["Missing '@param' tag for parameter 'b'"])
        XCTAssertEqual(try messages(documented, rule: .javadocMissingReturn), ["Missing '@return' tag"])
        let fixedParam = try XCTUnwrap(try fixed(documented, rule: .javadocMissingParam))
        XCTAssertTrue(fixedParam.contains("     * @param b\n     */"), fixedParam)
        let fixedReturn = try XCTUnwrap(try fixed(documented, rule: .javadocMissingReturn))
        XCTAssertTrue(fixedReturn.contains("     * @return\n     */"), fixedReturn)
        let complete = "class T {\n    /**\n     * Adds.\n     * @param a first\n     * @param b second\n     * @return sum\n     */\n    int add(int a, int b) { return a + b; }\n}\n"
        XCTAssertEqual(try messages(complete, rule: .javadocMissingParam), [])
        XCTAssertEqual(try messages(complete, rule: .javadocMissingReturn), [])
        XCTAssertEqual(try messages("class T {\n    int add(int a) { return a; }\n}\n", rule: .javadocMissingParam), [])
        XCTAssertEqual(try messages("class T {\n    /** {@inheritDoc} */\n    int add(int a) { return a; }\n}\n", rule: .javadocMissingParam), [])
        XCTAssertEqual(try messages("class T {\n    /**\n     * Runs.\n     */\n    void run() {}\n}\n", rule: .javadocMissingReturn), [])
        XCTAssertEqual(try messages("class T {\n    /** One line. */\n    <E> void run(E e) {}\n}\n", rule: .javadocMissingParam).count, 2)
        XCTAssertEqual(try findings("class T {\n    /** One line. */\n    void run(int e) {}\n}\n", rule: .javadocMissingParam).first?.fixTitle, nil)
    }

    func testJavadocInvalidParam() throws {
        let source = "class T {\n    /**\n     * @param a first\n     * @param z nothing\n     * @param a again\n     */\n    void f(int a) {}\n}\n"
        XCTAssertEqual(try messages(source, rule: .javadocInvalidParam), ["'@param z' does not match a parameter", "Duplicate '@param a' tag"])
        XCTAssertEqual(try messages("class T {\n    /**\n     * @param <E> element\n     * @param e value\n     */\n    <E> void f(E e) {}\n}\n", rule: .javadocInvalidParam), [])
    }
}
