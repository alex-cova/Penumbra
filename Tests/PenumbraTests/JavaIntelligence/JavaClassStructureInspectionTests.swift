import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaClassStructureInspectionTests: XCTestCase {
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

    func testUtilityClassWithPublicConstructor() throws {
        let rule = JavaInspectionRule.utilityClassWithPublicConstructor
        let explicit = "public class U {\n    public U() {}\n    static int f() { return 1; }\n}\n"
        XCTAssertEqual(try codes(explicit, rule: rule), [rule.code])
        XCTAssertEqual(try fixed(explicit, rule: rule), "public class U {\n    private U() {}\n    static int f() { return 1; }\n}\n")
        let implicit = "public class U {\n    static int f() { return 1; }\n}\n"
        XCTAssertEqual(try codes(implicit, rule: rule), [rule.code])
        XCTAssertEqual(try fixed(implicit, rule: rule), "public class U {\n    private U() {\n    }\n\n    static int f() { return 1; }\n}\n")
        XCTAssertEqual(try codes("public class U {\n    private U() {}\n    static int f() { return 1; }\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("public class U {\n    int x;\n    static int f() { return 1; }\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("public class U extends B {\n    static int f() { return 1; }\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("public class App {\n    public static void main(String[] args) {}\n}\n", rule: rule), [])
    }

    func testPublicField() throws {
        let rule = JavaInspectionRule.publicField
        XCTAssertEqual(try codes("class T {\n    public int x, y;\n}\n", rule: rule), [rule.code, rule.code])
        XCTAssertEqual(try codes("class T {\n    public static final int X = 1;\n    private int y;\n    int z;\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("class T {\n    @Inject public int x;\n}\n", rule: rule), [])
    }

    func testMissingSerialVersionUID() throws {
        let rule = JavaInspectionRule.missingSerialVersionUID
        let source = "class T implements java.io.Serializable {\n    int x;\n}\n"
        XCTAssertEqual(try codes(source, rule: rule), [rule.code])
        XCTAssertEqual(
            try fixed(source, rule: rule),
            "class T implements java.io.Serializable {\n    private static final long serialVersionUID = 1L;\n\n    int x;\n}\n"
        )
        XCTAssertEqual(try codes("class T implements Serializable {\n    private static final long serialVersionUID = 1L;\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("enum E implements Serializable { A }\n", rule: rule), [])
        XCTAssertEqual(try codes("class T implements Runnable {\n    public void run() {}\n}\n", rule: rule), [])
    }

    func testCloneWithoutCloneable() throws {
        let rule = JavaInspectionRule.cloneWithoutCloneable
        XCTAssertEqual(try codes("class T {\n    protected Object clone() { return null; }\n}\n", rule: rule), [rule.code])
        XCTAssertEqual(try codes("class T implements Cloneable {\n    protected Object clone() { return null; }\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("class T extends B {\n    protected Object clone() { return null; }\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("class T implements Marker {\n    protected Object clone() { return null; }\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("abstract class T {\n    protected Object clone() { return null; }\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("class T {\n    protected Object clone() throws CloneNotSupportedException { throw new CloneNotSupportedException(); }\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("class T {\n    Object clone(int n) { return null; }\n}\n", rule: rule), [])
    }

    func testFinalMethodInFinalClass() throws {
        let rule = JavaInspectionRule.finalMethodInFinalClass
        let source = "final class T {\n    public final void f() {}\n}\n"
        XCTAssertEqual(try codes(source, rule: rule), [rule.code])
        XCTAssertEqual(try fixed(source, rule: rule), "final class T {\n    public void f() {}\n}\n")
        XCTAssertEqual(try codes("class T {\n    final void f() {}\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("record R(int a) {\n    final int g() { return a; }\n}\n", rule: rule), [rule.code])
    }

    func testProtectedMemberInFinalClass() throws {
        let rule = JavaInspectionRule.protectedMemberInFinalClass
        let source = "final class T {\n    protected int x;\n}\n"
        XCTAssertEqual(try codes(source, rule: rule), [rule.code])
        XCTAssertEqual(try fixed(source, rule: rule), "final class T {\n    int x;\n}\n")
        XCTAssertEqual(try codes("final class T extends B {\n    @Override protected void f() {}\n    protected void finalize() {}\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("class T {\n    protected int x;\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("final class T extends B {\n    protected void g() {}\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("final class T extends B {\n    protected int x;\n    protected T() {}\n}\n", rule: rule), [rule.code, rule.code])
    }

    func testClassMayBeInterface() throws {
        let rule = JavaInspectionRule.classMayBeInterface
        XCTAssertEqual(try codes("abstract class T {\n    abstract void f();\n    public abstract int g(int a);\n    static final int X = 1;\n}\n", rule: rule), [rule.code])
        XCTAssertEqual(try codes("abstract class T {\n    abstract void f();\n    void g() {}\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("abstract class T {\n    abstract void f();\n    int x;\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("abstract class T {\n    protected abstract void f();\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("abstract class T extends B {\n    abstract void f();\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("abstract class T {\n    T() {}\n    abstract void f();\n}\n", rule: rule), [])
    }
}
