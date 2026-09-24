import XCTest
import EditorIntelligence
@testable import JavaIntelligence

final class JavaUnusedImportsTests: XCTestCase {
    private func organized(_ source: String) -> String {
        var result = source as NSString
        for edit in JavaUnusedImports.edits(in: source) {
            let range = NSRange(
                location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset
            )
            result = result.replacingCharacters(in: range, with: edit.replacement) as NSString
        }
        return result as String
    }

    func testRemovesOnlyTheUnusedSingleTypeImports() {
        let source = """
        package demo;

        import java.util.List;
        import java.util.Map;
        import java.util.Set;

        class T {
            List<String> names;
            Set<String> tags;
        }
        """
        XCTAssertEqual(organized(source), """
        package demo;

        import java.util.List;
        import java.util.Set;

        class T {
            List<String> names;
            Set<String> tags;
        }
        """)
    }

    func testAnnotationsGenericsAndQualifiedUsesCountAsUsed() {
        let source = """
        import java.util.Map;
        import java.util.ArrayList;
        import java.lang.annotation.Retention;
        import org.example.Marker;

        @Retention(RetentionPolicy.RUNTIME)
        @Marker
        class T {
            Map.Entry<String, ArrayList<String>> entry;
        }
        """
        XCTAssertEqual(organized(source), """
        import java.util.Map;
        import java.util.ArrayList;
        import java.lang.annotation.Retention;
        import org.example.Marker;

        @Retention(RetentionPolicy.RUNTIME)
        @Marker
        class T {
            Map.Entry<String, ArrayList<String>> entry;
        }
        """)
    }

    func testStaticImportsAreKeptOnlyWhenTheMemberIsUsed() {
        let source = """
        import static java.lang.Math.max;
        import static java.lang.Math.min;
        import static java.util.Collections.*;

        class T { int m() { return max(1, 2); } }
        """
        XCTAssertEqual(organized(source), """
        import static java.lang.Math.max;
        import static java.util.Collections.*;

        class T { int m() { return max(1, 2); } }
        """)
    }

    func testJavadocReferencesKeepTheirImports() {
        let source = """
        import java.util.List;
        import java.util.Map;
        import java.io.IOException;
        import java.net.URL;

        class T {
            /**
             * Uses {@link List#size()} and {@linkplain Map}.
             * @throws IOException when it fails
             */
            void m() {}
        }
        """
        XCTAssertEqual(organized(source), """
        import java.util.List;
        import java.util.Map;
        import java.io.IOException;

        class T {
            /**
             * Uses {@link List#size()} and {@linkplain Map}.
             * @throws IOException when it fails
             */
            void m() {}
        }
        """)
    }

    func testRemovesJavaLangSamePackageAndDuplicateImports() {
        let source = """
        package demo;

        import java.lang.String;
        import demo.Helper;
        import java.util.List;
        import java.util.List;

        class T { String s; Helper h; List<String> l; }
        """
        XCTAssertEqual(organized(source), """
        package demo;

        import java.util.List;

        class T { String s; Helper h; List<String> l; }
        """)
    }

    func testOnDemandImportsAreAlwaysKept() {
        let source = "import java.util.*;\n\nclass T { }\n"
        XCTAssertTrue(JavaUnusedImports.edits(in: source).isEmpty)
    }

    func testLastImportAtEndOfFileIsRemoved() {
        XCTAssertEqual(organized("import java.util.List;"), "")
        XCTAssertEqual(organized("import java.util.List;\n"), "")
    }

    func testWindowsLineEndingsAreConsumed() {
        let source = "import java.util.List;\r\nimport java.util.Set;\r\n\r\nclass T { Set<String> s; }\r\n"
        XCTAssertEqual(organized(source), "import java.util.Set;\r\n\r\nclass T { Set<String> s; }\r\n")
    }

    func testAFileWithASyntaxErrorIsLeftAlone() {
        let source = "import java.util.List;\n\nclass T { void m( { }\n"
        XCTAssertTrue(JavaUnusedImports.edits(in: source).isEmpty)
    }

    func testNonAsciiTextBeforeTheImportsKeepsRangesAligned() {
        let source = "// café ☕\nimport java.util.List;\nimport java.util.Set;\n\nclass T { Set<String> s; }\n"
        XCTAssertEqual(organized(source), "// café ☕\nimport java.util.Set;\n\nclass T { Set<String> s; }\n")
    }
}
