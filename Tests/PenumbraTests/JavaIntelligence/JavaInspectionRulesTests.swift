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

    /// Codes of the rule under test only, for sources that trip a neighbouring rule too.
    private func ruleCodes(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        try codes(source, file: file, line: line).filter { $0 == "subtraction-in-compareto" }
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
        XCTAssertEqual(try ruleCodes("class A implements Comparable<A> { int v; public int compareTo(A o) { return v - o.v; } }"), ["subtraction-in-compareto"])
        XCTAssertEqual(try ruleCodes("class A implements Comparable<A> { int v; public int compareTo(A o) { return Integer.compare(v, o.v); } }"), [])
        XCTAssertEqual(try ruleCodes("class A implements Comparable<A> { String n; public int compareTo(A o) { return n.length() - o.n.length(); } }"), [])
        XCTAssertEqual(try ruleCodes("class A { char c; int g(A o) { return c - o.c; } }"), [])
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
        XCTAssertEqual(try codes("class A { void f() { outer: for (;;) { continue outer; } } }").filter { $0 != "infinite-loop" }, ["unnecessary-label-on-continue"])
        XCTAssertEqual(try codes("class A { void f(int x) { outer: for (;;) { switch (x) { case 1: continue outer; default: break; } } } }").filter { $0 != "infinite-loop" }, ["unnecessary-label-on-continue"])
        XCTAssertEqual(try codes("class A { void f() { outer: for (;;) { g(); } } void g() { } }").filter { $0 != "infinite-loop" }, ["unused-label"])
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

    // MARK: Control flow

    func testRedundantIfStatement() throws {
        XCTAssertEqual(try codes("class A { boolean f(int n) { if (n > 0) return true; else return false; } }"), ["redundant-if-statement"])
        XCTAssertEqual(try codes("class A { boolean f(int n) { if (n > 0) { return false; } return true; } }"), ["redundant-if-statement"])
        XCTAssertEqual(try codes("class A { boolean f(int n) { if (n > 0) { return true; } else { return true; } } }"), ["identical-branches"])
        XCTAssertEqual(try codes("class A { int f(int n) { if (n > 0) return 1; else return 0; } }"), [])
        XCTAssertEqual(try codes("class A { boolean f(int n) { if (n > 0) return true; log(); return false; } void log() { } }"), [])
        XCTAssertEqual(try fixed("class A { boolean f(int n) { if (n > 0) return true; else return false; } }", rule: .redundantIfStatement),
                       "class A { boolean f(int n) { return n > 0; } }")
        XCTAssertEqual(try fixed("class A { boolean f(int n) { if (n > 0 && n < 9) { return false; } return true; } }", rule: .redundantIfStatement),
                       "class A { boolean f(int n) { return !(n > 0 && n < 9); } }")
        XCTAssertEqual(try fixed("class A { boolean f(boolean b) { if (!b) return false; return true; } }", rule: .redundantIfStatement),
                       "class A { boolean f(boolean b) { return b; } }")
    }

    func testSimplifiableConditionalExpression() throws {
        XCTAssertEqual(try codes(body("        boolean x = n > m ? true : false;")), ["simplifiable-conditional-expression"])
        XCTAssertEqual(try codes(body("        boolean x = n > m ? false : true;")), ["simplifiable-conditional-expression"])
        XCTAssertEqual(try codes(body("        boolean x = n > m ? true : true;")), ["identical-branches"])
        XCTAssertEqual(try codes(body("        boolean x = n > m ? s.isEmpty() : false;")), [])
        XCTAssertEqual(try fixed(body("        boolean x = n > m ? false : true;"), rule: .simplifiableConditional)?.contains("boolean x = !(n > m);"), true)
        XCTAssertEqual(try fixed(body("        boolean x = n > m ? true : false;"), rule: .simplifiableConditional)?.contains("boolean x = n > m;"), true)
    }

    func testIdenticalBranches() throws {
        XCTAssertEqual(try codes(body("        if (n > 0) { m = 1; } else { m = 1; }")), ["identical-branches"])
        XCTAssertEqual(try codes(body("        int r = n > 0 ? m : m;")), ["identical-branches"])
        XCTAssertEqual(try codes(body("        if (n > 0) { m = 1; } else { m = 2; }")), [])
        XCTAssertEqual(try codes(body("        if (n > 0) { m = 1; } else { // same\n m = 1; }")), [], "comments make it deliberate")
    }

    func testDuplicateSwitchBranches() throws {
        let duplicate = "class A { int f(int x) { return switch (x) { case 1 -> 10; case 2 -> 20; case 3 -> 10; default -> 0; }; } }"
        XCTAssertEqual(try codes(duplicate), ["duplicate-switch-branches"])
        let distinct = "class A { int f(int x) { return switch (x) { case 1 -> 10; case 2 -> 20; default -> 0; }; } }"
        XCTAssertEqual(try codes(distinct), [])
        let defaults = "class A { int f(int x) { return switch (x) { case 1 -> 0; default -> 0; }; } }"
        XCTAssertEqual(try codes(defaults), [], "default cannot be merged into a case list")
        let nullLabel = "class A { int f(String x) { return switch (x) { case \"a\" -> 1; case null -> 1; default -> 0; }; } }"
        XCTAssertEqual(try codes(nullLabel), [], "null cannot be merged into a case list")
        let empty = "class A { void f(int x) { switch (x) { case 1 -> { } case 2 -> { } default -> g(); } } void g() { } }"
        XCTAssertEqual(try codes(empty), [])
    }

    func testPointlessBooleanExpression() throws {
        XCTAssertEqual(try codes(body("        boolean x = n > 0 && true;")), ["pointless-boolean-expression"])
        XCTAssertEqual(try codes(body("        boolean x = false || n > 0;")), ["pointless-boolean-expression"])
        XCTAssertEqual(try codes(body("        boolean x = s.isEmpty() == true;")), ["pointless-boolean-expression"])
        XCTAssertEqual(try codes(body("        boolean x = s.isEmpty() != true;")), ["pointless-boolean-expression"])
        XCTAssertEqual(try codes(body("        boolean x = n > 0 && s.isEmpty();")), [])
        XCTAssertEqual(try fixed(body("        boolean x = s.isEmpty() == false;"), rule: .pointlessBooleanExpression)?.contains("boolean x = !s.isEmpty();"), true)
        XCTAssertEqual(try fixed(body("        boolean x = (n > 0 || m > 0) && true;"), rule: .pointlessBooleanExpression)?.contains("boolean x = (n > 0 || m > 0);"), true)
        // The call would be lost, so there is a warning but no fix.
        XCTAssertEqual(try codes(body("        boolean x = s.isEmpty() || true;")), ["pointless-boolean-expression"])
        XCTAssertNil(try fixed(body("        boolean x = s.isEmpty() || true;"), rule: .pointlessBooleanExpression))
        XCTAssertEqual(try fixed(body("        boolean x = n > 0 && false;"), rule: .pointlessBooleanExpression) == nil, true, "the other side is not a plain reference")
    }

    func testConstantCondition() throws {
        XCTAssertEqual(try codes(body("        if (true) { n++; }")), ["constant-condition"])
        XCTAssertEqual(try codes(body("        while (false) { n++; }")), ["constant-condition"])
        XCTAssertEqual(try codes(body("        int r = false ? n : m;")), ["constant-condition"])
        XCTAssertEqual(try codes(body("        if (n > 0) { n++; }")), [])
    }

    func testInfiniteLoop() throws {
        XCTAssertEqual(try codes("class A { void f() { while (true) { g(); } } void g() { } }"), ["infinite-loop"])
        XCTAssertEqual(try codes("class A { void f() { for (;;) { g(); } } void g() { } }"), ["infinite-loop"])
        XCTAssertEqual(try codes("class A { void f() { while (true) { if (g()) break; } } boolean g() { return true; } }"), [])
        XCTAssertEqual(try codes("class A { int f() { while (true) { if (g()) return 1; } } boolean g() { return true; } }"), [])
        XCTAssertEqual(try codes("class A { void f() { while (true) { g(); throw new IllegalStateException(); } } void g() { } }").filter { $0 == "infinite-loop" }, [])
        XCTAssertEqual(try codes("class A { void f() { while (true) { for (int i = 0; i < 3; i++) { break; } } } }").filter { $0 == "infinite-loop" }, ["infinite-loop"], "that break only leaves the inner loop")
        XCTAssertEqual(try codes("class A { void f() { while (true) { Runnable r = () -> { return; }; r.run(); } } }"), ["infinite-loop"], "a lambda's return is not ours")
        XCTAssertEqual(try codes("class A { void f() { while (true) { System.exit(0); } } }").filter { $0 == "infinite-loop" }, [])
        XCTAssertEqual(try codes("class A { void f() { while (g()) { } } boolean g() { return true; } }").filter { $0 == "infinite-loop" }, [])
    }

    func testLoopDoesNotLoop() throws {
        XCTAssertEqual(try codes("class A { void f(int n) { while (n > 0) { g(); break; } } void g() { } }"), ["loop-does-not-loop"])
        XCTAssertEqual(try codes("class A { int f(int n) { for (int i = 0; i < n; i++) { return i; } return -1; } }"), ["loop-does-not-loop"])
        XCTAssertEqual(try codes("class A { void f(int n) { while (n > 0) { if (n == 2) continue; g(); break; } } void g() { } }"), [])
        XCTAssertEqual(try codes("class A { int f(java.util.List<Integer> l) { for (int x : l) { return x; } return -1; } }"), [], "first-element idiom")
        XCTAssertEqual(try codes("class A { void f(int n) { while (n > 0) { g(); } } void g() { } }"), [])
    }

    // MARK: More probable bugs

    func testAssertRules() throws {
        XCTAssertEqual(try codes(body("        assert n++ > 0;")), ["assert-side-effects"])
        XCTAssertEqual(try codes(body("        assert (m = n) > 0 : \"set\";")), ["assert-side-effects"])
        XCTAssertEqual(try codes(body("        assert n > 0 : \"positive\";")), [])
        XCTAssertEqual(try codes(body("        assert true;")), ["constant-assert-condition"])
        XCTAssertEqual(try codes(body("        assert false : \"unreachable\";")), [])
        XCTAssertEqual(try fixed(body("        assert true;\n        n++;"), rule: .constantAssertCondition), body("        n++;"))
    }

    func testNonShortCircuitBoolean() throws {
        XCTAssertEqual(try codes(body("        boolean x = n > 0 & m > 0;")), ["non-short-circuit-boolean"])
        XCTAssertEqual(try codes(body("        boolean x = n > 0 | m > 0;")), ["non-short-circuit-boolean"])
        XCTAssertEqual(try codes(body("        int r = n & m;")), [])
        XCTAssertEqual(try fixed(body("        boolean x = n > 0 & m > 0;"), rule: .nonShortCircuitBoolean)?.contains("n > 0 && m > 0"), true)
        XCTAssertEqual(try fixed(body("        boolean x = n > 0 | m > 0;"), rule: .nonShortCircuitBoolean)?.contains("n > 0 || m > 0"), true)
        XCTAssertEqual(try codes(body("        boolean x = n > 0 & check();", members: "    boolean check() { return true; }")), [], "the call on the right is meant to run")
        XCTAssertEqual(try codes(body("        boolean y = true;\n        y |= check();", members: "    boolean check() { return true; }")), [], "accumulating a call's result")
        XCTAssertEqual(try codes(body("        boolean y = true;\n        y &= n > 0;")), ["non-short-circuit-boolean"])
        XCTAssertNil(try fixed(body("        boolean y = true;\n        y &= n > 0;"), rule: .nonShortCircuitBoolean))
    }

    func testComparableWithoutEquals() throws {
        XCTAssertEqual(try codes("class A implements Comparable<A> { public int compareTo(A o) { return 0; } }"), ["comparable-without-equals"])
        XCTAssertEqual(try codes("class A implements Comparable<A> { public int compareTo(A o) { return 0; } public boolean equals(Object o) { return true; } public int hashCode() { return 1; } }"), [])
        XCTAssertEqual(try codes("class A extends B implements Comparable<A> { public int compareTo(A o) { return 0; } }"), [], "a superclass may supply equals")
    }

    func testIteratorHasNextCallsNext() throws {
        XCTAssertEqual(try codes("class A implements java.util.Iterator<String> { public boolean hasNext() { return next() != null; } public String next() { return null; } }"), ["iterator-hasnext-calls-next"])
        XCTAssertEqual(try codes("class A { Object f() { return new java.util.Iterator<String>() { public boolean hasNext() { return next() != null; } public String next() { return null; } }; } }"), ["iterator-hasnext-calls-next"])
        XCTAssertEqual(try codes("class A implements java.util.Iterator<String> { int i; public boolean hasNext() { return i < 3; } public String next() { return null; } }"), [])
        XCTAssertEqual(try codes("class A { int i; public boolean hasNext() { return next() != null; } String next() { return null; } }"), [], "not an Iterator")
    }

    func testMismatchedStringCase() throws {
        XCTAssertEqual(try codes(body("        boolean x = s.toLowerCase().contains(\"ABC\");")), ["mismatched-string-case"])
        XCTAssertEqual(try codes(body("        boolean x = s.toUpperCase().equals(\"abc\");")), ["mismatched-string-case"])
        XCTAssertEqual(try codes(body("        boolean x = s.toLowerCase().startsWith(\"abc\\n\");")), [])
        XCTAssertEqual(try codes(body("        boolean x = s.toLowerCase().contains(t);")), [])
    }

    func testMissingWhitespaceInConcatenation() throws {
        XCTAssertEqual(try codes(body("        String q = \"select a\"\n            + \"from t\";")), ["missing-whitespace-in-concatenation"])
        XCTAssertEqual(try codes(body("        String q = \"select a \"\n            + \"from t\";")), [])
        XCTAssertEqual(try codes(body("        String q = \"select a\" + \"from t\";")), [], "same line")
        XCTAssertEqual(try codes(body("        String q = \"select a\"\n            + \"(x)\";")), [])
        XCTAssertEqual(try codes(body("        String q = \"and so on\\n\"\n            + \"that is all\";")), [], "ends in a newline escape")
        XCTAssertEqual(try codes(body("        String q = \"IO\"\n            + \"IOT\";")), [], "a table of codes is not prose")
        XCTAssertEqual(try codes(body("        String q = \"select a \"\n            + \"from b\"\n            + \"where c\";")), ["missing-whitespace-in-concatenation"])
    }

    func testClassNewInstance() throws {
        XCTAssertEqual(try codes(body("        Object o = c.newInstance();", members: "    Class<?> c;")), ["class-new-instance"])
        XCTAssertEqual(try codes(body("        Object o = Foo.class.newInstance();")), ["class-new-instance"])
        XCTAssertEqual(try codes(body("        Object o = Class.forName(s).newInstance();")), ["class-new-instance"])
        XCTAssertEqual(try codes(body("        Object o = ctor.newInstance();")), [])
    }

    func testRoundingOfIntegers() throws {
        XCTAssertEqual(try codes(body("        double r = Math.floor(n);")), ["rounding-of-integers"])
        XCTAssertEqual(try codes(body("        double r = Math.ceil(n / m);")), ["rounding-of-integers", "integer-division-in-floating-context"].filter { $0 == "rounding-of-integers" })
        XCTAssertEqual(try codes(body("        double r = Math.floor(d);")), [])
        XCTAssertEqual(try codes(body("        double r = Math.ceil(d / n);")), [])
    }

    func testIntegerDivisionInFloatingContext() throws {
        XCTAssertEqual(try codes(body("        double r = n / m;")), ["integer-division-in-floating-context"])
        XCTAssertEqual(try codes(body("        double r = 1 / 2;")), ["integer-division-in-floating-context"])
        XCTAssertEqual(try codes(body("        d = n / m;")), ["integer-division-in-floating-context"])
        XCTAssertEqual(try codes(body("        double r = (double) (n / m);")), ["integer-division-in-floating-context"])
        XCTAssertEqual(try codes(body("        double r = n / d;")), [])
        XCTAssertEqual(try codes(body("        int r = n / m;")), [])
        XCTAssertEqual(try fixed(body("        double r = n / m;"), rule: .integerDivisionInFloatingContext)?.contains("double r = (double) n / m;"), true)
        XCTAssertEqual(try fixed(body("        float r = (n + 1) / m;"), rule: .integerDivisionInFloatingContext)?.contains("float r = (float) (n + 1) / m;"), true)
    }

    func testStringConcatenationInFormat() throws {
        XCTAssertEqual(try codes(body("        String r = String.format(\"id \" + s);")), ["string-concatenation-in-format"])
        XCTAssertEqual(try codes(body("        String r = String.format(\"id %s\", s);")), [])
        XCTAssertEqual(try codes(body("        String r = String.format(\"id \" + \"x\");")), [])
        XCTAssertEqual(try codes(body("        out.printf(\"id \" + s);")), ["string-concatenation-in-format"])
        XCTAssertEqual(try codes(body("        String r = String.format(locale, \"id \" + s);", members: "    java.util.Locale locale;")), ["string-concatenation-in-format"])
    }

    func testCollectionAddedToItself() throws {
        XCTAssertEqual(try codes(body("        items.add(items);", members: "    java.util.List<Object> items;")), ["collection-added-to-itself"])
        XCTAssertEqual(try codes(body("        items.addAll(items);", members: "    java.util.List<Object> items;")), ["collection-added-to-itself"])
        XCTAssertEqual(try codes(body("        items.add(s);", members: "    java.util.List<Object> items;")), [])
        XCTAssertEqual(try codes(body("        sb.append(sb);", members: "    StringBuilder sb;")), [])
    }

    func testResultOfCallIgnored() throws {
        XCTAssertEqual(try codes(body("        s.trim();")), ["result-of-call-ignored"])
        XCTAssertEqual(try codes(body("        s.toLowerCase();")), ["result-of-call-ignored"])
        XCTAssertEqual(try codes(body("        Math.max(n, m);")), ["result-of-call-ignored"])
        XCTAssertEqual(try codes(body("        price.add(price);", members: "    java.math.BigDecimal price;")), ["result-of-call-ignored"])
        XCTAssertEqual(try codes(body("        String r = s.trim();")), [])
        XCTAssertEqual(try codes(body("        sb.append(s);", members: "    StringBuilder sb;")), [])
        XCTAssertEqual(try codes(body("        int r = switch (n) { case 1 -> Math.max(n, m); default -> 0; };")), [], "a switch arm yields the value")
    }

    func testOverwrittenElement() throws {
        XCTAssertEqual(try codes(body("        a[0] = 1;\n        a[0] = 2;")), ["overwritten-element"])
        XCTAssertEqual(try codes(body("        a[0] = 1;\n        a[0] = a[0] + 1;")), [])
        XCTAssertEqual(try codes(body("        a[0] = 1;\n        a[1] = 2;")), [])
        XCTAssertEqual(try codes(body("        map.put(\"k\", 1);\n        map.put(\"k\", 2);", members: "    java.util.Map<String, Integer> map;")), ["overwritten-element"])
        XCTAssertEqual(try codes(body("        map.put(\"k\", 1);\n        map.put(\"k\", map.get(\"k\") + 1);", members: "    java.util.Map<String, Integer> map;")), [])
        XCTAssertEqual(try codes(body("        map.put(\"k\", 1);\n        map.put(\"j\", 2);", members: "    java.util.Map<String, Integer> map;")), [])
    }

    func testInfiniteRecursion() throws {
        XCTAssertEqual(try codes("class A { void f(int x) { f(x); } }"), ["infinite-recursion"])
        XCTAssertEqual(try codes("class A { int g(int x) { log(); return g(x); } void log() { } }"), ["infinite-recursion"])
        XCTAssertEqual(try codes("class A { void h(int x) { h(x - 1); } }"), [])
        XCTAssertEqual(try codes("class A { void k(int x) { if (x > 0) k(x); } }"), [])
        XCTAssertEqual(try codes("class A { void p(int x) { p((long) x); } void p(long x) { } }"), [])
        XCTAssertEqual(try codes("class A { int q() { return q(); } }"), ["infinite-recursion"])
    }

    func testDuplicatedDelimiters() throws {
        XCTAssertEqual(try codes(body("        Object t = new StringTokenizer(s, \"aa\");")), ["duplicated-delimiters"])
        XCTAssertEqual(try codes(body("        Object t = new StringTokenizer(s, \"\\n\\n\");")), ["duplicated-delimiters"])
        XCTAssertEqual(try codes(body("        Object t = new StringTokenizer(s, \" \\t\\n\");")), [])
        XCTAssertEqual(try codes(body("        Object t = new StringTokenizer(s);")), [])
    }

    // MARK: Naming conventions

    func testClassAndTypeParameterNaming() throws {
        XCTAssertEqual(try codes("class my_class { }"), ["class-naming-convention"])
        XCTAssertEqual(try codes("interface lowerCase { }"), ["class-naming-convention"])
        XCTAssertEqual(try codes("enum color { RED }"), ["class-naming-convention"])
        XCTAssertEqual(try codes("class MyClass2 { }"), [])
        XCTAssertEqual(try codes("class Box<t> { }"), ["type-parameter-naming-convention"])
        XCTAssertEqual(try codes("class Box<T, Value> { }"), [])
    }

    func testMethodNaming() throws {
        XCTAssertEqual(try codes("class A { void Do_it() { } }"), ["method-naming-convention"])
        XCTAssertEqual(try codes("class A { void doIt2() { } }"), [])
        XCTAssertEqual(try codes("class A { @Override public String ToString() { return \"\"; } }"), [], "an override takes its name from the supertype")
        XCTAssertEqual(try codes("class A { @Test void should_work() { } }"), [], "test names read as sentences")
    }

    func testFieldAndConstantNaming() throws {
        XCTAssertEqual(try codes("class A { int Count; }"), ["field-naming-convention"])
        XCTAssertEqual(try codes("class A { int my_count; }"), ["field-naming-convention"])
        XCTAssertEqual(try codes("class A { static final int maxSize = 3; }"), ["field-naming-convention"])
        XCTAssertEqual(try codes("class A { static final int MAX_SIZE = 3; private int count; }"), [])
        XCTAssertEqual(try codes("interface I { int limit = 3; }"), ["field-naming-convention"])
        XCTAssertEqual(try codes("class A { static final long serialVersionUID = 1L; }"), [])
        XCTAssertEqual(try codes("class A { private static final Logger log = null; }"), [], "a logger handle")
    }

    func testVariableAndParameterNaming() throws {
        XCTAssertEqual(try codes("class A { void f() { int Count = 0; } }"), ["local-variable-naming-convention"])
        XCTAssertEqual(try codes("class A { void f(int[] xs) { for (int Item : xs) { } } }"), ["local-variable-naming-convention"])
        XCTAssertEqual(try codes("class A { void f() { int count = 0; int _ = 1; } }"), [])
        XCTAssertEqual(try codes("class A { void f() { final int PRIME = 31; } }"), [], "a local constant")
        XCTAssertEqual(try codes("class A { void f() { int PRIME = 31; } }"), ["local-variable-naming-convention"])
        XCTAssertEqual(try codes("class A { void f(int Count) { } }"), ["parameter-naming-convention"])
        XCTAssertEqual(try codes("class A { void f(int... Rest) { } }"), ["parameter-naming-convention"])
        XCTAssertEqual(try codes("record R(int X) { }"), [], "record components are named like fields")
        XCTAssertEqual(try codes("class A { void f(int count, String... rest) { } }"), [])
    }

    func testEnumConstantNaming() throws {
        XCTAssertEqual(try codes("enum E { Red, GREEN_2, blue }"), ["enum-constant-naming-convention", "enum-constant-naming-convention"])
        XCTAssertEqual(try codes("enum E { RED, DARK_RED }"), [])
    }

    func testNonConstantFieldNamedLikeConstant() throws {
        XCTAssertEqual(try codes("class A { static int MAX_SIZE = 3; }"), ["non-constant-field-named-like-constant"])
        XCTAssertEqual(try codes("class A { final int MAX_SIZE = 3; }"), ["non-constant-field-named-like-constant"])
        XCTAssertEqual(try codes("class A { static final int MAX_SIZE = 3; }"), [])
        XCTAssertEqual(try codes("class A { int N; }"), [], "a single letter")
    }

    func testMethodNameSameAsClass() throws {
        XCTAssertEqual(try codes("class Widget { void Widget() { } }"), ["method-name-same-as-class"])
        XCTAssertEqual(try codes("class Widget { Widget() { } }"), [])
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
