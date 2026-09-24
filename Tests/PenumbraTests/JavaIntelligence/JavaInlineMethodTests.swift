import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaInlineMethodTests: XCTestCase {
    private var fixture: JavaReferenceFixture!

    override func setUpWithError() throws {
        fixture = try JavaReferenceFixture()
    }

    func testInlinePrivateMethodAtCall() async throws {
        try fixture.add("p/T.java", """
        package p;
        class T {
            void run() {
                int x = €add(1, 2);
            }
            private int add(int a, int b) {
                return a + b;
            }
        }
        """)
        let plan = try await plan()
        XCTAssertNil(plan.blockingError)
        let result = try apply(plan)
        let text = try XCTUnwrap(result["p/T.java"])
        XCTAssertFalse(text.contains("add("))
        XCTAssertFalse(text.contains("private int add"))
        XCTAssertTrue(text.contains("int x ="))
        XCTAssertTrue(text.contains("1"))
        XCTAssertTrue(text.contains("2"))
    }

    func testInlinePrivateMethodAtDeclaration() async throws {
        try fixture.add("p/T.java", """
        package p;
        class T {
            void run() {
                int x = add(1, 2);
            }
            private int €add(int a, int b) {
                return a + b;
            }
        }
        """)
        let plan = try await plan()
        XCTAssertNil(plan.blockingError)
        let result = try apply(plan)
        let text = try XCTUnwrap(result["p/T.java"])
        XCTAssertFalse(text.contains("private int add"))
        XCTAssertTrue(text.contains("add(1, 2)") == false)
    }

    func testPublicMethodBlocks() async throws {
        try fixture.add("p/T.java", """
        package p;
        class T {
            void run() {
                int x = €add(1, 2);
            }
            public int add(int a, int b) {
                return a + b;
            }
        }
        """)
        let plan = try await plan()
        XCTAssertEqual(plan.blockingError, "Only private methods can be inlined.")
    }

    func testRecursiveMethodBlocks() async throws {
        try fixture.add("p/T.java", """
        package p;
        class T {
            void run() {
                €fact(3);
            }
            private int fact(int n) {
                if (n <= 1) return 1;
                return n * fact(n - 1);
            }
        }
        """)
        let plan = try await plan()
        XCTAssertEqual(plan.blockingError, "Recursive methods cannot be inlined.")
    }

    func testMultipleReturnsBlock() async throws {
        try fixture.add("p/T.java", """
        package p;
        class T {
            void run() {
                int x = €pick(true);
            }
            private int pick(boolean flag) {
                if (flag) return 1;
                return 2;
            }
        }
        """)
        let plan = try await plan()
        XCTAssertEqual(plan.blockingError, "Methods with multiple return statements cannot be inlined yet.")
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
        return await JavaInlineMethod.plan(
            source: source,
            context: context,
            url: fixture.url(caret.file),
            index: environment.index,
            cacheRoot: fixture.root
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
