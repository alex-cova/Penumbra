import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// The second batch of rules: each runs alone, so a neighbouring rule never muddies the answer.
final class JavaMoreInspectionsTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/proj/T.java")

    private func findings(_ rule: JavaInspectionRule, _ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> [JavaInspection] {
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source), file: file, line: line)
        let context = try XCTUnwrap(JavaInspectionContext(source: source, tree: tree, url: url, index: JavaIndex()), "source must parse", file: file, line: line)
        return JavaInspectionRunner.run(context: context, enabled: [rule])
    }

    private func count(_ rule: JavaInspectionRule, _ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        try findings(rule, source, file: file, line: line).count
    }

    private func fixed(_ rule: JavaInspectionRule, _ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let inspection = try XCTUnwrap(findings(rule, source, file: file, line: line).first, "no \(rule.code) finding", file: file, line: line)
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        let action = try XCTUnwrap(
            JavaInspectionRegistry.fixes(for: inspection.asDiagnostic(), tree: tree, source: source).first, "no fix", file: file, line: line
        )
        var text = source as NSString
        for edit in action.edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            let range = NSRange(location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset)
            text = text.replacingCharacters(in: range, with: edit.replacement) as NSString
        }
        return text as String
    }

    private func method(_ body: String, members: String = "") -> String {
        "class T {\n\(members)\n    void f() {\n\(body)\n    }\n}\n"
    }

    // MARK: Unused local variable

    func testUnusedLocalVariable() throws {
        XCTAssertEqual(try count(.unusedLocalVariable, method("        int unused = 5;")), 1)
        XCTAssertEqual(try count(.unusedLocalVariable, method("        int used = 5;\n        System.out.println(used);")), 0)
        // A write counts as a use of the name, and a field of the same name is not a use.
        XCTAssertEqual(try count(.unusedLocalVariable, method("        int x = 1;\n        x = 2;")), 0)
        XCTAssertEqual(try count(.unusedLocalVariable, method("        int count = 1;", members: "    int count;\n    int g() { return count; }")), 1)
        XCTAssertEqual(try count(.unusedLocalVariable, method("        for (int i = 0; i < 3; i++) { }")), 0)
        XCTAssertEqual(try count(.unusedLocalVariable, method("        int a = 1, b = 2;\n        System.out.println(a);")), 1)
    }

    func testUnusedLocalVariableFixOnlyWhenNothingElseRuns() throws {
        XCTAssertEqual(try fixed(.unusedLocalVariable, method("        int unused = 5;\n        int keep = 1;\n        g(keep);")), method("        int keep = 1;\n        g(keep);"))
        let inspection = try XCTUnwrap(findings(.unusedLocalVariable, method("        int unused = compute();")).first)
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(method("        int unused = compute();")))
        XCTAssertTrue(JavaInspectionRegistry.fixes(for: inspection.asDiagnostic(), tree: tree, source: method("        int unused = compute();")).isEmpty)
    }

    // MARK: Field can be final

    func testFieldCanBeFinal() throws {
        XCTAssertEqual(try count(.fieldCanBeFinal, "class T {\n    private int size = 3;\n    int g() { return size; }\n}\n"), 1)
        XCTAssertEqual(try count(.fieldCanBeFinal, "class T {\n    private int size = 3;\n    void g() { size = 4; }\n}\n"), 0)
        XCTAssertEqual(try count(.fieldCanBeFinal, "class T {\n    private int size = 3;\n    void g() { size++; }\n}\n"), 0)
        XCTAssertEqual(try count(.fieldCanBeFinal, "class T {\n    private int size = 3;\n    void g(T o) { o.size += 2; }\n}\n"), 0)
        XCTAssertEqual(try count(.fieldCanBeFinal, "class T {\n    private int size;\n    T() { size = 3; }\n}\n"), 0)
        XCTAssertEqual(try count(.fieldCanBeFinal, "class T {\n    private final int size = 3;\n}\n"), 0)
        XCTAssertEqual(try count(.fieldCanBeFinal, "class T {\n    private volatile int size = 3;\n}\n"), 0)
        XCTAssertEqual(try count(.fieldCanBeFinal, "@Data\nclass T {\n    private int size = 3;\n}\n"), 0)
        XCTAssertEqual(try count(.fieldCanBeFinal, "class T {\n    @Inject private int size = 3;\n}\n"), 0)
        XCTAssertEqual(
            try fixed(.fieldCanBeFinal, "class T {\n    private static int size = 3;\n}\n"),
            "class T {\n    private static final int size = 3;\n}\n"
        )
    }

    // MARK: Optional.get

    func testOptionalGetWithoutCheck() throws {
        XCTAssertEqual(try count(.optionalGetWithoutCheck, method("        java.util.Optional<String> o = find();\n        use(o.get());")), 1)
        XCTAssertEqual(try count(.optionalGetWithoutCheck, method("        Optional<String> o = find();\n        use(o.get());")), 1)
        XCTAssertEqual(try count(.optionalGetWithoutCheck, method("        Optional<String> o = find();\n        if (o.isPresent()) { use(o.get()); }")), 0)
        XCTAssertEqual(try count(.optionalGetWithoutCheck, method("        Optional<String> o = find();\n        if (o.isEmpty()) { return; }\n        use(o.get());")), 0)
        XCTAssertEqual(try count(.optionalGetWithoutCheck, method("        Map<String, String> m = new HashMap<>();\n        use(m.get());")), 0)
        XCTAssertEqual(try count(.optionalGetWithoutCheck, method("        Supplier<String> s = null;\n        use(s.get());")), 0)
    }

    // MARK: Lambdas

    func testLambdaCanBeMethodReference() throws {
        let members = "    static String twice(String s) { return s + s; }"
        XCTAssertEqual(try count(.lambdaCanBeMethodReference, method("        run(x -> T.twice(x));", members: members)), 1)
        XCTAssertEqual(try count(.lambdaCanBeMethodReference, method("        run(x -> System.out.println(x));")), 1)
        XCTAssertEqual(try count(.lambdaCanBeMethodReference, method("        run(() -> T.go());")), 1)
        XCTAssertEqual(try count(.lambdaCanBeMethodReference, method("        run(s -> new StringBuilder(s));")), 1)
        XCTAssertEqual(try count(.lambdaCanBeMethodReference, method("        run((a, b) -> Math.max(a, b));")), 1)
        // Arguments reordered, extra work, a parameter as the receiver: not a plain forward.
        XCTAssertEqual(try count(.lambdaCanBeMethodReference, method("        run((a, b) -> Math.max(b, a));")), 0)
        XCTAssertEqual(try count(.lambdaCanBeMethodReference, method("        run(x -> T.twice(x + 1));", members: members)), 0)
        XCTAssertEqual(try count(.lambdaCanBeMethodReference, method("        run(x -> x.trim());")), 0)
        XCTAssertEqual(try count(.lambdaCanBeMethodReference, method("        run(x -> twice(x));", members: members)), 0)
        // A field receiver may change after the reference is made.
        XCTAssertEqual(try count(.lambdaCanBeMethodReference, method("        run(x -> out.println(x));", members: "    java.io.PrintStream out;")), 0)
        XCTAssertEqual(try fixed(.lambdaCanBeMethodReference, method("        run(x -> Foo.bar(x));")), method("        run(Foo::bar);"))
        XCTAssertEqual(try fixed(.lambdaCanBeMethodReference, method("        run(() -> new ArrayList<>());")), method("        run(ArrayList::new);"))
        XCTAssertEqual(try fixed(.lambdaCanBeMethodReference, method("        run(() -> this.work());")), method("        run(this::work);"))
    }

    func testLambdaBodyCanBeExpression() throws {
        XCTAssertEqual(try count(.lambdaBodyCanBeExpression, method("        run(x -> { return x + 1; });")), 1)
        XCTAssertEqual(try count(.lambdaBodyCanBeExpression, method("        run(x -> { print(x); });")), 1)
        XCTAssertEqual(try count(.lambdaBodyCanBeExpression, method("        run(x -> { int y = x; return y; });")), 0)
        XCTAssertEqual(try count(.lambdaBodyCanBeExpression, method("        run(x -> { return; });")), 0)
        XCTAssertEqual(try count(.lambdaBodyCanBeExpression, method("        run(x -> { // keep this\n            return x; });")), 0)
        XCTAssertEqual(try count(.lambdaBodyCanBeExpression, method("        run(x -> x + 1);")), 0)
        XCTAssertEqual(try fixed(.lambdaBodyCanBeExpression, method("        run(x -> { return x + 1; });")), method("        run(x -> x + 1);"))
        XCTAssertEqual(try fixed(.lambdaBodyCanBeExpression, method("        run(x -> { print(x); });")), method("        run(x -> print(x));"))
    }

    // MARK: Equals

    func testLiteralEqualsReversed() throws {
        let members = "    String name;"
        XCTAssertEqual(try count(.literalEqualsReversed, method("        boolean b = name.equals(\"x\");", members: members)), 1)
        XCTAssertEqual(try count(.literalEqualsReversed, method("        String s = null;\n        boolean b = s.equalsIgnoreCase(\"x\");")), 1)
        XCTAssertEqual(try count(.literalEqualsReversed, method("        boolean b = \"x\".equals(name);", members: members)), 0)
        XCTAssertEqual(try count(.literalEqualsReversed, method("        Object o = null;\n        boolean b = o.equals(\"x\");")), 0)
        XCTAssertEqual(try count(.literalEqualsReversed, method("        boolean b = name.equals(other);", members: members)), 0)
        XCTAssertEqual(
            try fixed(.literalEqualsReversed, method("        boolean b = name.equals(\"x\");", members: members)),
            method("        boolean b = \"x\".equals(name);", members: members)
        )
    }

    func testBigDecimalEquals() throws {
        XCTAssertEqual(try count(.bigDecimalEquals, method("        BigDecimal a = null;\n        BigDecimal b = null;\n        boolean r = a.equals(b);")), 1)
        XCTAssertEqual(try count(.bigDecimalEquals, method("        BigDecimal a = null;\n        boolean r = a.compareTo(a) == 0;")), 0)
        XCTAssertEqual(try count(.bigDecimalEquals, method("        String a = null;\n        boolean r = a.equals(a);")), 0)
    }

    // MARK: Redundancy

    func testRedundantFieldInitializer() throws {
        let source = "class T {\n    int a = 0;\n    boolean b = false;\n    String c = null;\n    long d = 0L;\n    double e = 0.0;\n    char f = '\\u0000';\n}\n"
        XCTAssertEqual(try count(.redundantFieldInitializer, source), 6)
        let kept = "class T {\n    int a = 1;\n    boolean b = true;\n    final int c = 0;\n    String d = \"\";\n    int e;\n}\n"
        XCTAssertEqual(try count(.redundantFieldInitializer, kept), 0)
        XCTAssertEqual(try count(.redundantFieldInitializer, "interface I {\n    int a = 0;\n}\n"), 0)
        XCTAssertEqual(try fixed(.redundantFieldInitializer, "class T {\n    private int a = 0;\n}\n"), "class T {\n    private int a;\n}\n")
        XCTAssertEqual(try fixed(.redundantFieldInitializer, "class T {\n    String s = null;\n}\n"), "class T {\n    String s;\n}\n")
    }

    func testUnnecessarySuperCall() throws {
        XCTAssertEqual(try count(.unnecessarySuperCall, "class T extends B {\n    T() {\n        super();\n        init();\n    }\n}\n"), 1)
        XCTAssertEqual(try count(.unnecessarySuperCall, "class T extends B {\n    T() {\n        super(1);\n    }\n}\n"), 0)
        XCTAssertEqual(try count(.unnecessarySuperCall, "class T extends B {\n    T() {\n        this(1);\n    }\n    T(int x) { }\n}\n"), 0)
        XCTAssertEqual(
            try fixed(.unnecessarySuperCall, "class T extends B {\n    T() {\n        super();\n        init();\n    }\n}\n"),
            "class T extends B {\n    T() {\n        init();\n    }\n}\n"
        )
    }

    func testRedundantInterfaceModifier() throws {
        let source = "interface I {\n    public void m();\n    abstract void n();\n    public static final int X = 1;\n    void ok();\n    default void d() { }\n}\n"
        XCTAssertEqual(try count(.redundantInterfaceModifier, source), 5)
        XCTAssertEqual(try count(.redundantInterfaceModifier, "class C {\n    public void m() { }\n}\n"), 0)
        XCTAssertEqual(
            try fixed(.redundantInterfaceModifier, "interface I {\n    public void m();\n}\n"),
            "interface I {\n    void m();\n}\n"
        )
    }

    func testStringLengthZeroCheck() throws {
        let members = "    String s;"
        XCTAssertEqual(try count(.stringLengthZeroCheck, method("        boolean b = s.length() == 0;", members: members)), 1)
        XCTAssertEqual(try count(.stringLengthZeroCheck, method("        boolean b = s.length() > 0;", members: members)), 1)
        XCTAssertEqual(try count(.stringLengthZeroCheck, method("        boolean b = 0 == s.length();", members: members)), 1)
        XCTAssertEqual(try count(.stringLengthZeroCheck, method("        boolean b = s.length() > 1;", members: members)), 0)
        XCTAssertEqual(try count(.stringLengthZeroCheck, method("        java.util.List<String> l = null;\n        boolean b = l.length() == 0;")), 0)
        XCTAssertEqual(
            try fixed(.stringLengthZeroCheck, method("        boolean b = s.length() == 0;", members: members)),
            method("        boolean b = s.isEmpty();", members: members)
        )
        XCTAssertEqual(
            try fixed(.stringLengthZeroCheck, method("        boolean b = s.length() != 0;", members: members)),
            method("        boolean b = !s.isEmpty();", members: members)
        )
    }

    // MARK: Probable bugs

    func testSwitchFallThrough() throws {
        let fall = "        switch (n) {\n            case 1:\n                a();\n            case 2:\n                b();\n                break;\n            default:\n                c();\n        }"
        XCTAssertEqual(try count(.switchFallThrough, method(fall, members: "    int n;")), 1)
        let stacked = "        switch (n) {\n            case 1:\n            case 2:\n                b();\n                break;\n            default:\n                return;\n        }"
        XCTAssertEqual(try count(.switchFallThrough, method(stacked, members: "    int n;")), 0)
        let commented = "        switch (n) {\n            case 1:\n                a();\n                // fall through\n            case 2:\n                b();\n        }"
        XCTAssertEqual(try count(.switchFallThrough, method(commented, members: "    int n;")), 0)
        let returning = "        switch (n) {\n            case 1:\n                a();\n                return;\n            case 2:\n                b();\n        }"
        XCTAssertEqual(try count(.switchFallThrough, method(returning, members: "    int n;")), 0)
        let afterLabel = "        switch (n) {\n            case 1:\n                a();\n            case 2: /* Fall through */\n                b();\n        }"
        XCTAssertEqual(try count(.switchFallThrough, method(afterLabel, members: "    int n;")), 0)
        let arrows = "        switch (n) {\n            case 1 -> a();\n            case 2 -> b();\n            default -> c();\n        }"
        XCTAssertEqual(try count(.switchFallThrough, method(arrows, members: "    int n;")), 0)
    }

    func testDuplicateCondition() throws {
        let duplicate = "        if (a > 1) { x(); } else if (b) { y(); } else if (a > 1) { z(); }"
        XCTAssertEqual(try count(.duplicateCondition, method(duplicate, members: "    int a;\n    boolean b;")), 1)
        XCTAssertEqual(try count(.duplicateCondition, method("        if (a > 1) { x(); } else if (a > 2) { y(); }", members: "    int a;")), 0)
        // Conditions with calls may differ from one evaluation to the next.
        XCTAssertEqual(try count(.duplicateCondition, method("        if (it.next()) { x(); } else if (it.next()) { y(); }", members: "    java.util.Iterator<String> it;")), 0)
        XCTAssertEqual(try count(.duplicateCondition, method("        if (b) { x(); }\n        if (b) { y(); }", members: "    boolean b;")), 0)
    }

    func testThreadRunCall() throws {
        XCTAssertEqual(try count(.threadRunCall, method("        new Thread(r).run();", members: "    Runnable r;")), 1)
        XCTAssertEqual(try count(.threadRunCall, method("        Thread t = new Thread(r);\n        t.run();", members: "    Runnable r;")), 1)
        XCTAssertEqual(try count(.threadRunCall, method("        Runnable t = r;\n        t.run();", members: "    Runnable r;")), 0)
        XCTAssertEqual(
            try fixed(.threadRunCall, method("        new Thread(r).run();", members: "    Runnable r;")),
            method("        new Thread(r).start();", members: "    Runnable r;")
        )
    }

    func testFormatArgumentCount() throws {
        let declared = "        String a = null;\n        String b = null;\n        Object[] args = null;\n"
        XCTAssertEqual(try count(.formatArgumentCount, method(declared + "        String s = String.format(\"%s and %s\", a);")), 1)
        XCTAssertEqual(try count(.formatArgumentCount, method(declared + "        String s = String.format(\"%s\", a, b);")), 1)
        XCTAssertEqual(try count(.formatArgumentCount, method("        System.out.printf(\"%d items%n\");")), 1)
        XCTAssertEqual(try count(.formatArgumentCount, method(declared + "        String s = \"%s-%s\".formatted(a);")), 1)
        XCTAssertEqual(try count(.formatArgumentCount, method(declared + "        String s = String.format(\"%s and %s\", a, b);")), 0)
        XCTAssertEqual(try count(.formatArgumentCount, method(declared + "        String s = String.format(\"100%% %s%n\", a);")), 0)
        XCTAssertEqual(try count(.formatArgumentCount, method(declared + "        String s = String.format(\"%2$s %1$s\", a, b);")), 0)
        // An array is spread into the varargs, and an argument of unknown type might be one.
        XCTAssertEqual(try count(.formatArgumentCount, method(declared + "        String s = String.format(\"%s %s\", args);")), 0)
        XCTAssertEqual(try count(.formatArgumentCount, method("        String s = String.format(\"%s %s\", unknown);")), 0)
        XCTAssertEqual(try count(.formatArgumentCount, method(declared + "        String s = String.format(pattern, a);")), 0)
    }

    func testEveryNewRuleIsRegisteredAndDescribed() {
        let added: [JavaInspectionRule] = [
            .unusedLocalVariable, .fieldCanBeFinal, .optionalGetWithoutCheck, .lambdaCanBeMethodReference, .lambdaBodyCanBeExpression,
            .literalEqualsReversed, .redundantFieldInitializer, .unnecessarySuperCall, .redundantInterfaceModifier, .switchFallThrough,
            .duplicateCondition, .threadRunCall, .stringLengthZeroCheck, .formatArgumentCount, .bigDecimalEquals,
        ]
        for rule in added {
            XCTAssertNotNil(JavaInspectionRegistry.inspection(for: rule), "\(rule.code) is not registered")
            // The two style preferences start off; everything else is on.
            let styleOnly: Set<JavaInspectionRule> = [.literalEqualsReversed, .redundantFieldInitializer]
            XCTAssertEqual(rule.isEnabledByDefault, !styleOnly.contains(rule), "\(rule.code) default state")
        }
        let withFixes: Set<JavaInspectionRule> = [
            .unusedLocalVariable, .fieldCanBeFinal, .lambdaCanBeMethodReference, .lambdaBodyCanBeExpression, .literalEqualsReversed,
            .redundantFieldInitializer, .unnecessarySuperCall, .redundantInterfaceModifier, .threadRunCall, .stringLengthZeroCheck,
        ]
        XCTAssertEqual(Set(added.filter(\.hasQuickFix)), withFixes)
    }
}
