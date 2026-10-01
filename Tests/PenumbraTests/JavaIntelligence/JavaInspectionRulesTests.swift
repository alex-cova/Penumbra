import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaInspectionRulesTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/proj/T.java")

    private func findings(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> [JavaInspection] {
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source), file: file, line: line)
        let context = try XCTUnwrap(JavaInspectionContext(source: source, tree: tree, url: url, index: JavaIndex()), "source must parse", file: file, line: line)
        return JavaInspectionRunner.run(context: context, enabled: Set(JavaInspectionRule.allCases))
    }

    private func codes(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        try findings(source, file: file, line: line).map(\.id)
    }

    /// The text after applying the first fix of the first finding for `rule`.
    private func fixed(_ source: String, rule: JavaInspectionRule, file: StaticString = #filePath, line: UInt = #line) throws -> String? {
        let inspection = try XCTUnwrap(findings(source, file: file, line: line).first { $0.id == rule.code }, "no \(rule.code) finding", file: file, line: line)
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        let actions = JavaInspectionRegistry.fixes(for: inspection.asDiagnostic(), tree: tree, source: source)
        guard let action = actions.first else { return nil }
        var text = source as NSString
        for edit in action.edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            let range = NSRange(location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset)
            text = text.replacingCharacters(in: range, with: edit.replacement) as NSString
        }
        return text as String
    }

    private func body(_ statements: String, members: String = "") -> String {
        "class T {\n\(members)\n    void f(String s, String t, int[] a, int[] b, Integer i, Integer j, int n, int m, double d) {\n\(statements)\n    }\n}\n"
    }

    // MARK: Probable bugs

    func testStringComparison() throws {
        XCTAssertEqual(try codes(body("        boolean x = s == t;")), ["string-comparison-identity"])
        XCTAssertEqual(try codes(body("        boolean x = s == \"a\";")), ["string-comparison-identity"])
        XCTAssertEqual(try codes(body("        boolean x = s == null;")), [])
        XCTAssertEqual(try codes(body("        boolean x = n == m;")), [])
        XCTAssertEqual(try fixed(body("        boolean x = s != t;"), rule: .stringComparisonIdentity)?.contains("boolean x = !s.equals(t);"), true)
        XCTAssertEqual(try fixed(body("        boolean x = \"a\" + s == t;"), rule: .stringComparisonIdentity)?.contains("(\"a\" + s).equals(t)"), true)
    }

    func testNumberComparison() throws {
        XCTAssertEqual(try codes(body("        boolean x = i == j;")), ["number-comparison-identity"])
        XCTAssertEqual(try codes(body("        boolean x = i == n;")), [])
        XCTAssertEqual(try fixed(body("        boolean x = i == j;"), rule: .numberComparisonIdentity)?.contains("i.equals(j)"), true)
    }

    func testArrayComparison() throws {
        XCTAssertEqual(try codes(body("        boolean x = a == b;")), ["array-comparison-identity"])
        XCTAssertEqual(try codes(body("        boolean x = a == null;")), [])
        XCTAssertEqual(try fixed(body("        boolean x = a != b;"), rule: .arrayComparisonIdentity)?.contains("!java.util.Arrays.equals(a, b)"), true)
    }

    func testEmptyStatementBody() throws {
        XCTAssertEqual(try codes(body("        if (n > 0);\n        n++;")), ["empty-statement-body"])
        XCTAssertEqual(try codes(body("        for (int k = 0; k < n; k++);")), ["empty-statement-body"])
        XCTAssertEqual(try codes(body("        while (n-- > 0);")), [], "a counting loop is an idiom")
        XCTAssertEqual(try codes(body("        while (s.isEmpty());")), [], "side effects in the condition are an idiom")
        XCTAssertEqual(try codes(body("        if (n > 0) { }")), [])
        XCTAssertEqual(try fixed(body("        if (n > 0);"), rule: .emptyStatementBody)?.contains("if (n > 0){}"), true)
    }

    func testSelfAssignmentAndSelfComparison() throws {
        let members = "    int x;\n    double y;\n    void g(int x) { this.x = this.x; x = x; }"
        XCTAssertEqual(try codes(body("", members: members)).filter { $0 == "self-assignment" }.count, 2)
        XCTAssertEqual(try codes(body("        boolean q = n == n;")), ["expression-compared-to-itself"])
        XCTAssertEqual(try codes(body("        boolean q = d != d;")), [], "x != x is the NaN test")
        XCTAssertEqual(try codes(body("        boolean q = s.equals(s);")), ["expression-compared-to-itself"])
        XCTAssertEqual(try codes(body("        n = m;")), [])
        XCTAssertEqual(try fixed(body("        n = n;\n        m++;"), rule: .selfAssignment), body("        m++;"))
    }

    func testMathRandomCast() throws {
        XCTAssertEqual(try codes(body("        int r = (int) Math.random();")), ["math-random-cast-to-int"])
        XCTAssertEqual(try codes(body("        int r = (int) (Math.random() * 10);")), [])
    }

    func testThrowableNotThrownAndAllocationIgnored() throws {
        XCTAssertEqual(try codes(body("        new IllegalStateException(\"x\");")), ["throwable-not-thrown"])
        XCTAssertEqual(try codes(body("        new StringBuilder();")), ["result-of-object-allocation-ignored"])
        XCTAssertEqual(try codes(body("        throw new IllegalStateException(\"x\");")), [])
        XCTAssertEqual(try codes(body("        Object o = new Object();")), [])
        XCTAssertEqual(try codes(body("        Object o = switch (n) { case 1 -> new Object(); default -> new Object(); };")), [], "a switch arm yields the object")
        XCTAssertEqual(try codes(body("        new Object() { };")), [])
        XCTAssertEqual(try codes(body("        new AppFailure();", members: "    static class AppFailure extends RuntimeException { }")), ["throwable-not-thrown"])
        XCTAssertEqual(try fixed(body("        new IllegalStateException(\"x\");"), rule: .throwableNotThrown)?.contains("throw new IllegalStateException"), true)
    }

    func testStringBuilderCharArgument() throws {
        XCTAssertEqual(try codes(body("        StringBuilder sb = new StringBuilder('c');")), ["string-builder-char-argument"])
        XCTAssertEqual(try codes(body("        StringBuilder sb = new StringBuilder(16);")), [])
        XCTAssertEqual(try codes(body("        StringBuilder sb = new StringBuilder(\"c\");")), [])
        XCTAssertEqual(try fixed(body("        StringBuilder sb = new StringBuilder('\\'');"), rule: .stringBuilderCharArgument)?.contains("new StringBuilder(\"'\")"), true)
    }

    func testArrayObjectMethodCalls() throws {
        XCTAssertEqual(try codes(body("        boolean x = a.equals(b);")), ["array-object-method-call"])
        XCTAssertEqual(try codes(body("        int h = a.hashCode();")), ["array-object-method-call"])
        XCTAssertEqual(try codes(body("        String x = a.toString();")), ["array-object-method-call"])
        XCTAssertEqual(try codes(body("        String x = s.toString();")), [])
        XCTAssertEqual(try fixed(body("        String x = a.toString();"), rule: .arrayObjectMethodCall)?.contains("java.util.Arrays.toString(a)"), true)
    }

    func testEqualsContract() throws {
        XCTAssertEqual(try codes("class A { public boolean equals(Object o) { return true; } }"), ["equals-hashcode-pair"])
        XCTAssertEqual(try codes("class A { public int hashCode() { return 1; } }"), ["equals-hashcode-pair"])
        XCTAssertEqual(try codes("class A { public boolean equals(Object o) { return true; } public int hashCode() { return 1; } }"), [])
        XCTAssertEqual(try codes("class B { public boolean equals(Object o) { return true; } public int hashCode() { return 1; } } class A extends B { public int hashCode() { return 2; } }"), [], "equals is inherited")
        XCTAssertEqual(try codes("class A extends Base { public int hashCode() { return 2; } }"), [], "unknown superclass")
        XCTAssertEqual(try codes("class B { } class A extends B { public int hashCode() { return 2; } }"), ["equals-hashcode-pair"])
        XCTAssertEqual(try codes("class A { public boolean equals(A o) { return true; } }"), ["covariant-equals"])
        XCTAssertEqual(try codes("class A { public boolean equals(A o) { return true; } public boolean equals(Object o) { return true; } public int hashCode() { return 1; } }"), [])
        XCTAssertEqual(try codes("class A { boolean equal(Object o) { return true; } }"), ["equal-instead-of-equals"])
        XCTAssertEqual(try fixed("class A { boolean equal(Object o) { return true; } }", rule: .equalInsteadOfEquals)?.contains("boolean equals(Object o)"), true)
    }

    func testSubtractionInCompareTo() throws {
        XCTAssertEqual(try codes("class A implements Comparable<A> { int v; public int compareTo(A o) { return v - o.v; } }"), ["subtraction-in-compareto"])
        XCTAssertEqual(try codes("class A implements Comparable<A> { int v; public int compareTo(A o) { return Integer.compare(v, o.v); } }"), [])
        XCTAssertEqual(try codes("class A implements Comparable<A> { String n; public int compareTo(A o) { return n.length() - o.n.length(); } }"), [])
        XCTAssertEqual(try codes("class A { char c; int g(A o) { return c - o.c; } }"), [])
    }

    func testSuspiciousIndentation() throws {
        XCTAssertEqual(try codes(body("        if (n > 0)\n            n++;\n            m++;")), ["suspicious-indentation"])
        XCTAssertEqual(try codes(body("        if (n > 0)\n            n++;\n        m++;")), [])
        XCTAssertEqual(try codes(body("        if (n > 0) {\n            n++;\n        }\n            m++;")), [])
        XCTAssertEqual(try codes(body("        while (n > 0)\n            n--;\n        m++;")), [])
    }

    // MARK: Verbose or redundant code

    func testUnnecessaryJumps() throws {
        XCTAssertEqual(try codes("class A { void f() { g();\n        return;\n    } void g() { } }"), ["unnecessary-return"])
        XCTAssertEqual(try codes("class A { int f() { return 1; } }"), [])
        XCTAssertEqual(try codes("class A { void f(boolean b) { if (b) { return; } g(); } void g() { } }"), [])
        XCTAssertEqual(try codes("class A { A() { return; } }"), ["unnecessary-return"])
        XCTAssertEqual(try codes("class A { void f() { for (int i = 0; i < 3; i++) { g(); continue; } } void g() { } }"), ["unnecessary-continue"])
        XCTAssertEqual(try codes("class A { void f() { for (int i = 0; i < 3; i++) { if (i > 1) continue; g(); } } void g() { } }"), [])
        XCTAssertEqual(try codes("class A { void f(int x) { switch (x) { case 1 -> { g(); break; } default -> { } } } void g() { } }"), ["unnecessary-break"])
        XCTAssertEqual(try codes("class A { void f(int x) { switch (x) { case 1: g(); break; default: break; } } void g() { } }"), [])
        XCTAssertEqual(try fixed("class A {\n    void f() {\n        g();\n        return;\n    }\n    void g() { }\n}\n", rule: .unnecessaryReturn),
                       "class A {\n    void f() {\n        g();\n    }\n    void g() { }\n}\n")
    }

    func testLabels() throws {
        XCTAssertEqual(try codes("class A { void f() { outer: for (;;) { break outer; } } }"), ["unnecessary-label-on-break"])
        XCTAssertEqual(try codes("class A { void f() { outer: for (;;) { for (;;) { break outer; } } } }"), [])
        XCTAssertEqual(try codes("class A { void f(int x) { outer: for (;;) { switch (x) { case 1: break outer; default: break; } } } }"), [])
        XCTAssertEqual(try codes("class A { void f() { outer: for (;;) { continue outer; } } }"), ["unnecessary-label-on-continue"])
        XCTAssertEqual(try codes("class A { void f(int x) { outer: for (;;) { switch (x) { case 1: continue outer; default: break; } } } }"), ["unnecessary-label-on-continue"])
        XCTAssertEqual(try codes("class A { void f() { outer: for (;;) { g(); } } void g() { } }"), ["unused-label"])
        XCTAssertEqual(try fixed("class A { void f() { outer: for (;;) { g(); } } void g() { } }", rule: .unusedLabel)?.contains("{ for (;;)"), true)
        XCTAssertEqual(try fixed("class A { void f() { outer: for (;;) { break outer; } } }", rule: .unnecessaryLabelOnBreak)?.contains("break; }"), true)
    }

    func testConcatenationWithEmptyString() throws {
        XCTAssertEqual(try codes(body("        String x = \"\" + n;")), ["concatenation-with-empty-string"])
        XCTAssertEqual(try fixed(body("        String x = n + \"\";"), rule: .concatenationWithEmptyString)?.contains("String.valueOf(n)"), true)
        XCTAssertNil(try fixed(body("        String x = s + \"\";"), rule: .concatenationWithEmptyString), "null handling differs for a String")
        XCTAssertNil(try fixed(body("        String x = \"\" + a;"), rule: .concatenationWithEmptyString), "arrays print differently")
        XCTAssertEqual(try codes(body("        String x = \"a\" + n;")), [])
    }

    func testManualMinMax() throws {
        XCTAssertEqual(try codes(body("        int r = n > m ? n : m;")), ["manual-min-max"])
        XCTAssertEqual(try fixed(body("        int r = n > m ? n : m;"), rule: .manualMinMax)?.contains("Math.max(n, m)"), true)
        XCTAssertEqual(try fixed(body("        int r = n > m ? m : n;"), rule: .manualMinMax)?.contains("Math.min(n, m)"), true)
        XCTAssertEqual(try fixed(body("        int r = n < m ? n : m;"), rule: .manualMinMax)?.contains("Math.min(n, m)"), true)
        XCTAssertEqual(try codes(body("        int r = n > m ? n : 0;")), [])
        XCTAssertEqual(try codes(body("        Integer r = i > j ? i : j;")), [], "boxed operands are left alone")
    }

    func testUnnecessarilyEscapedCharacter() throws {
        XCTAssertEqual(try codes(body("        String x = \"it\\'s\";")), ["unnecessarily-escaped-character"])
        XCTAssertEqual(try codes(body("        char c = '\\\"';")), ["unnecessarily-escaped-character"])
        XCTAssertEqual(try codes(body("        String x = \"it's \\\"q\\\"\";")), [])
        XCTAssertEqual(try codes(body("        char c = '\\'';")), [])
        XCTAssertEqual(try fixed(body("        String x = \"it\\'s\";"), rule: .unnecessarilyEscapedCharacter)?.contains("\"it's\""), true)
    }

    // MARK: Declaration redundancy

    func testDuplicateThrowsAndEmptyInitializer() throws {
        XCTAssertEqual(try codes("class A { void f() throws java.io.IOException, RuntimeException, RuntimeException { } }"), ["duplicate-throws"])
        XCTAssertEqual(try codes("class A { void f() throws java.io.IOException, RuntimeException { } }"), [])
        XCTAssertEqual(try fixed("class A { void f() throws Exception, Exception { } }", rule: .duplicateThrows)?.contains("throws Exception {"), true)
        XCTAssertEqual(try codes("class A { { } }"), ["empty-class-initializer"])
        XCTAssertEqual(try codes("class A { static { } }"), ["empty-class-initializer"])
        XCTAssertEqual(try codes("class A { static { init(); } static void init() { } }"), [])
        XCTAssertEqual(try codes("class A { void f() { { } } }"), [], "a nested block is not an initializer")
    }

    func testTextLabelInSwitch() throws {
        let typo = "class A { void f(int x) { switch (x) { case 1: foo(); break; defalt: bar(); } } void foo() { } void bar() { } }"
        XCTAssertEqual(try codes(typo), ["text-label-in-switch"])
        let intended = "class A { void f(int x) { switch (x) { case 1: outer: for (;;) { break outer; } default: break; } } }"
        XCTAssertEqual(try codes(intended).filter { $0 == "text-label-in-switch" }, [])
        XCTAssertEqual(try codes("class A { void f(int x) { outer: for (;;) { break; } } }").filter { $0 == "text-label-in-switch" }, [])
    }

    func testRedundantClose() throws {
        let source = "class A {\n    void f() throws Exception {\n        try (java.io.Reader r = open()) {\n            r.read();\n            r.close();\n        }\n    }\n}\n"
        XCTAssertEqual(try codes(source), ["redundant-close"])
        XCTAssertEqual(try fixed(source, rule: .redundantClose)?.contains("r.close()"), false)
        XCTAssertEqual(try fixed(source, rule: .redundantClose)?.contains("r.read();"), true)
        XCTAssertEqual(try codes("class A { void f() throws Exception { try (java.io.Reader r = open()) { r.close(); r.read(); } } }"), [], "not the last statement")
        XCTAssertEqual(try codes("class A { void f(java.io.Reader o) throws Exception { try (java.io.Reader r = open()) { o.close(); } } }"), [], "not a resource")
        XCTAssertEqual(try codes("class A { void f() throws Exception { java.io.Reader r = open(); try { r.close(); } finally { log(); } } }"), [])
    }

    func testReplacementHasNoEffect() throws {
        XCTAssertEqual(try codes(body("        String r = s.replace(\"a\", \"a\");")), ["replacement-has-no-effect"])
        XCTAssertEqual(try codes(body("        String r = s.replaceAll(\"ab\", \"ab\");")), ["replacement-has-no-effect"])
        XCTAssertEqual(try codes(body("        String r = s.replace('x', 'x');")), ["replacement-has-no-effect"])
        XCTAssertEqual(try codes(body("        String r = s.replaceAll(\".\", \".\");")), [], "every character becomes a dot")
        XCTAssertEqual(try codes(body("        String r = s.replace(\"a\", \"b\");")), [])
        XCTAssertEqual(try codes(body("        String r = s.replace(\"\", \"\");")), [])
        XCTAssertEqual(try codes(body("        String r = n.replace(\"a\", \"a\");".replacingOccurrences(of: "n.replace", with: "t.replace").replacingOccurrences(of: "t.replace", with: "make().replace"), members: "    String make() { return null; }")), [], "receiver type unknown")
        XCTAssertEqual(try fixed(body("        String r = s.replace(\"a\", \"a\");"), rule: .replacementHasNoEffect)?.contains("String r = s;"), true)
    }

    func testUnnecessaryDefaultForEnumSwitch() throws {
        let enumDecl = "enum Color { RED, GREEN }\n"
        let full = enumDecl + "class A { int f(Color c) { return switch (c) { case RED -> 1; case GREEN -> 2; default -> 0; }; } }"
        XCTAssertEqual(try codes(full), ["unnecessary-default-for-enum-switch"])
        let partial = enumDecl + "class A { int f(Color c) { return switch (c) { case RED -> 1; default -> 0; }; } }"
        XCTAssertEqual(try codes(partial), [])
        let colon = enumDecl + "class A { void f(Color c) { switch (c) { case RED: break; case GREEN: break; default: break; } } }"
        XCTAssertEqual(try codes(colon), [])
        let unknown = "class A { int f(Other c) { return switch (c) { case RED -> 1; default -> 0; }; } }"
        XCTAssertEqual(try codes(unknown), [])
        let grouped = enumDecl + "class A { int f(Color c) { return switch (c) { case RED, GREEN -> 1; default -> 0; }; } }"
        XCTAssertEqual(try codes(grouped), ["unnecessary-default-for-enum-switch"])
        let fixedText = try XCTUnwrap(try fixed(full, rule: .unnecessaryDefaultForEnumSwitch))
        XCTAssertFalse(fixedText.contains("default"))
        XCTAssertTrue(fixedText.contains("case GREEN -> 2;"))
    }

    func testRedundantFileCreation() throws {
        XCTAssertEqual(try codes(body("        Object r = new java.io.FileReader(new java.io.File(s));").replacingOccurrences(of: "java.io.", with: "")), ["redundant-file-creation"])
        XCTAssertEqual(try codes(body("        Object r = new FileInputStream(new File(\"a.txt\"));")), ["redundant-file-creation"])
        XCTAssertEqual(try codes(body("        Object r = new FileReader(new File(s, t));")), [], "two-argument File")
        XCTAssertEqual(try codes(body("        Object r = new FileReader(new File(parent()));", members: "    String parent() { return \"\"; }")), [], "path type unknown")
        XCTAssertEqual(try codes(body("        Object r = new FileReader(s);")), [])
        XCTAssertEqual(try codes(body("        Object r = new Thread(new File(s));")), [])
        XCTAssertEqual(try fixed(body("        Object r = new FileWriter(new File(s), true);"), rule: .redundantFileCreation)?.contains("new FileWriter(s, true)"), true)
    }

    private func tryCatch(_ catchBody: String, parameter: String = "IOException e", rest: String = "") -> String {
        "class A { void f() { try { g(); } catch (\(parameter)) { \(catchBody) } \(rest) } void g() throws Exception { } }"
    }

    func testEmptyCatch() throws {
        XCTAssertEqual(try codes(tryCatch("")), ["empty-catch-block"])
        XCTAssertEqual(try codes(tryCatch("/* nothing to do */")), [])
        XCTAssertEqual(try codes(tryCatch("", parameter: "IOException ignored")), [])
        XCTAssertEqual(try codes(tryCatch("", parameter: "IOException expected")), [])
        XCTAssertEqual(try codes(tryCatch("log(e);")), [])
        XCTAssertEqual(try codes(tryCatch("log(1);")), [], "an unused parameter is not reported")
    }

    func testCatchOfThrowable() throws {
        XCTAssertEqual(try codes(tryCatch("log(t);", parameter: "Throwable t")), ["catch-of-throwable"])
        XCTAssertEqual(try codes(tryCatch("log(t);", parameter: "IOException | Throwable t")), ["catch-of-throwable"])
        XCTAssertEqual(try codes(tryCatch("log(t);", parameter: "Exception t")), [])
    }

    func testCaughtExceptionRethrown() throws {
        XCTAssertEqual(try codes(tryCatch("throw e;")), ["caught-exception-rethrown"])
        XCTAssertEqual(try codes(tryCatch("throw e;", rest: "catch (Exception x) { log(x); }")), [], "a broader catch follows")
        XCTAssertEqual(try codes(tryCatch("log(e); throw e;")), [])
        XCTAssertEqual(try codes(tryCatch("throw new RuntimeException(e);")), [])
    }

    func testJumpOutOfFinally() throws {
        XCTAssertEqual(try codes("class A { int f() { try { g(); } finally { return 1; } } void g() { } }"), ["jump-out-of-finally"])
        XCTAssertEqual(try codes("class A { void f() { try { g(); } finally { throw new IllegalStateException(); } } void g() { } }"), ["jump-out-of-finally"])
        XCTAssertEqual(try codes("class A { void f() { try { g(); } finally { try { g(); } catch (RuntimeException e) { throw e; } } } void g() { } }").filter { $0 == "jump-out-of-finally" }, [], "caught by a nested try")
        XCTAssertEqual(try codes("class A { void f() { try { g(); } finally { Runnable r = () -> { return; }; r.run(); } } void g() { } }"), [])
    }

    func testEmptyFinallyAndTry() throws {
        XCTAssertEqual(try codes("class A { void f() { try { g(); } finally { } } void g() { } }"), ["empty-finally-block"])
        XCTAssertEqual(try codes("class A { void f() { try { } catch (RuntimeException e) { log(e); } } }"), ["empty-try-block"])
        XCTAssertEqual(try codes("class A { void f() { try { g(); } finally { // cleanup later\n } } void g() { } }"), [])
        XCTAssertEqual(try fixed("class A { void f() { try { g(); } catch (RuntimeException e) { log(e); } finally { } } void g() { } }", rule: .emptyFinallyBlock),
                       "class A { void f() { try { g(); } catch (RuntimeException e) { log(e); } } void g() { } }")
        XCTAssertNil(try fixed("class A { void f() { try { g(); } finally { } } void g() { } }", rule: .emptyFinallyBlock), "a lone finally cannot just be dropped")
    }

    func testCodeMaturityRules() throws {
        XCTAssertEqual(try codes(tryCatch("e.printStackTrace();")), ["print-stack-trace"])
        XCTAssertEqual(try codes(body("        Thread.dumpStack();")), ["print-stack-trace"])
        XCTAssertEqual(try codes(body("        log.printStackTrace(out);")), [])
        XCTAssertEqual(try codes(body("        System.out.println(s);")), ["system-out-err"])
        XCTAssertEqual(try codes(body("        System.err.println(s);")), ["system-out-err"])
        XCTAssertEqual(try codes(body("        out.println(s);")), [])
        XCTAssertEqual(try codes(body("        System.gc();")), ["system-gc-call"])
        XCTAssertEqual(try codes(body("        Runtime.getRuntime().gc();")), ["system-gc-call"])
        XCTAssertEqual(try codes(body("        pool.gc();")), [])
        XCTAssertEqual(try codes(body("        Object v = new Vector<String>();")), ["obsolete-collection"])
        XCTAssertEqual(try codes(body("        Object h = new Hashtable<String, String>(); Object k = new java.util.Stack<String>();")), ["obsolete-collection", "obsolete-collection"])
        XCTAssertEqual(try codes(body("        Object l = new ArrayList<String>();")), [])
        XCTAssertEqual(try codes("class A { protected void finalize() throws Throwable { } }"), ["finalize-declared"])
        XCTAssertEqual(try codes("class A { void finalize(int x) { } }"), [])
    }

    func testCleanCodeProducesNoFindings() throws {
        let source = """
        import java.util.List;

        class Clean {
            private final List<String> names;

            Clean(List<String> names) {
                this.names = names;
            }

            @Override
            public boolean equals(Object o) {
                return o instanceof Clean c && c.names.equals(names);
            }

            @Override
            public int hashCode() {
                return names.hashCode();
            }

            int largest(int a, int b) {
                return Math.max(a, b);
            }
        }
        """
        XCTAssertEqual(try codes(source), [])
    }
}
