import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaExtractMethodTests: XCTestCase {
    private var fixture: JavaReferenceFixture!

    override func setUpWithError() throws {
        fixture = try JavaReferenceFixture()
    }

    func testExtractExpressionWithCapturedParameters() async throws {
        try add("p/T.java", """
        package p;
        class T {
            void run() {
                int a = 1, b = 2;
                int x = €a + b;
            }
        }
        """, selecting: "a + b")
        let plan = try await plan(name: "sum")
        XCTAssertNil(plan.blockingError)
        let result = try apply(plan)
        let text = try XCTUnwrap(result["p/T.java"])
        XCTAssertTrue(text.contains("private int sum(int a, int b) {"))
        XCTAssertTrue(text.contains("return a + b;"))
        XCTAssertTrue(text.contains("int x = sum(a, b);"))
    }

    func testExtractVoidStatements() async throws {
        let secondLineIndent = String(repeating: " ", count: 8)
        try add("p/T.java", """
        package p;
        class T {
            void run() {
                int a = 1;
                €System.out.println(a);
                a = a + 1;
            }
        }
        """, selecting: "System.out.println(a);\n\(secondLineIndent)a = a + 1;")
        let plan = try await plan(name: "update")
        XCTAssertNil(plan.blockingError)
        let result = try apply(plan)
        let text = try XCTUnwrap(result["p/T.java"])
        XCTAssertTrue(text.contains("private void update(int a) {"))
        XCTAssertTrue(text.contains("System.out.println(a);"))
        XCTAssertTrue(text.contains("a = a + 1;"))
        XCTAssertTrue(text.contains("update(a);"))
    }

    func testExtractReturnStatement() async throws {
        try add("p/T.java", """
        package p;
        class T {
            int run(int a, int b) {
                €return a + b;
            }
        }
        """, selecting: "return a + b;")
        let plan = try await plan(name: "sum")
        XCTAssertNil(plan.blockingError)
        let result = try apply(plan)
        let text = try XCTUnwrap(result["p/T.java"])
        XCTAssertTrue(text.contains("private int sum(int a, int b) {"))
        XCTAssertTrue(text.contains("return a + b;"))
        XCTAssertTrue(text.contains("return sum(a, b);"))
    }

    func testStaticContextProducesStaticMethod() async throws {
        try add("p/T.java", """
        package p;
        class T {
            static void run() {
                int x = €1 + 2;
            }
        }
        """, selecting: "1 + 2")
        let plan = try await plan(name: "sum")
        XCTAssertNil(plan.blockingError)
        let result = try apply(plan)
        let text = try XCTUnwrap(result["p/T.java"])
        XCTAssertTrue(text.contains("private static int sum() {"))
        XCTAssertTrue(text.contains("int x = sum();"))
    }

    func testMethodNameConflictBlocks() async throws {
        try add("p/T.java", """
        package p;
        class T {
            void sum() {}
            void run() {
                int x = €1 + 2;
            }
        }
        """, selecting: "1 + 2")
        let plan = try await plan(name: "sum")
        XCTAssertEqual(plan.blockingError, "A method named sum already exists in this type.")
    }

    func testPartialSelectionBlocks() async throws {
        try add("p/T.java", """
        package p;
        class T {
            void run() {
                int x = fo€o.bar();
            }
        }
        """, selecting: "o.bar")
        let plan = try await plan(name: "bar")
        XCTAssertEqual(
            plan.blockingError,
            "Select a complete expression or one or more statements to extract."
        )
    }

    // MARK: - Helpers

    private var selections: [String: (start: Int, end: Int)] = [:]

    private func add(_ name: String, _ marked: String, selecting expression: String) throws {
        if let marker = marked.range(of: "€") {
            let start = marked.utf16.distance(from: marked.utf16.startIndex, to: marker.lowerBound.samePosition(in: marked.utf16)!)
            selections[name] = (start, start + (expression as NSString).length)
        }
        try fixture.add(name, marked)
    }

    private func plan(name: String) async throws -> WorkspaceEditPlan {
        let environment = try await fixture.build()
        let caret = try XCTUnwrap(fixture.caretLocation)
        let source = try XCTUnwrap(fixture.sources[caret.file])
        let range = try XCTUnwrap(selections[caret.file])
        let start = JavaNavigationText.position(utf16Offset: range.start, in: source)
        let end = JavaNavigationText.position(utf16Offset: range.end, in: source)
        let selection = Selection(range: EditorIntelligence.TextRange(start: start, end: end))
        return await JavaExtractMethod.plan(
            source: source,
            selection: selection,
            url: fixture.url(caret.file),
            name: name,
            index: environment.index
        )
    }

    private func apply(_ plan: WorkspaceEditPlan) throws -> [String: String] {
        let edit = plan.workspaceEdit()
        var result: [String: String] = [:]
        for url in edit.changes.keys {
            var text = try String(contentsOf: url, encoding: .utf8) as NSString
            for change in edit.orderedEdits(for: url) {
                let length = change.range.end.utf16Offset - change.range.start.utf16Offset
                text = text.replacingCharacters(
                    in: NSRange(location: change.range.start.utf16Offset, length: length), with: change.replacement
                ) as NSString
            }
            let prefix = fixture.root.standardizedFileURL.path + "/"
            result[url.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "")] = text as String
        }
        return result
    }
}
