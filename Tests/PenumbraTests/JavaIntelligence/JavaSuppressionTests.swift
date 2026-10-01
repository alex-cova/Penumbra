import XCTest
import EditorIntelligence
@testable import JavaIntelligence

final class JavaSuppressionTests: XCTestCase {
    private let source = """
    class T {
        void run() {
            List raw = new ArrayList();
        }
    }
    """

    private func tree(_ text: String) throws -> JavaSyntaxTree {
        try XCTUnwrap(JavaSyntaxParser().parse(text))
    }

    private func byteOffset(of marker: String, in text: String) -> Int {
        JavaNavigationText.utf8ByteOffset(forUTF16Offset: (text as NSString).range(of: marker).location, in: text)
    }

    private func apply(_ action: CodeAction, to text: String) -> String {
        var result = text as NSString
        for edit in action.edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            let range = NSRange(location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset)
            result = result.replacingCharacters(in: range, with: edit.replacement) as NSString
        }
        return result as String
    }

    private func fixes(_ text: String, code: String = "rawtypes", at marker: String = "List raw", style: JavaSuppressionStyle = .annotation) throws -> [CodeAction] {
        JavaSuppression.fixes(code: code, atByteOffset: byteOffset(of: marker, in: text), tree: try tree(text), source: text, style: style)
    }

    func testAnnotationFixesCoverTheVariableTheMethodAndTheClass() throws {
        let actions = try fixes(source)
        XCTAssertEqual(actions.map(\.title), [
            "Suppress 'rawtypes' for variable",
            "Suppress 'rawtypes' for method 'run'",
            "Suppress 'rawtypes' for class 'T'"
        ])
        XCTAssertEqual(apply(actions[0], to: source), """
        class T {
            void run() {
                @SuppressWarnings("rawtypes") List raw = new ArrayList();
            }
        }
        """)
        XCTAssertEqual(apply(actions[1], to: source), """
        class T {
            @SuppressWarnings("rawtypes")
            void run() {
                List raw = new ArrayList();
            }
        }
        """)
        XCTAssertTrue(apply(actions[2], to: source).hasPrefix("@SuppressWarnings(\"rawtypes\")\nclass T {"))
    }

    func testAnnotationIsMergedIntoAnExistingSuppressWarnings() throws {
        let text = "class T {\n    @SuppressWarnings(\"unchecked\")\n    void run() {\n        List raw;\n    }\n}\n"
        let method = try XCTUnwrap(try fixes(text).first { $0.title.contains("method") })
        XCTAssertEqual(apply(method, to: text), "class T {\n    @SuppressWarnings({\"unchecked\", \"rawtypes\"})\n    void run() {\n        List raw;\n    }\n}\n")
    }

    func testNoFixIsOfferedWhenTheCodeIsAlreadySuppressed() throws {
        let text = "class T {\n    @SuppressWarnings(\"rawtypes\")\n    void run() {\n        List raw;\n    }\n}\n"
        XCTAssertFalse(try fixes(text).contains { $0.title.contains("method") })
    }

    func testCommentStyleAddsNoinspectionAboveTheStatement() throws {
        let actions = try fixes(source, style: .comment)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(apply(actions[0], to: source), """
        class T {
            void run() {
                //noinspection rawtypes
                List raw = new ArrayList();
            }
        }
        """)
    }

    func testCommentStyleAppendsToAnExistingNoinspection() throws {
        let text = "class T {\n    void run() {\n        //noinspection unchecked\n        List raw = new ArrayList();\n    }\n}\n"
        let action = try XCTUnwrap(try fixes(text, style: .comment).first)
        XCTAssertEqual(apply(action, to: text), "class T {\n    void run() {\n        //noinspection unchecked, rawtypes\n        List raw = new ArrayList();\n    }\n}\n")
    }

    func testAnImportFallsBackToTheCommentWhenAnnotationsAreChosen() throws {
        let text = "import java.util.List;\n\nclass T {}\n"
        let actions = try fixes(text, code: "unused-import", at: "import java", style: .annotation)
        XCTAssertEqual(actions.map(\.title), ["Suppress 'unused-import' for statement with //noinspection"])
        XCTAssertEqual(apply(actions[0], to: text), "//noinspection unused-import\nimport java.util.List;\n\nclass T {}\n")
    }

    func testIsSuppressedHonoursAnnotationsOnEveryEnclosingDeclaration() throws {
        let onMethod = "class T {\n    @SuppressWarnings({\"a\", \"rawtypes\"})\n    void run() {\n        List raw;\n    }\n}\n"
        let onClass = "@SuppressWarnings(\"all\")\nclass T {\n    void run() {\n        List raw;\n    }\n}\n"
        let other = "class T {\n    @SuppressWarnings(\"unchecked\")\n    void run() {\n        List raw;\n    }\n}\n"
        for (text, expected) in [(onMethod, true), (onClass, true), (other, false), (source, false)] {
            XCTAssertEqual(
                JavaSuppression.isSuppressed(code: "rawtypes", atByteOffset: byteOffset(of: "List raw", in: text), tree: try tree(text)),
                expected, text
            )
        }
    }

    func testIsSuppressedHonoursNoinspectionOnTheLineAbove() throws {
        let text = "class T {\n    void run() {\n        //noinspection unchecked, rawtypes\n        List raw;\n        List other;\n    }\n}\n"
        let parsed = try tree(text)
        XCTAssertTrue(JavaSuppression.isSuppressed(code: "rawtypes", atByteOffset: byteOffset(of: "List raw", in: text), tree: parsed))
        XCTAssertFalse(JavaSuppression.isSuppressed(code: "rawtypes", atByteOffset: byteOffset(of: "List other", in: text), tree: parsed))
        XCTAssertFalse(JavaSuppression.isSuppressed(code: "deprecation", atByteOffset: byteOffset(of: "List raw", in: text), tree: parsed))
    }

    func testNoinspectionAllSilencesEveryCode() throws {
        let text = "class T {\n    void run() {\n        //noinspection ALL\n        List raw;\n    }\n}\n"
        XCTAssertTrue(JavaSuppression.isSuppressed(code: "anything", atByteOffset: byteOffset(of: "List raw", in: text), tree: try tree(text)))
    }
}
