import XCTest
import EditorIntelligence
@testable import JavaIntelligence

final class JavaImportOrganizerTests: XCTestCase {
    private func organized(_ source: String) -> String {
        var result = source as NSString
        for edit in JavaImportOrganizer.edits(in: source).sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            let range = NSRange(
                location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset
            )
            result = result.replacingCharacters(in: range, with: edit.replacement) as NSString
        }
        return result as String
    }

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
}
