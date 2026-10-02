import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaConcurrencyCollectionInspectionTests: XCTestCase {
    private func codes(_ source: String, rule: JavaInspectionRule, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source), file: file, line: line)
        let context = try XCTUnwrap(JavaInspectionContext(source: source, tree: tree, url: URL(fileURLWithPath: "/proj/T.java"), index: JavaIndex()), file: file, line: line)
        return JavaInspectionRunner.run(context: context, enabled: [rule]).map(\.id)
    }

    private func cls(_ members: String) -> String { "class T {\n    Object lock = new Object();\n\(members)\n}\n" }

    func testOverridableMethodCalledInConstructor() throws {
        let rule = JavaInspectionRule.overridableMethodCalledInConstructor
        XCTAssertEqual(try codes(cls("    T() { init(); this.setup(1); }\n    void init() { }\n    protected void setup(int a) { }"), rule: rule), [rule.code, rule.code])
        XCTAssertEqual(try codes(cls("    T() { init(); }\n    private void init() { }"), rule: rule), [])
        XCTAssertEqual(try codes(cls("    T() { init(); }\n    final void init() { }"), rule: rule), [])
        XCTAssertEqual(try codes(cls("    T() { init(); }\n    static void init() { }"), rule: rule), [])
        XCTAssertEqual(try codes(cls("    T() { init(1); }\n    void init() { }"), rule: rule), [])
        XCTAssertEqual(try codes(cls("    T() { Runnable r = () -> init(); }\n    void init() { }"), rule: rule), [])
        XCTAssertEqual(try codes("final class T {\n    T() { init(); }\n    void init() { }\n}\n", rule: rule), [])
        XCTAssertEqual(try codes("class T {\n    private T() { init(); }\n    void init() { }\n}\n", rule: rule), [])
    }

    func testSynchronization() throws {
        let literal = JavaInspectionRule.synchronizationOnStringLiteral
        let this = JavaInspectionRule.synchronizationOnThis
        let source = cls("    void f() { synchronized (\"lock\") { } synchronized (this) { } synchronized (lock) { } }")
        XCTAssertEqual(try codes(source, rule: literal), [literal.code])
        XCTAssertEqual(try codes(source, rule: this), [this.code])
    }

    func testWaitNotInLoop() throws {
        let rule = JavaInspectionRule.waitNotInLoop
        XCTAssertEqual(try codes(cls("    void f() throws Exception { synchronized (lock) { lock.wait(); } }"), rule: rule), [rule.code])
        XCTAssertEqual(try codes(cls("    void f() throws Exception { synchronized (this) { wait(10); } }"), rule: rule), [rule.code])
        XCTAssertEqual(try codes(cls("    boolean ready;\n    void f() throws Exception { synchronized (lock) { while (!ready) { lock.wait(); } } }"), rule: rule), [])
        XCTAssertEqual(try codes(cls("    void f(Process p) throws Exception { p.wait(); }"), rule: rule), [])
        // A loop outside the lambda does not make the wait inside it safe.
        XCTAssertEqual(try codes(cls("    void f() { while (true) { Runnable r = () -> { try { lock.wait(); } catch (Exception e) { } }; } }"), rule: rule), [rule.code])
    }

    func testSortedCollectionWithNonComparableElements() throws {
        let rule = JavaInspectionRule.sortedCollectionNonComparable
        let source = "class P { }\nclass Q implements Comparable<Q> { public int compareTo(Q o) { return 0; } }\nclass R extends Q { }\nclass T {\n    void f() {\n        TreeSet<P> a = new TreeSet<>();\n        Map<P, String> b = new TreeMap<P, String>();\n        PriorityQueue<P> c = new PriorityQueue<>();\n        TreeSet<Q> d = new TreeSet<>();\n        TreeSet<R> e = new TreeSet<>();\n        TreeSet<P> g = new TreeSet<>((x, y) -> 0);\n        TreeSet<String> h = new TreeSet<>();\n    }\n}\n"
        XCTAssertEqual(try codes(source, rule: rule), [rule.code, rule.code, rule.code])
    }

    func testSuspiciousToArray() throws {
        let rule = JavaInspectionRule.suspiciousToArray
        let source = cls("    String[] a(List<String> l) { return (String[]) l.toArray(); }\n    Object[] b(List<String> l) { return (Object[]) l.toArray(); }\n    Integer[] c(List<String> l) { return l.toArray(new Integer[0]); }\n    String[] d(List<String> l) { return l.toArray(new String[0]); }\n    Object[] e(List<String> l) { return l.toArray(new Object[0]); }")
        XCTAssertEqual(try codes(source, rule: rule), [rule.code, rule.code])
        let generic = "class G<E> {\n    E[] f(List<E> l) { return (E[]) l.toArray(); }\n}\n"
        XCTAssertEqual(try codes(generic, rule: rule), [])
    }

    func testCollectionModifiedWhileIterated() throws {
        let rule = JavaInspectionRule.listRemoveInLoop
        let wrap = { (body: String) in "class T {\n    void f(List<String> list, List<String> other) {\n        \(body)\n    }\n}\n" }
        XCTAssertEqual(try codes(wrap("for (String s : list) { if (s.isEmpty()) list.remove(s); }"), rule: rule), [rule.code])
        XCTAssertEqual(try codes(wrap("for (int i = 0; i < list.size(); i++) { if (i > 1) list.remove(i); }"), rule: rule), [rule.code])
        XCTAssertEqual(try codes(wrap("for (String s : list) { if (s.isEmpty()) { list.remove(s); break; } }"), rule: rule), [])
        XCTAssertEqual(try codes(wrap("for (int i = 0; i < list.size(); i++) { list.remove(i); i--; }"), rule: rule), [])
        XCTAssertEqual(try codes(wrap("for (int i = 0; i < list.size(); ) { if (list.get(i).isEmpty()) { list.remove(i); } else { i++; } }"), rule: rule), [])
        XCTAssertEqual(try codes(wrap("for (String s : list) { other.remove(s); }"), rule: rule), [])
        XCTAssertEqual(try codes(wrap("for (String s : new ArrayList<>(list)) { list.remove(s); }"), rule: rule), [])
        XCTAssertEqual(try codes(wrap("for (String s : list) { list.get(0); list.size(); }"), rule: rule), [])
    }
}
