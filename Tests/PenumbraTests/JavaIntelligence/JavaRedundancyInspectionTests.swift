import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaRedundancyInspectionTests: XCTestCase {
    private func codes(_ source: String, rule: JavaInspectionRule, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source), file: file, line: line)
        let context = try XCTUnwrap(JavaInspectionContext(source: source, tree: tree, url: URL(fileURLWithPath: "/proj/T.java"), index: JavaIndex()), file: file, line: line)
        return JavaInspectionRunner.run(context: context, enabled: [rule]).map(\.id)
    }

    private func fixed(_ source: String, rule: JavaInspectionRule, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source), file: file, line: line)
        let context = try XCTUnwrap(JavaInspectionContext(source: source, tree: tree, url: URL(fileURLWithPath: "/proj/T.java"), index: JavaIndex()), file: file, line: line)
        let finding = try XCTUnwrap(JavaInspectionRunner.run(context: context, enabled: [rule]).first, "no finding", file: file, line: line)
        let action = try XCTUnwrap(JavaInspectionRegistry.fixes(for: finding.asDiagnostic(), tree: tree, source: source).first, "no fix", file: file, line: line)
        var text = source as NSString
        for edit in action.edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            let range = NSRange(location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset)
            text = text.replacingCharacters(in: range, with: edit.replacement) as NSString
        }
        return text as String
    }

    func testRedundantLocalVariable() throws {
        let rule = JavaInspectionRule.redundantLocalVariable
        let source = "class T {\n    int f() {\n        int x = g();\n        return x;\n    }\n    int g() { return 1; }\n}\n"
        XCTAssertEqual(try codes(source, rule: rule), [rule.code])
        XCTAssertEqual(try fixed(source, rule: rule), "class T {\n    int f() {\n        return g();\n    }\n    int g() { return 1; }\n}\n")
        let thrown = "class T {\n    void f() {\n        RuntimeException e = new RuntimeException();\n        throw e;\n    }\n}\n"
        XCTAssertEqual(try codes(thrown, rule: rule), [rule.code])
        XCTAssertEqual(try codes("class T {\n    int f() {\n        int x = g();\n        x++;\n        return x;\n    }\n    int g() { return 1; }\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("class T {\n    Object f() {\n        long x = 1;\n        return x;\n    }\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("class T {\n    int[] f() {\n        int[] x = {1};\n        return x;\n    }\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("class T {\n    int f() {\n        int x = 1, y = 2;\n        return x;\n    }\n}\n", rule: rule), [])
    }

    func testRedundantStringOperation() throws {
        let rule = JavaInspectionRule.redundantStringOperation
        let wrap = { (body: String) in "class T {\n    String f(String s, String t) {\n        \(body)\n    }\n}\n" }
        XCTAssertEqual(try codes(wrap("return s.toString();"), rule: rule), [rule.code])
        XCTAssertEqual(try fixed(wrap("return s.toString();"), rule: rule), wrap("return s;"))
        XCTAssertEqual(try codes(wrap("return s.substring(0);"), rule: rule), [rule.code])
        XCTAssertEqual(try fixed(wrap("return s.substring(0);"), rule: rule), wrap("return s;"))
        XCTAssertEqual(try codes(wrap("return new String(s);"), rule: rule), [rule.code])
        XCTAssertEqual(try fixed(wrap("return new String(s + t).trim();"), rule: rule), wrap("return (s + t).trim();"))
        XCTAssertEqual(try codes(wrap("return s.substring(1);"), rule: rule), [])
        XCTAssertEqual(try codes(wrap("Object o = null; return o.toString();"), rule: rule), [])
        XCTAssertEqual(try codes(wrap("return new String(new char[0]);"), rule: rule), [])
    }

    func testDeclarationUsesConcreteClass() throws {
        let rule = JavaInspectionRule.declarationUsesConcreteClass
        let source = "import java.util.ArrayList;\n\nclass T {\n    int f() {\n        ArrayList<String> l = new ArrayList<>();\n        l.add(\"a\");\n        for (String s : l) { }\n        return l.size();\n    }\n}\n"
        XCTAssertEqual(try codes(source, rule: rule), [rule.code])
        XCTAssertEqual(
            try fixed(source, rule: rule),
            "import java.util.ArrayList;\nimport java.util.List;\n\nclass T {\n    int f() {\n        List<String> l = new ArrayList<>();\n        l.add(\"a\");\n        for (String s : l) { }\n        return l.size();\n    }\n}\n"
        )
        let wildcard = "import java.util.*;\nclass T {\n    private HashMap<String, String> m = new HashMap<>();\n    void f() { m.put(\"a\", \"b\"); this.m.clear(); }\n}\n"
        XCTAssertEqual(try codes(wildcard, rule: rule), [rule.code])
        XCTAssertEqual(try fixed(wildcard, rule: rule), wildcard.replacingOccurrences(of: "private HashMap", with: "private Map"))
        // Passing it on, returning it and concrete-only methods keep the declaration.
        XCTAssertEqual(try codes("import java.util.*;\nclass T {\n    void f() { ArrayList<String> l = new ArrayList<>(); g(l); }\n    void g(ArrayList<String> x) { }\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("import java.util.*;\nclass T {\n    Object f() { ArrayList<String> l = new ArrayList<>(); return l; }\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("import java.util.*;\nclass T {\n    void f() { LinkedList<String> l = new LinkedList<>(); l.addFirst(\"a\"); }\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("import java.util.*;\nclass T {\n    public ArrayList<String> l = new ArrayList<>();\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("import java.awt.List;\nimport java.util.ArrayList;\nclass T {\n    void f() { ArrayList<String> l = new ArrayList<>(); l.add(\"a\"); }\n}\n", rule: rule), [])
    }

    func testStaticViaSubclass() throws {
        let rule = JavaInspectionRule.staticViaSubclass
        let source = "class Base {\n    static int N = 1;\n    static void help() { }\n    void inst() { }\n}\nclass Sub extends Base { }\nclass Use {\n    void f() { Sub.help(); int a = Sub.N; }\n}\n"
        XCTAssertEqual(try codes(source, rule: rule), [rule.code, rule.code])
        XCTAssertEqual(try fixed(source, rule: rule), source.replacingOccurrences(of: "Sub.help", with: "Base.help"))
        XCTAssertEqual(try codes(source.replacingOccurrences(of: "class Sub extends Base { }", with: "class Sub extends Base { static void help() { } static int N; }"), rule: rule), [])
        XCTAssertEqual(try codes(source.replacingOccurrences(of: "Sub.help(); int a = Sub.N;", with: "Base.help(); int a = Base.N;"), rule: rule), [])
        XCTAssertEqual(try codes("class Base { static void help() { } void help(int x) { } }\nclass Sub extends Base { }\nclass Use { void f() { Sub.help(); } }\n", rule: rule), [])
        XCTAssertEqual(try codes("class Sub extends Lib { }\nclass Use { void f() { Sub.help(); } }\n", rule: rule), [])
    }
}
