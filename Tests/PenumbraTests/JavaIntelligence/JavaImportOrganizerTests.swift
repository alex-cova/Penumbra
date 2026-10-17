import XCTest
import EditorIntelligence
@testable import JavaIntelligence

final class JavaImportOrganizerTests: XCTestCase {
    func testGroupsAreOtherThenJavaxAndJavaThenStatic() {
        let source = """
        package demo;

        import static org.junit.Assert.assertEquals;
        import java.util.Set;
        import org.acme.Widget;
        import javax.swing.JFrame;
        import java.io.File;
        import com.zed.Zed;
        import static java.lang.Math.max;

        class T { Set<File> s; Widget w; JFrame f; Zed z; int m() { assertEquals(1, 1); return max(1, 2); } }
        """
        XCTAssertEqual(organized(source), """
        package demo;

        import com.zed.Zed;
        import org.acme.Widget;

        import javax.swing.JFrame;
        import java.io.File;
        import java.util.Set;

        import static java.lang.Math.max;
        import static org.junit.Assert.assertEquals;

        class T { Set<File> s; Widget w; JFrame f; Zed z; int m() { assertEquals(1, 1); return max(1, 2); } }
        """)
    }

    func testRemovesUnusedAndDuplicatesWhileSorting() {
        let source = "import java.util.Set;\nimport java.util.List;\nimport java.util.Set;\nimport java.util.Map;\n\nclass T { List<String> l; Set<String> s; }\n"
        XCTAssertEqual(organized(source), "import java.util.List;\nimport java.util.Set;\n\nclass T { List<String> l; Set<String> s; }\n")
    }

    func testAlreadyOrganizedFileHasNoEdits() {
        let source = "import org.acme.Widget;\n\nimport java.util.List;\n\nclass T { List<Widget> l; }\n"
        XCTAssertTrue(JavaImportOrganizer.edits(in: source).isEmpty)
    }

    func testOnDemandImportsAreKeptAndSortedWithTheirName() {
        let source = "import java.util.*;\nimport java.io.*;\n\nclass T { }\n"
        XCTAssertEqual(organized(source), "import java.io.*;\nimport java.util.*;\n\nclass T { }\n")
    }

    func testRemovingEveryImportAlsoRemovesTheBlankLinesAfterThem() {
        let source = "package demo;\n\nimport java.util.List;\nimport java.util.Map;\n\n\nclass T { }\n"
        XCTAssertEqual(organized(source), "package demo;\n\nclass T { }\n")
    }

    func testFileWithNoImportsHasNoEdits() {
        XCTAssertTrue(JavaImportOrganizer.edits(in: "class T { }\n").isEmpty)
    }

    func testACommentInsideTheBlockOnlyRemovesUnusedImportsAndKeepsTheOrder() {
        let source = "import java.util.Set;\n// keep this\nimport java.util.List;\nimport java.io.File;\n\nclass T { Set<String> s; List<String> l; }\n"
        XCTAssertEqual(organized(source), "import java.util.Set;\n// keep this\nimport java.util.List;\n\nclass T { Set<String> s; List<String> l; }\n")
    }

    func testATrailingCommentOnTheLastImportOnlyRemovesUnusedImports() {
        let source = "import java.util.Set;\nimport java.io.File; // for tests\n\nclass T { Set<String> s; File f; }\n"
        XCTAssertTrue(JavaImportOrganizer.edits(in: source).isEmpty)
    }

    func testSyntaxErrorLeavesTheFileAlone() {
        XCTAssertTrue(JavaImportOrganizer.edits(in: "import java.util.Set;\nimport java.io.File;\nclass T { void m( { }\n").isEmpty)
    }

    func testCRLFFileKeepsWorking() {
        let source = "import java.util.Set;\r\nimport java.io.File;\r\n\r\nclass T { Set<String> s; File f; }\r\n"
        XCTAssertEqual(organized(source), "import java.io.File;\r\nimport java.util.Set;\r\n\r\nclass T { Set<String> s; File f; }\r\n")
    }

    func testFourClassesFromOnePackageStaySingle() {
        let source = "import com.acme.A;\nimport com.acme.B;\nimport com.acme.C;\nimport com.acme.D;\n\nclass T { A a; B b; C c; D d; }\n"
        XCTAssertTrue(JavaImportOrganizer.edits(in: source).isEmpty)
    }

    func testTheFifthClassFromOnePackageBecomesAStar() {
        let source = """
        import com.acme.A;
        import com.acme.B;
        import com.acme.C;
        import com.acme.D;
        import com.acme.E;

        class T { A a; B b; C c; D d; E e; }
        """
        XCTAssertEqual(organized(source), """
        import com.acme.*;

        class T { A a; B b; C c; D d; E e; }
        """)
    }

    func testACountOf999NeverCollapses() {
        let source = "import com.acme.A;\nimport com.acme.B;\nimport com.acme.C;\nimport com.acme.D;\nimport com.acme.E;\n\nclass T { A a; B b; C c; D d; E e; }\n"
        let policy = JavaImportPolicy(classCountToUseStarImport: 999)
        XCTAssertTrue(JavaImportOrganizer.edits(in: source, policy: policy).isEmpty)
    }

    func testSingleClassImportsOffCollapsesAtTwo() {
        let source = "import com.acme.A;\nimport com.acme.B;\n\nclass T { A a; B b; }\n"
        let policy = JavaImportPolicy(useSingleClassImports: false)
        XCTAssertEqual(organized(source, policy: policy), "import com.acme.*;\n\nclass T { A a; B b; }\n")
    }

    func testThreeStaticImportsFromOneClassBecomeAStar() {
        let source = """
        import static com.acme.Util.a;
        import static com.acme.Util.b;
        import static com.acme.Util.c;

        class T { int m() { return a(b(c(1))); } }
        """
        XCTAssertEqual(organized(source), """
        import static com.acme.Util.*;

        class T { int m() { return a(b(c(1))); } }
        """)
    }

    func testTwoStaticImportsStaySingle() {
        let source = "import static com.acme.Util.a;\nimport static com.acme.Util.b;\n\nclass T { int m() { return a(b(1)); } }\n"
        XCTAssertTrue(JavaImportOrganizer.edits(in: source).isEmpty)
    }

    func testACommentBlocksCollapsingToAStar() {
        let source = "import com.acme.A;\nimport com.acme.B; // keep\nimport com.acme.C;\nimport com.acme.D;\nimport com.acme.E;\n\nclass T { A a; B b; C c; D d; E e; }\n"
        XCTAssertTrue(JavaImportOrganizer.edits(in: source).isEmpty)
    }

    func testAddingAJavaImportOpensTheJavaGroupUnderOther() {
        let source = "import com.foo.Bar;\n\nclass T { Bar b; }\n"
        XCTAssertEqual(
            adding([("java.util.List", false)], to: source),
            "import com.foo.Bar;\n\nimport java.util.List;\n\nclass T { Bar b; }\n"
        )
    }

    func testAddingAStaticImportLandsAfterTheJavaGroup() {
        let source = "import com.foo.Bar;\n\nimport java.util.List;\n\nclass T { Bar b; List l; }\n"
        XCTAssertEqual(
            adding([("java.lang.Math.max", true)], to: source),
            "import com.foo.Bar;\n\nimport java.util.List;\n\nimport static java.lang.Math.max;\n\nclass T { Bar b; List l; }\n"
        )
    }

    func testACommentKeepsTheExistingImportWhereItIs() {
        let source = "import org.acme.Widget; // keep\n\nclass T { Widget w; }\n"
        XCTAssertEqual(
            adding([("com.foo.Bar", false)], to: source),
            "import com.foo.Bar;\nimport org.acme.Widget; // keep\n\nclass T { Widget w; }\n"
        )
    }

    private func organized(_ source: String, policy: JavaImportPolicy = .intellij) -> String {
        apply(JavaImportOrganizer.edits(in: source, policy: policy), to: source)
    }

    private func adding(_ additions: [(qualifiedName: String, isStatic: Bool)], to source: String) -> String {
        let tree = JavaSyntaxParser().parse(source)!
        let edits = JavaImportOrganizer.editsAdding(
            additions, list: JavaImportList(tree: tree), bytes: tree.sourceBytes, policy: .intellij
        )
        return apply(edits, to: source)
    }

    private func apply(_ edits: [TextEdit], to source: String) -> String {
        var result = source as NSString
        for edit in edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            let range = NSRange(
                location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset
            )
            result = result.replacingCharacters(in: range, with: edit.replacement) as NSString
        }
        return result as String
    }
}
