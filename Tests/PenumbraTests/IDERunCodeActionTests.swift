import EditorIntelligence
import JavaIntelligence
import XCTest
@testable import Umbra

final class IDERunCodeActionTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/proj/src/FooTest.java")

    private let testSource = """
    package app;

    import org.junit.jupiter.api.Test;

    public class FooTest {
        @Test
        void testAdds() {}

        void helper() {}

        public static void main(String[] args) {}
    }
    """

    func testTheDeclarationLinesOfATestFileAreRunTargets() {
        typealias Provider = IDERunCodeActionProvider
        XCTAssertEqual(Provider.target(atLine: 5, in: testSource, url: url), .init(kind: .testClass, title: "FooTest", line: 5))
        XCTAssertEqual(Provider.target(atLine: 7, in: testSource, url: url), .init(kind: .testMethod, title: "testAdds()", line: 7))
        XCTAssertEqual(Provider.target(atLine: 11, in: testSource, url: url), .init(kind: .main, title: "FooTest.main()", line: 11))
        for line in [1, 3, 6, 9, 12] {
            XCTAssertNil(Provider.target(atLine: line, in: testSource, url: url), "line \(line)")
        }
        XCTAssertNil(Provider.target(atLine: 0, in: testSource, url: url))
        XCTAssertNil(Provider.target(atLine: 99, in: testSource, url: url))
    }

    func testAClassWithoutTestsIsNotATestTarget() {
        let source = "public class Plain {\n    void helper() {}\n}\n"
        XCTAssertNil(IDERunCodeActionProvider.target(atLine: 1, in: source, url: url))
    }

    func testNestedMainsNameTheirOwnClass() {
        let source = """
        public class Outer {
            static class Inner {
                public static void main(String[] args) {}
            }
        }
        """
        XCTAssertEqual(
            IDERunCodeActionProvider.target(atLine: 3, in: source, url: url),
            .init(kind: .main, title: "Inner.main()", line: 3)
        )
    }

    private func document(_ text: String, line: Int, language: String? = "java") -> Document {
        let position = TextPosition(line: line, column: 0, utf16Offset: 0)
        return Document(
            id: DocumentID(), url: url, displayName: "FooTest.java",
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: language
        )
    }

    func testTheActionsCarryCommandsAndNoEdits() async {
        let onTest = document(testSource, line: 6)  // 0-based: line 7 of the file
        let actions = await IDERunCodeActionProvider().codeActions(for: onTest, at: onTest.cursor.position, diagnostics: [])
        XCTAssertEqual(actions.map(\.title), ["Run ‘testAdds()’", "Debug ‘testAdds()’", "Modify Run Configuration…"])
        XCTAssertTrue(actions.allSatisfy { $0.edits.isEmpty })
        XCTAssertEqual(actions.map { $0.command?.id }, ["umbra.run", "umbra.debug", "umbra.modifyRun"])
        XCTAssertEqual(actions[0].command?.arguments, ["testMethod", "7"])

        let elsewhere = document(testSource, line: 8)
        let none = await IDERunCodeActionProvider().codeActions(for: elsewhere, at: elsewhere.cursor.position, diagnostics: [])
        XCTAssertTrue(none.isEmpty)
    }

    /// The Run actions are a service of their own, registered for Java after Java's: the router puts
    /// them last, and only for Java documents.
    @MainActor
    func testTheRouterOffersTheRunActionsForJavaDocumentsAfterJavasOwn() async {
        let router = IDEIntelligenceServices().languages.codeActions
        let onTest = document(testSource, line: 6)
        let actions = await router.codeActions(for: onTest, at: onTest.cursor.position, diagnostics: [])
        XCTAssertEqual(actions.suffix(3).map(\.title), ["Run ‘testAdds()’", "Debug ‘testAdds()’", "Modify Run Configuration…"])
        XCTAssertEqual(actions.filter { $0.command != nil }.count, 3)

        let notJava = document(testSource, line: 6, language: "markdown")
        let none = await router.codeActions(for: notJava, at: notJava.cursor.position, diagnostics: [])
        XCTAssertTrue(none.isEmpty)
    }
}
