import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaExtractFieldConstantTests: XCTestCase {
    private var fixture: JavaReferenceFixture!
    private var selections: [String: (start: Int, end: Int)] = [:]

    override func setUpWithError() throws {
        fixture = try JavaReferenceFixture()
    }

    func testExtractFieldInInstanceMethod() async throws {
        try add("p/T.java", """
        package p;
        class T {
            void run() {
                int x = €(1 + 2);
            }
        }
        """, selecting: "(1 + 2)")
        let plan = try await plan(.extractField, name: "sum")
        XCTAssertNil(plan.blockingError)
        let result = try apply(plan)
        let text = try XCTUnwrap(result["p/T.java"])
        XCTAssertTrue(text.contains("private int sum = (1 + 2);"))
        XCTAssertTrue(text.contains("int x = sum;"))
    }

    func testExtractFieldBlocksInStaticMethod() async throws {
        try add("p/T.java", """
        package p;
        class T {
            static void run() {
                int x = €(1 + 2);
            }
        }
        """, selecting: "(1 + 2)")
        let plan = try await plan(.extractField, name: "sum")
        XCTAssertTrue(plan.blockingError?.contains("static context") == true)
    }

    func testExtractConstantInStaticMethod() async throws {
        try add("p/T.java", """
        package p;
        class T {
            static void run() {
                int x = €(1 + 2);
            }
        }
        """, selecting: "(1 + 2)")
        let plan = try await plan(.extractConstant, name: "SUM")
        XCTAssertNil(plan.blockingError)
        let result = try apply(plan)
        let text = try XCTUnwrap(result["p/T.java"])
        XCTAssertTrue(text.contains("private static final int SUM = (1 + 2);"))
        XCTAssertTrue(text.contains("int x = SUM;"))
    }

    func testExtractConstantInInterface() async throws {
        try add("p/I.java", """
        package p;
        interface I {
            default void run() {
                int x = €(1 + 2);
            }
        }
        """, selecting: "(1 + 2)")
        let plan = try await plan(.extractConstant, name: "SUM")
        XCTAssertNil(plan.blockingError)
        let result = try apply(plan)
        let text = try XCTUnwrap(result["p/I.java"])
        XCTAssertTrue(text.contains("int SUM = (1 + 2);"))
        XCTAssertFalse(text.contains("private static final"))
        XCTAssertTrue(text.contains("int x = SUM;"))
    }

    func testFieldNameConflictBlocks() async throws {
        try add("p/T.java", """
        package p;
        class T {
            private int sum;
            void run() {
                int x = €(1 + 2);
            }
        }
        """, selecting: "(1 + 2)")
        let plan = try await plan(.extractField, name: "sum")
        XCTAssertEqual(plan.blockingError, "A field named sum already exists in this type.")
    }

    // MARK: - Helpers

    private func add(_ name: String, _ marked: String, selecting expression: String) throws {
        if let marker = marked.range(of: "€") {
            let start = marked.utf16.distance(from: marked.utf16.startIndex, to: marker.lowerBound.samePosition(in: marked.utf16)!)
            selections[name] = (start, start + (expression as NSString).length)
        }
        try fixture.add(name, marked)
    }

    private enum Operation {
        case extractField, extractConstant

        func plan(source: String, selection: Selection, url: URL, name: String, index: JavaIndex) async -> WorkspaceEditPlan {
            switch self {
            case .extractField:
                await JavaExtractField.plan(source: source, selection: selection, url: url, name: name, index: index)
            case .extractConstant:
                await JavaExtractConstant.plan(source: source, selection: selection, url: url, name: name, index: index)
            }
        }
    }

    private func plan(_ operation: Operation, name: String) async throws -> WorkspaceEditPlan {
        let environment = try await fixture.build()
        let caret = try XCTUnwrap(fixture.caretLocation)
        let source = try XCTUnwrap(fixture.sources[caret.file])
        let range = try XCTUnwrap(selections[caret.file])
        let start = JavaNavigationText.position(utf16Offset: range.start, in: source)
        let end = JavaNavigationText.position(utf16Offset: range.end, in: source)
        let selection = Selection(range: EditorIntelligence.TextRange(start: start, end: end))
        return await operation.plan(
            source: source, selection: selection, url: fixture.url(caret.file), name: name, index: environment.index
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
