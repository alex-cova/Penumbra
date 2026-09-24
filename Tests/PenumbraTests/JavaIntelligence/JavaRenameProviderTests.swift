import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaRenameProviderTests: XCTestCase {
    private var fixture: JavaReferenceFixture!
    private var markerOffsets: [String: Int] = [:]

    override func setUpWithError() throws {
        fixture = try JavaReferenceFixture()
    }

    // MARK: - Classes

    func testClassRenameEditsEverythingAndRenamesFile() async throws {
        try add("p/Old.java", """
        package p;

        /** A {@link Old} thing; see {@link p.Old#run()}. */
        public class Old {
            public Old() {}
            public Old(int x) { this(); }
            public void run() {}
            static Old make() { return new Old(); }
        }
        """)
        try add("q/User.java", """
        package q;

        import p.Old;

        class User {
            €Old field = new Old();
            java.util.function.Supplier<Old> s = Old::new;
            /** @see Old */
            void m(Old o) {}
        }
        """)
        let (provider, context) = try await makeProvider(caretIn: "q/User.java")
        let prepared = await provider.prepareRename(context)
        XCTAssertEqual(prepared?.currentName, "Old")
        XCTAssertEqual(prepared?.kindDescription, "class")

        let plan = try await provider.rename(context, to: "Fresh")
        XCTAssertNil(plan.blockingError)
        XCTAssertEqual(plan.fileRenames.count, 1)
        XCTAssertEqual(plan.fileRenames.first?.to.lastPathComponent, "Fresh.java")
        XCTAssertEqual(plan.fileRenames.first?.from.lastPathComponent, "Old.java")

        let result = try apply(plan)
        let old = try XCTUnwrap(result["p/Old.java"])
        XCTAssertTrue(old.contains("public class Fresh {"))
        XCTAssertTrue(old.contains("public Fresh() {}"))
        XCTAssertTrue(old.contains("public Fresh(int x)"))
        XCTAssertTrue(old.contains("static Fresh make() { return new Fresh(); }"))
        XCTAssertTrue(old.contains("{@link Fresh} thing; see {@link p.Fresh#run()}"))
        let user = try XCTUnwrap(result["q/User.java"])
        XCTAssertTrue(user.contains("import p.Fresh;"))
        XCTAssertTrue(user.contains("Fresh field = new Fresh();"))
        XCTAssertTrue(user.contains("Supplier<Fresh> s = Fresh::new;"))
        XCTAssertTrue(user.contains("/** @see Fresh */"))
        XCTAssertTrue(user.contains("void m(Fresh o) {}"))
        XCTAssertFalse(user.contains("Old"))
    }

    func testNestedTypeRenameKeepsFileName() async throws {
        try add("p/Outer.java", """
        package p;
        public class Outer {
            public static class €Inner {}
            Inner make() { return new Inner(); }
        }
        """)
        try add("p/Use.java", """
        package p;
        import p.Outer.Inner;
        class Use { Outer.Inner i; }
        """)
        let (provider, context) = try await makeProvider(caretIn: "p/Outer.java")
        let plan = try await provider.rename(context, to: "Core")
        XCTAssertNil(plan.blockingError)
        XCTAssertTrue(plan.fileRenames.isEmpty)
        let result = try apply(plan)
        XCTAssertTrue(try XCTUnwrap(result["p/Outer.java"]).contains("class Core {}"))
        XCTAssertTrue(try XCTUnwrap(result["p/Outer.java"]).contains("Core make() { return new Core(); }"))
        let use = try XCTUnwrap(result["p/Use.java"])
        XCTAssertTrue(use.contains("import p.Outer.Core;"))
        XCTAssertTrue(use.contains("Outer.Core i;"))
    }

    func testStaticImportOfTypeMemberIsRewritten() async throws {
        try add("p/Util.java", """
        package p;
        public class €Util { public static int f() { return 1; } public static final int K = 1; }
        """)
        try add("q/User.java", """
        package q;
        import static p.Util.f;
        import static p.Util.*;
        class User { int x = f() + K; p.Util u; }
        """)
        let (provider, context) = try await makeProvider(caretIn: "p/Util.java")
        let plan = try await provider.rename(context, to: "Helpers")
        let result = try apply(plan)
        let user = try XCTUnwrap(result["q/User.java"])
        XCTAssertTrue(user.contains("import static p.Helpers.f;"))
        XCTAssertTrue(user.contains("import static p.Helpers.*;"))
        XCTAssertTrue(user.contains("p.Helpers u;"))
        XCTAssertEqual(plan.fileRenames.first?.to.lastPathComponent, "Helpers.java")
    }

    func testSamePackageConflictWarns() async throws {
        try add("p/Old.java", "package p; public class €Old {}")
        try add("p/Taken.java", "package p; public class Taken {}")
        let (provider, context) = try await makeProvider(caretIn: "p/Old.java")
        let plan = try await provider.rename(context, to: "Taken")
        XCTAssertTrue(plan.warnings.contains { $0.contains("Taken") && $0.contains("already exists") })
    }

    func testNestedSiblingConflictWarns() async throws {
        try add("p/Outer.java", "package p; public class Outer { class €A {} class B {} }")
        let (provider, context) = try await makeProvider(caretIn: "p/Outer.java")
        let plan = try await provider.rename(context, to: "B")
        XCTAssertTrue(plan.warnings.contains { $0.contains("nested type named B") })
    }

    func testInvalidIdentifiersAreBlocked() async throws {
        try add("p/Old.java", "package p; public class €Old {}")
        let (provider, context) = try await makeProvider(caretIn: "p/Old.java")
        for bad in ["", "1Bad", "class", "has space", "a-b"] {
            let plan = try await provider.rename(context, to: bad)
            XCTAssertNotNil(plan.blockingError, "\(bad) should be blocked")
        }
        let target = await provider.prepareRename(context)
        XCTAssertNotNil(target?.validate("class"))
        XCTAssertNil(target?.validate("Good"))
    }

    func testExistingFileBlocksFileRename() async throws {
        try add("p/Old.java", "package p; public class €Old {}")
        try add("p/New.java", "package p; class Different {}")
        let (provider, context) = try await makeProvider(caretIn: "p/Old.java")
        let plan = try await provider.rename(context, to: "New")
        XCTAssertNotNil(plan.blockingError)
    }

    func testUsageInGeneratedFileIsReadOnly() async throws {
        try add("p/Old.java", "package p; public class €Old {}")
        try add("build/generated/sources/p/Gen.java", "package p; class Gen { Old o; }")
        let (provider, context) = try await makeProvider(caretIn: "p/Old.java")
        let plan = try await provider.rename(context, to: "Fresh")
        let generated = plan.entries.filter { $0.url.path.contains("/build/generated/") }
        XCTAssertFalse(generated.isEmpty)
        XCTAssertTrue(generated.allSatisfy(\.isReadOnly))
        XCTAssertFalse(plan.workspaceEdit().changes.keys.contains { $0.path.contains("/build/generated/") })
    }

    // MARK: - Locals

    func testLocalAndParameterRename() async throws {
        try add("p/T.java", """
        package p;
        class T {
            int count;
            int m(int €total) {
                int count = total + 1;
                return count + total + this.count;
            }
        }
        """)
        let (provider, context) = try await makeProvider(caretIn: "p/T.java")
        let prepared = await provider.prepareRename(context)
        XCTAssertEqual(prepared?.currentName, "total")
        let plan = try await provider.rename(context, to: "sum")
        XCTAssertEqual(plan.entries.count, 3)
        XCTAssertTrue(plan.fileRenames.isEmpty)
        let text = try XCTUnwrap(apply(plan)["p/T.java"])
        XCTAssertTrue(text.contains("int m(int sum)"))
        XCTAssertTrue(text.contains("int count = sum + 1;"))
        XCTAssertTrue(text.contains("return count + sum + this.count;"))
    }

    // MARK: - Not renamable

    func testJarTypeIsNotRenamable() async throws {
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
        let provider = JavaRenameProvider(
            index: index, indexPaths: JavaIndexPaths(root: fixture.root.appendingPathComponent("cache")),
            candidates: JavaTextScanCandidateSource()
        )
        await provider.setRoots([fixture.root])
        let context = try makeContext(file: "p/T.java")
        let plan = try await provider.rename(context, to: "Other")
        XCTAssertTrue(plan.blockingError?.contains("library") == true)
    }

    func testMethodIsRenamable() async throws {
        try add("p/T.java", "package p; class T { void €run() {} }")
        let (provider, context) = try await makeProvider(caretIn: "p/T.java")
        let prepared = await provider.prepareRename(context)
        XCTAssertEqual(prepared?.kindDescription, "method")
    }

    // MARK: - Helpers

    private func add(_ name: String, _ marked: String) throws {
        if let marker = marked.range(of: "€") {
            markerOffsets[name] = marked.utf16.distance(from: marked.utf16.startIndex, to: marker.lowerBound.samePosition(in: marked.utf16)!)
        }
        try fixture.add(name, marked)
    }

    private func makeProvider(caretIn file: String) async throws -> (JavaRenameProvider, NavigationContext) {
        let environment = try await fixture.build()
        let provider = JavaRenameProvider(
            index: environment.index, indexPaths: JavaIndexPaths(root: fixture.root.appendingPathComponent("cache")),
            candidates: JavaTextScanCandidateSource()
        )
        await provider.setRoots([fixture.root])
        return (provider, try makeContext(file: file))
    }

    private func makeContext(file: String) throws -> NavigationContext {
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
        return NavigationContext(document: document, cursor: Cursor(position: position), selection: document.selection)
    }

    /// Applies every non-read-only entry and returns the new text of each edited file, by fixture path.
    private func apply(_ plan: RenamePlan) throws -> [String: String] {
        let ids = Set(plan.entries.filter { !$0.isReadOnly }.map(\.id))
        let edit = plan.workspaceEdit(including: ids)
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
