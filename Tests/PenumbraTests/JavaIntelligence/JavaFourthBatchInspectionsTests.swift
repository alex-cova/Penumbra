import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// Redundancy, class-structure and probable-bug rules of the fourth batch, each run alone.
final class JavaFourthBatchInspectionsTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/proj/T.java")

    private func findings(
        _ rule: JavaInspectionRule, _ source: String, level: Int? = 21, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [JavaInspection] {
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source), file: file, line: line)
        let context = try XCTUnwrap(
            JavaInspectionContext(source: source, tree: tree, url: url, index: JavaIndex(), languageLevel: level),
            "source must parse", file: file, line: line
        )
        return JavaInspectionRunner.run(context: context, enabled: [rule])
    }

    private func count(_ rule: JavaInspectionRule, _ source: String, level: Int? = 21, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        try findings(rule, source, level: level, file: file, line: line).count
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

    private func method(_ body: String, params: String = "", members: String = "") -> String {
        "class T {\n\(members)\n    void f(\(params)) {\n\(body)\n    }\n}\n"
    }

    // MARK: Redundancy

    func testUnnecessarySemicolon() throws {
        XCTAssertEqual(try count(.unnecessarySemicolon, "class T {\n    int x;;\n    void f() { }\n}\n"), 1)
        XCTAssertEqual(try count(.unnecessarySemicolon, "class T {\n    int x;\n    void f() { }\n}\n"), 0)
    }

    func testUnnecessaryToString() throws {
        XCTAssertEqual(try count(.unnecessaryToString, method("        String r = \"a\" + o.toString();", params: "Object o")), 1)
        XCTAssertEqual(try count(.unnecessaryToString, method("        String r = o.toString() + \"a\";", params: "Object o")), 1)
        // Without a String on the other side, dropping it would turn the concatenation into addition.
        XCTAssertEqual(try count(.unnecessaryToString, method("        String r = 1 + o.toString();", params: "Object o")), 0)
        XCTAssertEqual(try count(.unnecessaryToString, method("        String r = o.toString();", params: "Object o")), 0)
        XCTAssertEqual(
            try fixed(.unnecessaryToString, method("        String r = \"a\" + o.toString();", params: "Object o")),
            method("        String r = \"a\" + o;", params: "Object o")
        )
    }

    func testStringIndexOfContains() throws {
        let params = "String s, String t, java.util.List<String> l"
        XCTAssertEqual(try count(.stringIndexOfContains, method("        boolean b = s.indexOf(t) != -1;", params: params)), 1)
        XCTAssertEqual(try count(.stringIndexOfContains, method("        boolean b = s.indexOf(\"x\") >= 0;", params: params)), 1)
        XCTAssertEqual(try count(.stringIndexOfContains, method("        boolean b = s.indexOf(t) == -1;", params: params)), 1)
        XCTAssertEqual(try count(.stringIndexOfContains, method("        boolean b = s.indexOf(t) > 0;", params: params)), 0)
        // A char argument has no contains() overload.
        XCTAssertEqual(try count(.stringIndexOfContains, method("        boolean b = s.indexOf('x') != -1;", params: params)), 0)
        XCTAssertEqual(try count(.stringIndexOfContains, method("        boolean b = l.indexOf(t) != -1;", params: params)), 0)
        XCTAssertEqual(
            try fixed(.stringIndexOfContains, method("        boolean b = s.indexOf(t) == -1;", params: params)),
            method("        boolean b = !s.contains(t);", params: params)
        )
    }

    func testManualArrayCopy() throws {
        let params = "int[] a, int[] b, int n"
        let loop = "        for (int i = 0; i < n; i++) {\n            a[i] = b[i];\n        }"
        XCTAssertEqual(try count(.manualArrayCopy, method(loop, params: params)), 1)
        XCTAssertEqual(
            try fixed(.manualArrayCopy, method(loop, params: params)),
            method("        System.arraycopy(b, 0, a, 0, n);", params: params)
        )
        XCTAssertEqual(try count(.manualArrayCopy, method("        for (int i = 0; i < n; i++) a[i] = b[i + 1];", params: params)), 0)
        XCTAssertEqual(try count(.manualArrayCopy, method("        for (int i = 1; i < n; i++) a[i] = b[i];", params: params)), 0)
        XCTAssertEqual(try count(.manualArrayCopy, method("        for (int i = 0; i < n; i++) a[i] = a[i];", params: params)), 0)
        XCTAssertEqual(try count(.manualArrayCopy, method("        for (int i = 0; i < n; i++) { a[i] = b[i]; log(i); }", params: params)), 0)
    }

    func testArraysFillLoop() throws {
        let params = "int[] a, int n, int v"
        XCTAssertEqual(try count(.arraysFillLoop, method("        for (int i = 0; i < a.length; i++) a[i] = 0;", params: params)), 1)
        XCTAssertEqual(try count(.arraysFillLoop, method("        for (int i = 0; i < n; i++) a[i] = v;", params: params)), 1)
        XCTAssertEqual(try count(.arraysFillLoop, method("        for (int i = 0; i < n; i++) a[i] = i;", params: params)), 0)
        XCTAssertEqual(try count(.arraysFillLoop, method("        for (int i = 0; i < n; i++) a[i] = compute();", params: params)), 0)
        XCTAssertEqual(
            try fixed(.arraysFillLoop, method("        for (int i = 0; i < a.length; i++) a[i] = 0;", params: params)),
            method("        java.util.Arrays.fill(a, 0);", params: params)
        )
        XCTAssertEqual(
            try fixed(.arraysFillLoop, method("        for (int i = 0; i < n; i++) a[i] = v;", params: params)),
            method("        java.util.Arrays.fill(a, 0, n, v);", params: params)
        )
    }

    func testCollectionsSortToListSort() throws {
        let params = "java.util.List<String> l, java.util.Comparator<String> c, java.util.Set<String> s"
        XCTAssertEqual(try fixed(.collectionsSortToListSort, method("        Collections.sort(l);", params: params)), method("        l.sort(null);", params: params))
        XCTAssertEqual(try fixed(.collectionsSortToListSort, method("        Collections.sort(l, c);", params: params)), method("        l.sort(c);", params: params))
        XCTAssertEqual(try count(.collectionsSortToListSort, method("        Collections.sort(unknown);", params: params)), 0)
        XCTAssertEqual(try count(.collectionsSortToListSort, method("        Collections.sort(l);", params: params), level: nil), 0)
    }

    func testAppendConcatenation() throws {
        let params = "StringBuilder sb, String s, int n"
        XCTAssertEqual(try count(.appendConcatenation, method("        sb.append(\"a\" + s);", params: params)), 1)
        XCTAssertEqual(try count(.appendConcatenation, method("        sb.append(\"a\" + s + \"b\");", params: params)), 1)
        XCTAssertEqual(try count(.appendConcatenation, method("        sb.append(n + 1 + \"a\");", params: params)), 0)
        XCTAssertEqual(try count(.appendConcatenation, method("        sb.append(\"a\" + \"b\");", params: params)), 0)
        XCTAssertEqual(try count(.appendConcatenation, method("        sb.append(s);", params: params)), 0)
        XCTAssertEqual(
            try fixed(.appendConcatenation, method("        sb.append(\"a\" + s + \"b\");", params: params)),
            method("        sb.append(\"a\").append(s).append(\"b\");", params: params)
        )
    }

    func testLowercaseLongLiteral() throws {
        XCTAssertEqual(try count(.lowercaseLongLiteral, method("        long x = 100l;")), 1)
        XCTAssertEqual(try count(.lowercaseLongLiteral, method("        long x = 100L;")), 0)
        XCTAssertEqual(try fixed(.lowercaseLongLiteral, method("        long x = 100l;")), method("        long x = 100L;"))
    }

    func testDeprecatedTagWithoutAnnotation() throws {
        let tagged = "class T {\n    /**\n     * Old.\n     * @deprecated use g\n     */\n    void f() { }\n}\n"
        XCTAssertEqual(try count(.deprecatedTagWithoutAnnotation, tagged), 1)
        XCTAssertEqual(
            try fixed(.deprecatedTagWithoutAnnotation, tagged),
            "class T {\n    /**\n     * Old.\n     * @deprecated use g\n     */\n    @Deprecated\n    void f() { }\n}\n"
        )
        let annotated = "class T {\n    /** @deprecated use g */\n    @Deprecated\n    void f() { }\n}\n"
        XCTAssertEqual(try count(.deprecatedTagWithoutAnnotation, annotated), 0)
        XCTAssertEqual(try count(.deprecatedTagWithoutAnnotation, "class T {\n    /** Fine. */\n    void f() { }\n}\n"), 0)
    }

    // MARK: Class structure

    func testInnerClassMayBeStatic() throws {
        let plain = "class T {\n    private int x;\n    class Inner {\n        int v() { return 1; }\n    }\n}\n"
        XCTAssertEqual(try count(.innerClassMayBeStatic, plain), 1)
        XCTAssertEqual(
            try fixed(.innerClassMayBeStatic, plain),
            "class T {\n    private int x;\n    static class Inner {\n        int v() { return 1; }\n    }\n}\n"
        )
        let usesOuter = "class T {\n    private int x;\n    class Inner {\n        int v() { return x; }\n    }\n}\n"
        XCTAssertEqual(try count(.innerClassMayBeStatic, usesOuter), 0)
        let callsOuter = "class T {\n    int g() { return 1; }\n    class Inner {\n        int v() { return g(); }\n    }\n}\n"
        XCTAssertEqual(try count(.innerClassMayBeStatic, callsOuter), 0)
        let qualifiedThis = "class T {\n    class Inner {\n        Object v() { return T.this; }\n    }\n}\n"
        XCTAssertEqual(try count(.innerClassMayBeStatic, qualifiedThis), 0)
        let privateInner = "class T {\n    private final class Inner { }\n}\n"
        XCTAssertEqual(try fixed(.innerClassMayBeStatic, privateInner), "class T {\n    private static final class Inner { }\n}\n")
        let alreadyStatic = "class T {\n    static class Inner { }\n}\n"
        XCTAssertEqual(try count(.innerClassMayBeStatic, alreadyStatic), 0)
        let qualifiedNew = "class T {\n    class Inner { }\n    void f(T t) { Object o = t.new Inner(); }\n}\n"
        XCTAssertEqual(try count(.innerClassMayBeStatic, qualifiedNew), 0)
        let generic = "class T<E> {\n    class Inner {\n        E value;\n    }\n}\n"
        XCTAssertEqual(try count(.innerClassMayBeStatic, generic), 0)
    }

    func testMethodMayBeStatic() throws {
        let plain = "class T {\n    private int twice(int n) {\n        return n * 2;\n    }\n}\n"
        XCTAssertEqual(try count(.methodMayBeStatic, plain), 1)
        XCTAssertEqual(
            try fixed(.methodMayBeStatic, plain),
            "class T {\n    private static int twice(int n) {\n        return n * 2;\n    }\n}\n"
        )
        XCTAssertEqual(try count(.methodMayBeStatic, "class T {\n    int x;\n    private int g() { return x; }\n}\n"), 0)
        XCTAssertEqual(try count(.methodMayBeStatic, "class T {\n    private Object g() { return this; }\n}\n"), 0)
        XCTAssertEqual(try count(.methodMayBeStatic, "class T {\n    int h() { return 1; }\n    private int g() { return h(); }\n}\n"), 0)
        XCTAssertEqual(try count(.methodMayBeStatic, "class T {\n    private String g() { return toString(); }\n}\n"), 0)
        XCTAssertEqual(try count(.methodMayBeStatic, "class T<E> {\n    private E g(E e) { return e; }\n}\n"), 0)
        XCTAssertEqual(try count(.methodMayBeStatic, "class T extends B {\n    private int g() { return 1; }\n}\n"), 0)
        XCTAssertEqual(try count(.methodMayBeStatic, "class T {\n    public int g() { return 1; }\n}\n"), 0)
        XCTAssertEqual(try count(.methodMayBeStatic, "class T {\n    private synchronized int g() { return 1; }\n}\n"), 0)
    }

    func testFieldMayBeStatic() throws {
        XCTAssertEqual(try count(.fieldMayBeStatic, "class T {\n    private final int LIMIT = 10;\n}\n"), 1)
        XCTAssertEqual(
            try fixed(.fieldMayBeStatic, "class T {\n    private final int LIMIT = 10;\n}\n"),
            "class T {\n    private static final int LIMIT = 10;\n}\n"
        )
        XCTAssertEqual(try count(.fieldMayBeStatic, "class T {\n    private static final int LIMIT = 10;\n}\n"), 0)
        // Public and protected fields are API.
        XCTAssertEqual(try count(.fieldMayBeStatic, "class T {\n    public final int LIMIT = 10;\n}\n"), 0)
        XCTAssertEqual(try count(.fieldMayBeStatic, "class T {\n    protected final int LIMIT = 10;\n}\n"), 0)
        XCTAssertEqual(try count(.fieldMayBeStatic, "class T {\n    private final int n = compute();\n}\n"), 0)
        XCTAssertEqual(try count(.fieldMayBeStatic, "class T {\n    private int n = 10;\n}\n"), 0)
        XCTAssertEqual(try count(.fieldMayBeStatic, "class T {\n    private final int n;\n}\n"), 0)
    }

    func testUnusedParameter() throws {
        XCTAssertEqual(try count(.unusedParameter, "class T {\n    private void f(int a, int b) { use(a); }\n}\n"), 1)
        XCTAssertEqual(try count(.unusedParameter, "class T {\n    private void f(int a) { use(a); }\n}\n"), 0)
        XCTAssertEqual(try count(.unusedParameter, "class T {\n    public void f(int a, int b) { use(a); }\n}\n"), 0)
        XCTAssertEqual(try count(.unusedParameter, "class T {\n    private void readObject(java.io.ObjectInputStream in) { }\n}\n"), 0)
        XCTAssertEqual(try count(.unusedParameter, "class T {\n    private void f(int unusedFlag) { }\n}\n"), 0)
        XCTAssertEqual(try count(.unusedParameter, "class T {\n    private void f(@SuppressWarnings(\"unused\") int a) { }\n}\n"), 0)
    }

    func testNonSerializableField() throws {
        // ReentrantLock is Serializable, so it is not on the list.
        XCTAssertEqual(try count(.nonSerializableField, "class T implements java.io.Serializable {\n    private ReentrantLock lock;\n}\n"), 0)
        let thread = "class T implements java.io.Serializable {\n    private Thread worker;\n}\n"
        XCTAssertEqual(try count(.nonSerializableField, thread), 1)
        XCTAssertEqual(try count(.nonSerializableField, thread.replacingOccurrences(of: "private Thread", with: "private transient Thread")), 0)
        XCTAssertEqual(try count(.nonSerializableField, thread.replacingOccurrences(of: "implements java.io.Serializable ", with: "")), 0)
        let plain = "class Helper { }\nclass T implements Serializable {\n    private Helper helper;\n}\n"
        XCTAssertEqual(try count(.nonSerializableField, plain), 1)
        let serializableHelper = "class Helper implements Serializable { }\nclass T implements Serializable {\n    private Helper helper;\n}\n"
        XCTAssertEqual(try count(.nonSerializableField, serializableHelper), 0)
        let extended = "class Base { }\nclass Helper extends Base { }\nclass T implements Serializable {\n    private Helper helper;\n}\n"
        XCTAssertEqual(try count(.nonSerializableField, extended), 0)
    }

    func testRawTypeUsage() throws {
        XCTAssertEqual(try count(.rawTypeUsage, method("        List l = new ArrayList();")), 2)
        XCTAssertEqual(try count(.rawTypeUsage, method("        List<String> l = new ArrayList<>();")), 0)
        XCTAssertEqual(try count(.rawTypeUsage, "class T {\n    Map m;\n}\n"), 1)
        XCTAssertEqual(try count(.rawTypeUsage, "class Box<E> { }\nclass T {\n    Box b;\n    Box<String> ok;\n}\n"), 1)
        XCTAssertEqual(try count(.rawTypeUsage, "class T implements Comparable { }\n"), 0)
        XCTAssertEqual(try count(.rawTypeUsage, method("        String s = \"x\";")), 0)
    }

    func testUncheckedCast() throws {
        XCTAssertEqual(try count(.uncheckedCast, method("        List<String> l = (List<String>) o;", params: "Object o")), 1)
        XCTAssertEqual(try count(.uncheckedCast, method("        List<?> l = (List<?>) o;", params: "Object o")), 0)
        XCTAssertEqual(try count(.uncheckedCast, method("        String s = (String) o;", params: "Object o")), 0)
    }

    // MARK: Probable bugs

    func testSwitchEnumMissingCases() throws {
        let members = "    enum Color { RED, GREEN, BLUE }\n    Color color;"
        let missing = method("        switch (color) {\n            case RED:\n                a();\n                break;\n            case GREEN:\n                b();\n                break;\n        }", members: members)
        XCTAssertEqual(try count(.switchEnumMissingCases, missing), 1)
        let complete = method("        switch (color) {\n            case RED:\n            case GREEN:\n            case BLUE:\n                a();\n                break;\n        }", members: members)
        XCTAssertEqual(try count(.switchEnumMissingCases, complete), 0)
        let withDefault = method("        switch (color) {\n            case RED:\n                a();\n                break;\n            default:\n                b();\n        }", members: members)
        XCTAssertEqual(try count(.switchEnumMissingCases, withDefault), 0)
        let notAnEnum = method("        switch (n) {\n            case 1:\n                a();\n                break;\n        }", members: "    int n;")
        XCTAssertEqual(try count(.switchEnumMissingCases, notAnEnum), 0)
    }

    func testEmptySynchronizedBlock() throws {
        XCTAssertEqual(try count(.emptySynchronizedBlock, method("        synchronized (this) { }")), 1)
        XCTAssertEqual(try count(.emptySynchronizedBlock, method("        synchronized (this) { // wait for it\n        }")), 1)
        XCTAssertEqual(try count(.emptySynchronizedBlock, method("        synchronized (this) { a(); }")), 0)
    }

    func testSleepWhileHoldingLock() throws {
        XCTAssertEqual(try count(.sleepWhileHoldingLock, method("        synchronized (this) { Thread.sleep(10); }")), 1)
        XCTAssertEqual(try count(.sleepWhileHoldingLock, "class T {\n    synchronized void f() throws Exception { Thread.sleep(10); }\n}\n"), 1)
        XCTAssertEqual(try count(.sleepWhileHoldingLock, method("        Thread.sleep(10);")), 0)
        XCTAssertEqual(try count(.sleepWhileHoldingLock, method("        synchronized (this) { run(() -> Thread.sleep(10)); }")), 0)
    }

    func testEqualsIncompatibleTypes() throws {
        let params = "String s, Integer i, Long l, int n, long m"
        XCTAssertEqual(try count(.equalsIncompatibleTypes, method("        boolean b = s.equals(i);", params: params)), 1)
        XCTAssertEqual(try count(.equalsIncompatibleTypes, method("        boolean b = i.equals(l);", params: params)), 1)
        XCTAssertEqual(try count(.equalsIncompatibleTypes, method("        boolean b = l.equals(1);", params: params)), 1)
        XCTAssertEqual(try count(.equalsIncompatibleTypes, method("        boolean b = Objects.equals(i, m);", params: params)), 1)
        XCTAssertEqual(try count(.equalsIncompatibleTypes, method("        boolean b = i.equals(n);", params: params)), 0)
        XCTAssertEqual(try count(.equalsIncompatibleTypes, method("        boolean b = s.equals(\"x\");", params: params)), 0)
        XCTAssertEqual(try count(.equalsIncompatibleTypes, method("        boolean b = s.equals(unknown);", params: params)), 0)
    }

    func testIntegerOverflowInLongAssignment() throws {
        let params = "int a, int b, long c"
        XCTAssertEqual(try count(.integerOverflowInLongAssignment, method("        long x = a * b;", params: params)), 1)
        XCTAssertEqual(try count(.integerOverflowInLongAssignment, method("        long x = a * b * 1000;", params: params)), 1)
        XCTAssertEqual(try count(.integerOverflowInLongAssignment, method("        long x = a << 40;", params: params)), 1)
        XCTAssertEqual(try count(.integerOverflowInLongAssignment, method("        long x;\n        x = a * b;", params: params)), 1)
        XCTAssertEqual(try count(.integerOverflowInLongAssignment, method("        long x = 60 * 60 * 24 * 1000 * 365;", params: params)), 1)
        // Already long, or too small to overflow.
        XCTAssertEqual(try count(.integerOverflowInLongAssignment, method("        long x = a * c;", params: params)), 0)
        XCTAssertEqual(try count(.integerOverflowInLongAssignment, method("        long x = (long) a * b;", params: params)), 0)
        XCTAssertEqual(try count(.integerOverflowInLongAssignment, method("        long x = 60 * 60;", params: params)), 0)
        // A bounded factor, a small narrow type or a constant that fits cannot overflow.
        XCTAssertEqual(try count(.integerOverflowInLongAssignment, method("        long x = 12 * (a % 2);", params: params)), 0)
        XCTAssertEqual(try count(.integerOverflowInLongAssignment, method("        long x = 24 * HOUR;", params: params, members: "    static final int HOUR = 60 * 60 * 1000;")), 0)
        XCTAssertEqual(try count(.integerOverflowInLongAssignment, method("        long x = 24 * BIG;", params: params, members: "    static final int BIG = 1 << 30;")), 1)
        XCTAssertEqual(try count(.integerOverflowInLongAssignment, method("        long x = s * t;", params: "short s, short t")), 0)
        XCTAssertEqual(try count(.integerOverflowInLongAssignment, method("        long x = 1 << 3;", params: params)), 0)
        XCTAssertEqual(try count(.integerOverflowInLongAssignment, method("        int x = a * b;", params: params)), 0)
        XCTAssertEqual(
            try fixed(.integerOverflowInLongAssignment, method("        long x = a * b;", params: params)),
            method("        long x = (long) a * b;", params: params)
        )
    }

    func testRegistrationDefaultsAndFixes() {
        let added: [JavaInspectionRule] = [
            .unnecessarySemicolon, .unnecessaryToString, .stringIndexOfContains, .manualArrayCopy, .arraysFillLoop,
            .collectionsSortToListSort, .deprecatedTagWithoutAnnotation, .innerClassMayBeStatic, .switchEnumMissingCases,
            .appendConcatenation, .lowercaseLongLiteral, .emptySynchronizedBlock, .sleepWhileHoldingLock, .unusedParameter,
            .methodMayBeStatic, .fieldMayBeStatic, .rawTypeUsage, .uncheckedCast, .equalsIncompatibleTypes,
            .integerOverflowInLongAssignment, .nonSerializableField,
        ]
        let off: Set<JavaInspectionRule> = [.rawTypeUsage, .uncheckedCast, .methodMayBeStatic]
        let withoutFix: Set<JavaInspectionRule> = [
            .switchEnumMissingCases, .emptySynchronizedBlock, .sleepWhileHoldingLock, .unusedParameter, .rawTypeUsage,
            .uncheckedCast, .equalsIncompatibleTypes, .nonSerializableField,
        ]
        for rule in added {
            XCTAssertNotNil(JavaInspectionRegistry.inspection(for: rule), "\(rule.code) is not registered")
            XCTAssertEqual(rule.isEnabledByDefault, !off.contains(rule), "\(rule.code) default state")
            XCTAssertEqual(rule.hasQuickFix, !withoutFix.contains(rule), "\(rule.code) fix flag")
        }
        XCTAssertEqual(JavaInspectionRule.nonSerializableField.group, .serialization)
    }
}
