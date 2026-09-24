import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaExtractVariableTests: XCTestCase {
    private var fixture: JavaReferenceFixture!

    override func setUpWithError() throws {
        fixture = try JavaReferenceFixture()
    }

    func testExtractSimpleMethodCall() async throws {
        try add("p/T.java", """
        package p;
        class T {
            void run() {
                int x = €(1 + 2);
            }
        }
        """, selecting: "(1 + 2)")
        let plan = try await plan(name: "sum")
        XCTAssertNil(plan.blockingError)
        XCTAssertEqual(plan.entries.count, 2)
        let result = try apply(plan)
        let text = try XCTUnwrap(result["p/T.java"])
        XCTAssertTrue(text.contains("final int sum = (1 + 2);"))
        XCTAssertTrue(text.contains("int x = sum;"))
    }

    func testExtractArithmetic() async throws {
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
        XCTAssertTrue(text.contains("final int sum = a + b;"))
        XCTAssertTrue(text.contains("int x = sum;"))
    }

    func testNameConflictBlocks() async throws {
        try add("p/T.java", """
        package p;
        class T {
            void run() {
                int a = 1, b = 2;
                int x = €a + b;
            }
        }
        """, selecting: "a + b")
        let plan = try await plan(name: "a")
        XCTAssertEqual(plan.blockingError, "A local named a already exists here.")
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
        XCTAssertEqual(plan.blockingError, "Select a complete expression to extract.")
    }

    func testMultiStatementSelectionBlocks() async throws {
        try add("p/T.java", """
        package p;
        class T {
            void run() {
                €int x = 1;
                int y = 2;
            }
        }
        """, selecting: "int x = 1;\n                int y = 2")
        let plan = try await plan(name: "value")
        XCTAssertEqual(plan.blockingError, "Select a complete expression to extract.")
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
        return await JavaExtractVariable.plan(
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
