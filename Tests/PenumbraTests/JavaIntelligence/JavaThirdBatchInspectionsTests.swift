import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// Threading, security and probable-bug rules of the third batch, each run alone.
final class JavaThirdBatchInspectionsTests: XCTestCase {
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

    // MARK: Probable bugs

    func testSplitRegexSpecialChar() throws {
        let members = "    String s;"
        XCTAssertEqual(try count(.splitRegexSpecialChar, method("        String[] p = s.split(\".\");", members: members)), 1)
        XCTAssertEqual(try count(.splitRegexSpecialChar, method("        String[] p = s.split(\"|\");", members: members)), 1)
        XCTAssertEqual(try count(.splitRegexSpecialChar, method("        String r = s.replaceAll(\".\", \"x\");", members: members)), 1)
        XCTAssertEqual(try count(.splitRegexSpecialChar, method("        String[] p = s.split(\",\");", members: members)), 0)
        XCTAssertEqual(try count(.splitRegexSpecialChar, method("        String[] p = s.split(\"\\\\.\");", members: members)), 0)
        XCTAssertEqual(try count(.splitRegexSpecialChar, method("        String r = s.replaceAll(\"$\", \"x\");", members: members)), 0)
        // A Pattern's split takes input text, not a regex.
        XCTAssertEqual(try count(.splitRegexSpecialChar, method("        Pattern p = null;\n        String[] r = p.split(\".\");")), 0)
        XCTAssertEqual(
            try fixed(.splitRegexSpecialChar, method("        String[] p = s.split(\".\");", members: members)),
            method("        String[] p = s.split(\"\\\\.\");", members: members)
        )
    }

    func testExceptionCauseLost() throws {
        let lost = method("        try { g(); } catch (java.io.IOException e) { throw new IllegalStateException(\"bad\"); }")
        XCTAssertEqual(try count(.exceptionCauseLost, lost), 1)
        XCTAssertEqual(try count(.exceptionCauseLost, method("        try { g(); } catch (Exception e) { throw new IllegalStateException(\"bad\", e); }")), 0)
        XCTAssertEqual(try count(.exceptionCauseLost, method("        try { g(); } catch (Exception e) { log(e); throw new IllegalStateException(\"bad\"); }")), 0)
        XCTAssertEqual(try count(.exceptionCauseLost, method("        try { g(); } catch (Exception ignored) { throw new IllegalStateException(\"bad\"); }")), 0)
        XCTAssertEqual(try count(.exceptionCauseLost, method("        throw new IllegalStateException(\"bad\");")), 0)
        // An exception whose constructors take no cause cannot carry it.
        XCTAssertEqual(try count(.exceptionCauseLost, method("        try { g(); } catch (Exception e) { throw new UnknownHostException(\"x\"); }")), 0)
        XCTAssertEqual(try count(.exceptionCauseLost, method("        try { g(); } catch (Exception e) { throw new Object(); }")), 0)
    }

    func testFloatingPointEquality() throws {
        let declared = "        double d = 1.0;\n        double e = 2.0;\n        float f = 1f;\n        int n = 1;\n"
        XCTAssertEqual(try count(.floatingPointEquality, method(declared + "        boolean b = d == e;")), 1)
        XCTAssertEqual(try count(.floatingPointEquality, method(declared + "        boolean b = d != 0.1;")), 1)
        XCTAssertEqual(try count(.floatingPointEquality, method(declared + "        boolean b = f == d;")), 1)
        XCTAssertEqual(try count(.floatingPointEquality, method(declared + "        boolean b = d == 0;")), 0)
        XCTAssertEqual(try count(.floatingPointEquality, method(declared + "        boolean b = d == 0.0;")), 0)
        XCTAssertEqual(try count(.floatingPointEquality, method(declared + "        boolean b = d == Double.POSITIVE_INFINITY;")), 0)
        XCTAssertEqual(try count(.floatingPointEquality, method(declared + "        boolean b = n == 1;")), 0)
        XCTAssertEqual(try count(.floatingPointEquality, method(declared + "        boolean b = d < e;")), 0)
    }

    func testShiftOutOfRange() throws {
        let declared = "        int i = 1;\n        long l = 1L;\n"
        XCTAssertEqual(try count(.shiftOutOfRange, method(declared + "        int r = i << 32;")), 1)
        XCTAssertEqual(try count(.shiftOutOfRange, method(declared + "        long r = l >> 64;")), 1)
        XCTAssertEqual(try count(.shiftOutOfRange, method(declared + "        int r = i >>> -1;")), 1)
        XCTAssertEqual(try count(.shiftOutOfRange, method(declared + "        i <<= 40;")), 1)
        XCTAssertEqual(try count(.shiftOutOfRange, method(declared + "        long r = l << 40;")), 0)
        XCTAssertEqual(try count(.shiftOutOfRange, method(declared + "        int r = i << 31;")), 0)
        XCTAssertEqual(try count(.shiftOutOfRange, method("        int r = unknown << 40;")), 0)
    }

    func testAssignmentAsCondition() throws {
        XCTAssertEqual(try count(.assignmentAsCondition, method("        boolean flag = false;\n        if (flag = true) { }")), 1)
        XCTAssertEqual(try count(.assignmentAsCondition, method("        boolean flag = false;\n        boolean other = true;\n        while (flag = other) { }")), 1)
        // Assigning a computed value and testing it is a deliberate idiom.
        XCTAssertEqual(try count(.assignmentAsCondition, method("        boolean flag = false;\n        if (flag = (a == b)) { }")), 0)
        XCTAssertEqual(try count(.assignmentAsCondition, method("        boolean flag = false;\n        while (flag = next()) { }")), 0)
        XCTAssertEqual(try count(.assignmentAsCondition, method("        String line;\n        while ((line = read()) != null) { }")), 0)
        XCTAssertEqual(try count(.assignmentAsCondition, method("        boolean flag = false;\n        if (flag == true) { }")), 0)
        XCTAssertEqual(
            try fixed(.assignmentAsCondition, method("        boolean flag = false;\n        if (flag = true) { }")),
            method("        boolean flag = false;\n        if (flag == true) { }")
        )
    }

    // MARK: Threading

    func testVolatileNonAtomicUpdate() throws {
        let members = "    private volatile int count;\n    private int plain;"
        XCTAssertEqual(try count(.volatileNonAtomicUpdate, method("        count++;", members: members)), 1)
        XCTAssertEqual(try count(.volatileNonAtomicUpdate, method("        count += 2;", members: members)), 1)
        XCTAssertEqual(try count(.volatileNonAtomicUpdate, method("        this.count--;", members: members)), 1)
        XCTAssertEqual(try count(.volatileNonAtomicUpdate, method("        count = count + 1;", members: members)), 1)
        XCTAssertEqual(try count(.volatileNonAtomicUpdate, method("        count = 5;", members: members)), 0)
        // `this.count = count` stores a parameter; it reads nothing from the field.
        XCTAssertEqual(try count(.volatileNonAtomicUpdate, "class T {\n    private volatile int count;\n    void set(int count) { this.count = count; }\n}\n"), 0)
        XCTAssertEqual(try count(.volatileNonAtomicUpdate, method("        plain++;", members: members)), 0)
        XCTAssertEqual(try count(.volatileNonAtomicUpdate, method("        synchronized (this) { count++; }", members: members)), 0)
        // Another object's field of the same name is not a read of this one.
        XCTAssertEqual(try count(.volatileNonAtomicUpdate, "class T {\n    private volatile int count;\n    void copy(T src) { this.count = src.count; }\n}\n"), 0)
        // A private helper runs under its caller's lock, and a member that locks is guarded.
        XCTAssertEqual(try count(.volatileNonAtomicUpdate, "class T {\n    private volatile int count;\n    private void bump() { count++; }\n}\n"), 0)
        XCTAssertEqual(try count(.volatileNonAtomicUpdate, "class T {\n    private volatile int count;\n    public void bump() { lock.lock(); try { count++; } finally { lock.unlock(); } }\n}\n"), 0)
        XCTAssertEqual(try count(.volatileNonAtomicUpdate, method("        int count = 0;\n        count++;", members: members)), 0)
        XCTAssertEqual(
            try count(.volatileNonAtomicUpdate, "class T {\n    private volatile int count;\n    synchronized void up() { count++; }\n}\n"), 0
        )
    }

    func testWaitNotifyOutsideSynchronized() throws {
        XCTAssertEqual(try count(.waitNotifyOutsideSynchronized, "class T {\n    public void f() throws Exception { wait(); }\n}\n"), 1)
        XCTAssertEqual(try count(.waitNotifyOutsideSynchronized, "class T {\n    public void f() { lock.notifyAll(); }\n}\n"), 1)
        XCTAssertEqual(try count(.waitNotifyOutsideSynchronized, "class T {\n    public synchronized void f() throws Exception { wait(); }\n}\n"), 0)
        XCTAssertEqual(try count(.waitNotifyOutsideSynchronized, "class T {\n    public void f() throws Exception { synchronized (this) { wait(); } }\n}\n"), 0)
        XCTAssertEqual(try count(.waitNotifyOutsideSynchronized, "class T {\n    public void f() { synchronized (lock) { lock.notify(); } }\n}\n"), 0)
        // The wrong lock is still a bug.
        XCTAssertEqual(try count(.waitNotifyOutsideSynchronized, "class T {\n    public void f() { synchronized (other) { lock.notify(); } }\n}\n"), 1)
        // A private helper is normally called with the lock held.
        XCTAssertEqual(try count(.waitNotifyOutsideSynchronized, "class T {\n    private void f() throws Exception { wait(); }\n}\n"), 0)
        XCTAssertEqual(try count(.waitNotifyOutsideSynchronized, "class T {\n    public void f() { process.wait(5, 6, 7); }\n}\n"), 0)
    }

    func testStaticNonThreadSafeFormat() throws {
        XCTAssertEqual(try count(.staticNonThreadSafeFormat, "class T {\n    private static final SimpleDateFormat F = new SimpleDateFormat(\"x\");\n}\n"), 1)
        XCTAssertEqual(try count(.staticNonThreadSafeFormat, "class T {\n    static java.text.NumberFormat n;\n}\n"), 1)
        XCTAssertEqual(try count(.staticNonThreadSafeFormat, "class T {\n    private final SimpleDateFormat f = new SimpleDateFormat(\"x\");\n}\n"), 0)
        XCTAssertEqual(try count(.staticNonThreadSafeFormat, "class T {\n    private static final DateTimeFormatter F = null;\n}\n"), 0)
    }

    func testDoubleCheckedLocking() throws {
        let broken = "class T {\n    private Helper helper;\n    Helper get() {\n        if (helper == null) {\n            synchronized (this) {\n                if (helper == null) {\n                    helper = new Helper();\n                }\n            }\n        }\n        return helper;\n    }\n}\n"
        XCTAssertEqual(try count(.doubleCheckedLocking, broken), 1)
        XCTAssertEqual(try count(.doubleCheckedLocking, broken.replacingOccurrences(of: "private Helper", with: "private volatile Helper")), 0)
        XCTAssertEqual(
            try fixed(.doubleCheckedLocking, broken),
            broken.replacingOccurrences(of: "private Helper helper;", with: "private volatile Helper helper;")
        )
        let single = "class T {\n    private Helper helper;\n    void f() {\n        if (helper == null) {\n            helper = new Helper();\n        }\n    }\n}\n"
        XCTAssertEqual(try count(.doubleCheckedLocking, single), 0)
    }

    func testPatternCompileInLoop() throws {
        XCTAssertEqual(try count(.patternCompileInLoop, method("        for (String s : list) { Pattern p = Pattern.compile(\"a+\"); }", members: "    java.util.List<String> list;")), 1)
        XCTAssertEqual(try count(.patternCompileInLoop, method("        while (more()) { Pattern.compile(\"a+\"); }")), 1)
        XCTAssertEqual(try count(.patternCompileInLoop, method("        Pattern p = Pattern.compile(\"a+\");")), 0)
        XCTAssertEqual(try count(.patternCompileInLoop, method("        for (String s : list) { Pattern p = Pattern.compile(s); }", members: "    java.util.List<String> list;")), 0)
    }

    // MARK: Security

    func testWeakCryptographicAlgorithm() throws {
        XCTAssertEqual(try count(.weakCryptographicAlgorithm, method("        MessageDigest.getInstance(\"MD5\");")), 1)
        XCTAssertEqual(try count(.weakCryptographicAlgorithm, method("        MessageDigest.getInstance(\"SHA-1\");")), 1)
        XCTAssertEqual(try count(.weakCryptographicAlgorithm, method("        Cipher.getInstance(\"DES/CBC/PKCS5Padding\");")), 1)
        XCTAssertEqual(try count(.weakCryptographicAlgorithm, method("        Cipher.getInstance(\"AES/ECB/PKCS5Padding\");")), 1)
        XCTAssertEqual(try count(.weakCryptographicAlgorithm, method("        Cipher.getInstance(\"AES\");")), 1)
        XCTAssertEqual(try count(.weakCryptographicAlgorithm, method("        MessageDigest.getInstance(\"SHA-256\");")), 0)
        XCTAssertEqual(try count(.weakCryptographicAlgorithm, method("        Cipher.getInstance(\"AES/GCM/NoPadding\");")), 0)
        XCTAssertEqual(try count(.weakCryptographicAlgorithm, method("        Other.getInstance(\"MD5\");")), 0)
    }

    func testSqlStringConcatenation() throws {
        XCTAssertEqual(try count(.sqlStringConcatenation, method("        stmt.executeQuery(\"select * from t where id = \" + id);")), 1)
        XCTAssertEqual(try count(.sqlStringConcatenation, method("        conn.prepareStatement(\"delete from t where n = '\" + name + \"'\");")), 1)
        XCTAssertEqual(try count(.sqlStringConcatenation, method("        stmt.executeQuery(\"select * from t where id = ?\");")), 0)
        XCTAssertEqual(try count(.sqlStringConcatenation, method("        stmt.executeQuery(\"select \" + \"* from t\");")), 0)
        XCTAssertEqual(try count(.sqlStringConcatenation, method("        executor.execute(\"hello \" + name);")), 0)
        XCTAssertEqual(try count(.sqlStringConcatenation, method("        stmt.executeQuery(query);")), 0)
    }

    func testHardcodedCredential() throws {
        XCTAssertEqual(try count(.hardcodedCredential, method("        String password = \"hunter2\";")), 1)
        XCTAssertEqual(try count(.hardcodedCredential, "class T {\n    private static final String API_KEY_SECRET = \"abc123\";\n}\n"), 1)
        XCTAssertEqual(try count(.hardcodedCredential, method("        String password = \"\";")), 0)
        XCTAssertEqual(try count(.hardcodedCredential, method("        String password = read();")), 0)
        XCTAssertEqual(try count(.hardcodedCredential, method("        String passwordField = \"pw\";")), 0)
        XCTAssertEqual(try count(.hardcodedCredential, method("        String PASSWORD = \"password\";")), 0)
        XCTAssertEqual(try count(.hardcodedCredential, method("        String title = \"hunter2\";")), 0)
    }

    func testRuntimeExecConcatenation() throws {
        XCTAssertEqual(try count(.runtimeExecConcatenation, method("        Runtime.getRuntime().exec(\"ls \" + dir);")), 1)
        XCTAssertEqual(try count(.runtimeExecConcatenation, method("        Runtime.getRuntime().exec(\"ls -l\");")), 0)
        XCTAssertEqual(try count(.runtimeExecConcatenation, method("        Runtime.getRuntime().exec(new String[] {\"ls\", dir});")), 0)
        XCTAssertEqual(try count(.runtimeExecConcatenation, method("        service.exec(\"ls \" + dir);")), 0)
    }

    // MARK: JUnit

    private func test(_ body: String, imports: String = "import static org.junit.Assert.assertEquals;\n") -> String {
        imports + "class T {\n    void f() {\n\(body)\n    }\n}\n"
    }

    func testAssertEqualsArgumentOrder() throws {
        XCTAssertEqual(try count(.assertEqualsArgumentOrder, test("        assertEquals(actual, \"x\");")), 1)
        XCTAssertEqual(try count(.assertEqualsArgumentOrder, test("        assertEquals(compute(), 42);")), 1)
        XCTAssertEqual(try count(.assertEqualsArgumentOrder, test("        assertEquals(\"x\", actual);")), 0)
        XCTAssertEqual(try count(.assertEqualsArgumentOrder, test("        assertEquals(a, b);")), 0)
        XCTAssertEqual(try count(.assertEqualsArgumentOrder, test("        assertEquals(1, 2);")), 0)
        // JUnit 4 puts the message first, Jupiter last.
        XCTAssertEqual(try count(.assertEqualsArgumentOrder, test("        assertEquals(\"message\", actual, 42);")), 1)
        XCTAssertEqual(try count(.assertEqualsArgumentOrder, test("        assertEquals(actual, 42, \"message\");", imports: "import static org.junit.jupiter.api.Assertions.assertEquals;\n")), 1)
        XCTAssertEqual(try count(.assertEqualsArgumentOrder, test("        assertEquals(expected, actual, \"message\");", imports: "import static org.junit.jupiter.api.Assertions.assertEquals;\n")), 0)
        // TestNG takes the actual value first, and without a framework import nothing is known.
        XCTAssertEqual(try count(.assertEqualsArgumentOrder, test("        assertEquals(actual, \"x\");", imports: "import static org.testng.Assert.assertEquals;\n")), 0)
        XCTAssertEqual(try count(.assertEqualsArgumentOrder, test("        assertEquals(actual, \"x\");", imports: "")), 0)
        XCTAssertEqual(
            try fixed(.assertEqualsArgumentOrder, test("        assertEquals(actual, \"x\");")),
            test("        assertEquals(\"x\", actual);")
        )
    }

    func testEveryRuleOfTheBatchIsRegisteredAndDescribed() {
        let added: [JavaInspectionRule] = [
            .splitRegexSpecialChar, .volatileNonAtomicUpdate, .exceptionCauseLost, .waitNotifyOutsideSynchronized, .floatingPointEquality,
            .shiftOutOfRange, .assignmentAsCondition, .staticNonThreadSafeFormat, .patternCompileInLoop, .doubleCheckedLocking,
            .weakCryptographicAlgorithm, .sqlStringConcatenation, .hardcodedCredential, .runtimeExecConcatenation, .assertEqualsArgumentOrder,
        ]
        for rule in added {
            XCTAssertNotNil(JavaInspectionRegistry.inspection(for: rule), "\(rule.code) is not registered")
            XCTAssertEqual(
                rule.isEnabledByDefault, ![.hardcodedCredential, .floatingPointEquality].contains(rule), "\(rule.code) default state"
            )
        }
        let withFixes: Set<JavaInspectionRule> = [.splitRegexSpecialChar, .assignmentAsCondition, .doubleCheckedLocking, .assertEqualsArgumentOrder]
        XCTAssertEqual(Set(added.filter(\.hasQuickFix)), withFixes)
        XCTAssertEqual(JavaInspectionRule.sqlStringConcatenation.group, .security)
        XCTAssertEqual(JavaInspectionRule.doubleCheckedLocking.group, .threading)
        XCTAssertEqual(JavaInspectionRule.assertEqualsArgumentOrder.group, .testFrameworks)
    }
}
