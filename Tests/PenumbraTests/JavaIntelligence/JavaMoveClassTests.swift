import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaMoveClassTests: XCTestCase {
    private var fixture: JavaReferenceFixture!
    private var markerOffsets: [String: Int] = [:]

    override func setUpWithError() throws {
        fixture = try JavaReferenceFixture()
    }

    func testMoveClassUpdatesPackageImportsAndFilePath() async throws {
        try add("p/Foo.java", """
        package p;

        /** A {@link Foo} thing; see {@link p.Foo#run()}. */
        public class €Foo {
            public Foo() {}
            public void run() {}
            static Foo make() { return new Foo(); }
        }
        """)
        try add("q/User.java", """
        package q;

        import p.Foo;

        class User {
            Foo field = new Foo();
            java.util.function.Supplier<Foo> s = Foo::new;
            /** @see Foo */
            void m(Foo o) {}
        }
        """)
        let plan = try await planMove(caretIn: "p/Foo.java", targetPackage: "r")
        XCTAssertNil(plan.blockingError)
        XCTAssertEqual(plan.fileRenames.count, 1)
        XCTAssertEqual(plan.fileRenames.first?.from.lastPathComponent, "Foo.java")
        XCTAssertTrue(plan.fileRenames.first?.to.path.hasSuffix("/r/Foo.java") == true)

        let result = try apply(plan)
        let moved = try XCTUnwrap(result["p/Foo.java"] ?? result["r/Foo.java"])
        XCTAssertTrue(moved.contains("package r;"))
        XCTAssertTrue(moved.contains("public class Foo {"))
        XCTAssertTrue(moved.contains("{@link Foo} thing; see {@link r.Foo#run()}"))
        let user = try XCTUnwrap(result["q/User.java"])
        XCTAssertTrue(user.contains("import r.Foo;"))
        XCTAssertTrue(user.contains("Foo field = new Foo();"))
        XCTAssertFalse(user.contains("import p.Foo"))
    }

    func testMoveToSamePackageIsBlocked() async throws {
        try add("p/Foo.java", "package p; public class €Foo {}")
        let plan = try await planMove(caretIn: "p/Foo.java", targetPackage: "p")
        XCTAssertNotNil(plan.blockingError)
    }

    func testMoveBlocksWhenTargetFileExists() async throws {
        try add("p/Foo.java", "package p; public class €Foo {}")
        try add("q/Foo.java", "package q; class Other {}")
        let plan = try await planMove(caretIn: "p/Foo.java", targetPackage: "q")
        XCTAssertNotNil(plan.blockingError)
    }

    func testNestedTypeCannotBeMoved() async throws {
        try add("p/Outer.java", "package p; public class Outer { class €Inner {} }")
        let plan = try await planMove(caretIn: "p/Outer.java", targetPackage: "q")
        XCTAssertNotNil(plan.blockingError)
    }

    func testMoveBlocksWhenTypeUsedElsewhereInOldPackage() async throws {
        try add("p/Foo.java", "package p; public class €Foo {}")
        try add("p/Use.java", "package p; class Use { Foo x; }")
        let plan = try await planMove(caretIn: "p/Foo.java", targetPackage: "q")
        XCTAssertNil(plan.blockingError)
        XCTAssertTrue(plan.warnings.contains { $0.contains("Unqualified references") })
    }

    // MARK: - Helpers

    private func add(_ name: String, _ marked: String) throws {
        if let marker = marked.range(of: "€") {
            markerOffsets[name] = marked.utf16.distance(from: marked.utf16.startIndex, to: marker.lowerBound.samePosition(in: marked.utf16)!)
        }
        try fixture.add(name, marked)
    }

    private func planMove(caretIn file: String, targetPackage: String) async throws -> WorkspaceEditPlan {
        let environment = try await fixture.build()
        let candidates = JavaTextScanCandidateSource()
        let provider = JavaRefactoringProvider(
            index: environment.index, indexPaths: JavaIndexPaths(root: fixture.root.appendingPathComponent("cache")),
            candidates: candidates
        )
        await provider.setRoots([fixture.root])
        let source = try XCTUnwrap(fixture.sources[file])
        let offset = try XCTUnwrap(markerOffsets[file])
        let position = JavaNavigationText.position(utf16Offset: offset, in: source)
        let document = Document(
            url: fixture.url(file), displayName: file,
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
        let context = RefactoringContext(document: document, cursor: document.cursor, selection: document.selection)
        return try await provider.plan(.moveClass, context: context, parameters: ["targetPackage": targetPackage])
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
