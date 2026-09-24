import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaSafeDeleteTests: XCTestCase {
    private var fixture: JavaReferenceFixture!
    private var markerOffsets: [String: Int] = [:]

    override func setUpWithError() throws {
        fixture = try JavaReferenceFixture()
    }

    func testSafeDeleteTopLevelClassWithNoUsages() async throws {
        try add("p/Foo.java", "package p; public class €Foo {}")
        let plan = try await planDelete(caretIn: "p/Foo.java")
        XCTAssertNil(plan.blockingError)
        XCTAssertEqual(plan.fileDeletions.count, 1)
        XCTAssertEqual(plan.fileDeletions.first?.lastPathComponent, "Foo.java")
        XCTAssertTrue(plan.entries.isEmpty)
    }

    func testSafeDeleteBlocksWhenClassIsUsed() async throws {
        try add("p/Foo.java", "package p; public class €Foo {}")
        try add("q/User.java", """
        package q;
        import p.Foo;
        class User { Foo x; }
        """)
        let plan = try await planDelete(caretIn: "p/Foo.java")
        XCTAssertNotNil(plan.blockingError)
        XCTAssertTrue(plan.blockingError?.contains("usage") == true)
    }

    func testSafeDeleteUnusedMethod() async throws {
        try add("p/T.java", """
        package p;
        class T {
            void €unused() {}
            void run() { unused(); }
        }
        """)
        let plan = try await planDelete(caretIn: "p/T.java")
        XCTAssertNotNil(plan.blockingError)
    }

    func testSafeDeleteMethodWithOnlyDeclaration() async throws {
        try add("p/T.java", """
        package p;
        class T {
            void €unused() {}
            void run() {}
        }
        """)
        let plan = try await planDelete(caretIn: "p/T.java")
        XCTAssertNil(plan.blockingError)
        XCTAssertTrue(plan.fileDeletions.isEmpty)
        XCTAssertEqual(plan.entries.count, 1)
        let result = try apply(plan)
        let text = try XCTUnwrap(result["p/T.java"])
        XCTAssertFalse(text.contains("unused()"))
        XCTAssertTrue(text.contains("void run()"))
    }

    func testSafeDeleteBlocksLibraryMember() async throws {
        let jar = fixture.root.appendingPathComponent("lib.jar")
        let stub = JavaClassStub(
            binaryName: "lib.Lib", qualifiedName: "lib.Lib", simpleName: "Lib", packageName: "lib",
            kind: .classKind, modifiers: [.publicFlag], origin: .jar(jar)
        )
        let shard = fixture.root.appendingPathComponent("jar.idx")
        try JavaIndexShardWriter().write([stub], stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: shard))])
        try add("p/T.java", "package p; import lib.Lib; class T { €Lib x; }")
        let plan = try await planDelete(caretIn: "p/T.java", index: index)
        XCTAssertNotNil(plan.blockingError)
    }

    // MARK: - Helpers

    private func add(_ name: String, _ marked: String) throws {
        if let marker = marked.range(of: "€") {
            markerOffsets[name] = marked.utf16.distance(from: marked.utf16.startIndex, to: marker.lowerBound.samePosition(in: marked.utf16)!)
        }
        try fixture.add(name, marked)
    }

    private func planDelete(caretIn file: String, index: JavaIndex? = nil) async throws -> WorkspaceEditPlan {
        let environment = try await fixture.build()
        let candidates = JavaTextScanCandidateSource()
        let usedIndex = index ?? environment.index
        let provider = JavaRefactoringProvider(
            index: usedIndex, indexPaths: JavaIndexPaths(root: fixture.root.appendingPathComponent("cache")),
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
        return try await provider.plan(.safeDelete, context: context, parameters: [:])
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
