import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaInlineVariableTests: XCTestCase {
    private var fixture: JavaReferenceFixture!

    override func setUpWithError() throws {
        fixture = try JavaReferenceFixture()
    }

    func testInlineSimpleLocal() async throws {
        try fixture.add("p/T.java", """
        package p;
        class T {
            void run() {
                int sum = 1 + 2;
                int x = €sum;
            }
        }
        """)
        let plan = try await plan()
        XCTAssertNil(plan.blockingError)
        let result = try apply(plan)
        let text = try XCTUnwrap(result["p/T.java"])
        XCTAssertFalse(text.contains("int sum"))
        XCTAssertTrue(text.contains("int x = (1 + 2);"))
    }

    func testInlineFromDeclaration() async throws {
        try fixture.add("p/T.java", """
        package p;
        class T {
            void run() {
                int €sum = 1 + 2;
                int x = sum;
            }
        }
        """)
        let plan = try await plan()
        XCTAssertNil(plan.blockingError)
        let result = try apply(plan)
        let text = try XCTUnwrap(result["p/T.java"])
        XCTAssertFalse(text.contains("int sum"))
        XCTAssertTrue(text.contains("int x = (1 + 2);"))
    }

    func testMissingInitializerBlocks() async throws {
        try fixture.add("p/T.java", """
        package p;
        class T {
            void run() {
                int €sum;
                sum = 1;
            }
        }
        """)
        let plan = try await plan()
        XCTAssertEqual(plan.blockingError, "The variable has no initializer to inline.")
    }

    func testWriteUsageBlocks() async throws {
        try fixture.add("p/T.java", """
        package p;
        class T {
            void run() {
                int sum = 1;
                €sum = 2;
            }
        }
        """)
        let plan = try await plan()
        XCTAssertEqual(plan.blockingError, "The variable is assigned after it is declared.")
    }

    func testParameterBlocks() async throws {
        try fixture.add("p/T.java", """
        package p;
        class T {
            void run(int €limit) {
                use(limit);
            }
            void use(int v) {}
        }
        """)
        let plan = try await plan()
        XCTAssertEqual(plan.blockingError, "Only local variables can be inlined.")
    }

    // MARK: - Helpers

    private func plan() async throws -> WorkspaceEditPlan {
        let environment = try await fixture.build()
        let caret = try XCTUnwrap(fixture.caretLocation)
        let source = try XCTUnwrap(fixture.sources[caret.file])
        let offset = caret.utf16Offset
        let position = TextPosition(line: 0, column: offset, utf16Offset: offset)
        let document = Document(
            id: DocumentID(),
            url: fixture.url(caret.file),
            displayName: caret.file,
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
        let context = RefactoringContext(
            document: document,
            cursor: Cursor(position: position),
            selection: Selection(range: TextRange(start: position, end: position))
        )
        return await JavaInlineVariable.plan(
            source: source, context: context, url: fixture.url(caret.file), index: environment.index
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
