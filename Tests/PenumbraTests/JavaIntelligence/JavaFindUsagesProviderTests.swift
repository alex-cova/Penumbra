import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaFindUsagesProviderTests: XCTestCase {
    private func makeProvider(
        _ fixture: JavaReferenceFixture, nameIndex: JavaNameIndex? = nil, roots: [URL]? = nil,
        model: JavaGradleProjectModel? = nil, paths: JavaIndexPaths? = nil
    ) async throws -> JavaFindUsagesProvider {
        let environment = try await fixture.build(gradleModel: model, indexPaths: paths)
        let provider = JavaFindUsagesProvider(
            index: environment.index, indexPaths: paths ?? JavaIndexPaths(root: fixture.root.appendingPathComponent("cache")),
            nameIndex: nameIndex
        )
        await provider.setProjectRoots(roots ?? [fixture.root])
        if let model, let paths { await provider.setSourceSetClasspath(model, indexPaths: paths) }
        return provider
    }

    private func usageLines(_ provider: JavaFindUsagesProvider, _ fixture: JavaReferenceFixture) async throws -> [String] {
        let caret = try XCTUnwrap(fixture.caretLocation)
        let usages = await provider.findUsages(
            source: try XCTUnwrap(fixture.sources[caret.file]), url: fixture.url(caret.file), utf16Offset: caret.utf16Offset
        )
        return fixture.lines(usages)
    }

    func testClassUsagesAcrossFilesExcludeTheDeclaration() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("p/Foo.java", "package p; public class €Foo { }")
        try fixture.add("p/A.java", "package p; class A { Foo f; }")
        try fixture.add("p/B.java", "package p; class B { Foo make() { return new Foo(); } }")
        try fixture.add("p/C.java", "package p; class C { int Fooish; }")
        let provider = try await makeProvider(fixture)
        let lines = try await usageLines(provider, fixture)
        XCTAssertEqual(lines.count, 3)
        XCTAssertFalse(lines.contains { $0.hasPrefix("C.java") })
        XCTAssertFalse(lines.contains { $0.contains("public class") })
    }

    func testOverloadSiblingsAreExcluded() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class A { void €put(Foo f) {} void put(Bar b) {} }\nclass Foo {}\nclass Bar {}")
        try fixture.add("U.java", "class U { void go(A a, Foo f, Bar b) { a.put(f); a.put(b); a.put(f); } }")
        let provider = try await makeProvider(fixture)
        let caret = try XCTUnwrap(fixture.caretLocation)
        let usages = await provider.findUsages(
            source: try XCTUnwrap(fixture.sources[caret.file]), url: fixture.url(caret.file), utf16Offset: caret.utf16Offset
        )
        XCTAssertEqual(usages.count, 2)
        XCTAssertTrue(usages.allSatisfy { $0.kind == .call })
    }

    func testFieldUsagesIncludeReadsAndWrites() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class A { int €count; void inc() { count++; } int get() { return count; } }")
        try fixture.add("B.java", "class B { int peek(A a) { return a.count; } }")
        let provider = try await makeProvider(fixture)
        let lines = try await usageLines(provider, fixture)
        XCTAssertEqual(lines.count, 3)
    }

    func testLocalUsagesStayInFile() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class A { void go() { int €n = 1; n++; System.out.println(n); } }")
        try fixture.add("B.java", "class B { void go() { int n = 1; n++; } }")
        let provider = try await makeProvider(fixture)
        let lines = try await usageLines(provider, fixture)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("A.java") })
    }

    func testOverrideFamilyIsFollowedFromTheBaseMethod() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Base.java", "abstract class Base { abstract void €run(); }")
        try fixture.add("Impl.java", "class Impl extends Base { void run() {} }")
        try fixture.add("U.java", "class U { void go(Base b, Impl i) { b.run(); i.run(); } }")
        let provider = try await makeProvider(fixture)
        let caret = try XCTUnwrap(fixture.caretLocation)
        let usages = await provider.findUsages(
            source: try XCTUnwrap(fixture.sources[caret.file]), url: fixture.url(caret.file), utf16Offset: caret.utf16Offset
        )
        XCTAssertEqual(usages.filter { $0.url.lastPathComponent == "U.java" }.count, 2)
    }

    func testNoSymbolYieldsNoResult() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class A { €}")
        let provider = try await makeProvider(fixture)
        let lines = try await usageLines(provider, fixture)
        XCTAssertTrue(lines.isEmpty)
    }

    func testProvideReturnsLocationsWithUsageInfo() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Foo.java", "public class €Foo { }")
        try fixture.add("A.java", "class A {\n    Foo f;\n    Foo g;\n}")
        let provider = try await makeProvider(fixture)
        let caret = try XCTUnwrap(fixture.caretLocation)
        let text = try XCTUnwrap(fixture.sources[caret.file])
        let position = TextPosition(line: 0, column: caret.utf16Offset, utf16Offset: caret.utf16Offset)
        let document = Document(
            url: fixture.url(caret.file), displayName: caret.file, contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 10, height: 10), languageIdentifier: "java"
        )
        let context = NavigationContext(document: document, cursor: document.cursor, selection: document.selection, kind: .references)
        XCTAssertTrue(provider.isPrimary(for: context))
        let result = await provider.provide(context: context)
        guard case .multiple(let locations)? = result else { return XCTFail("expected multiple, got \(String(describing: result))") }
        XCTAssertEqual(locations.count, 2)
        let first = try XCTUnwrap(locations.first?.usage)
        XCTAssertEqual(first.line, 1)
        XCTAssertEqual(first.kindLabel, "type")
        XCTAssertEqual((first.lineText as NSString).substring(with: first.matchRange), "Foo")
        XCTAssertFalse(first.isAmbiguous)

        let definitionContext = NavigationContext(document: document, cursor: document.cursor, selection: document.selection, kind: .definition)
        XCTAssertFalse(provider.isPrimary(for: definitionContext))
    }

    func testNameIndexCandidatesAndOverlayForUnsavedBuffer() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Foo.java", "public class €Foo { }")
        try fixture.add("A.java", "class A { int x; }")
        let nameIndex = JavaNameIndex(paths: JavaIndexPaths(root: fixture.root.appendingPathComponent("names")))
        for await _ in await nameIndex.build(roots: [fixture.root]) {}
        let provider = try await makeProvider(fixture, nameIndex: nameIndex)
        var lines = try await usageLines(provider, fixture)
        XCTAssertTrue(lines.isEmpty)

        let unsaved = "class A { Foo f; }"
        await nameIndex.setOverlay(fixture.url("A.java"), text: unsaved)
        await provider.setOpenBufferLookup { url in
            url.lastPathComponent == "A.java" ? unsaved : nil
        }
        lines = try await usageLines(provider, fixture)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("A.java"))
    }

    func testGradleScopedVisibility() async throws {
        let fixture = try JavaReferenceFixture()
        let lib = fixture.root.appendingPathComponent("lib/src/main/java", isDirectory: true)
        let app = fixture.root.appendingPathComponent("app/src/main/java", isDirectory: true)
        let other = fixture.root.appendingPathComponent("other/src/main/java", isDirectory: true)
        try fixture.add("lib/src/main/java/Widget.java", "public class €Widget {}")
        try fixture.add("app/src/main/java/App.java", "class App { Widget w; }")
        try fixture.add("other/src/main/java/Other.java", "class Other { Widget w; }")
        let model = JavaGradleProjectModel(
            formatVersion: 4, gradleVersion: "9.0",
            subprojects: [
                .init(path: ":lib", directory: fixture.root, sourceSets: [.init(name: "main", sourceDirs: [lib])]),
                .init(
                    path: ":app", directory: fixture.root,
                    sourceSets: [.init(name: "main", sourceDirs: [app], projectDependencies: [.init(projectPath: ":lib", sourceSetName: "main")])]
                ),
                .init(path: ":other", directory: fixture.root, sourceSets: [.init(name: "main", sourceDirs: [other])])
            ]
        )
        let paths = JavaIndexPaths(root: fixture.root.appendingPathComponent("index-cache"))
        let provider = try await makeProvider(fixture, roots: [lib, app, other], model: model, paths: paths)
        let lines = try await usageLines(provider, fixture)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("App.java"))
    }
}
