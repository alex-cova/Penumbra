import XCTest
import EditorIntelligence
@testable import JavaIntelligence

final class JavaTypeHierarchyTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("java-hierarchy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Supertypes

    func testSupertypesAreSuperclassFirstThenInterfacesAndWalkTransitively() async throws {
        let provider = try await makeProvider(sources: [
            "Iface.java": "interface Iface { }",
            "Other.java": "interface Other extends Iface { }",
            "Base.java": "abstract class Base implements Iface { }",
            "Leaf.java": "class Leaf extends Base implements Other { }"
        ])
        let leaf = try await root(provider, "class T { €Leaf l; }")
        let direct = await provider.supertypes(of: leaf, file: nil)
        XCTAssertEqual(direct.map(\.qualifiedName), ["Base", "Other"])

        let base = try XCTUnwrap(direct.first)
        let baseSupers = await provider.supertypes(of: base, file: nil)
        XCTAssertEqual(baseSupers.map(\.qualifiedName), ["Iface"])
        XCTAssertEqual(baseSupers.first?.path, ["Leaf", "Base", "Iface"])
        XCTAssertEqual(baseSupers.first?.kind, .interfaceKind)

        // The same type under two parents is two distinct nodes.
        let other = try XCTUnwrap(direct.last)
        let otherSupers = await provider.supertypes(of: other, file: nil)
        XCTAssertEqual(otherSupers.map(\.qualifiedName), ["Iface"])
        XCTAssertNotEqual(otherSupers.first?.id, baseSupers.first?.id)
    }

    func testSupertypesResolveThroughTheDeclaringFilesImports() async throws {
        let provider = try await makeProvider(sources: [
            "a/Animal.java": "package a; public class Animal { }",
            "b/Dog.java": "package b; import a.Animal; public class Dog extends Animal { }"
        ])
        let dog = try await root(provider, "import b.Dog; class T { €Dog d; }")
        let supers = await provider.supertypes(of: dog, file: nil)
        XCTAssertEqual(supers.map(\.qualifiedName), ["a.Animal"])
        XCTAssertEqual(supers.first?.displayName, "Animal")
        XCTAssertEqual(supers.first?.packageName, "a")
    }

    func testImplicitObjectIsTheSuperclassOfAClassButNotAnInterface() async throws {
        let object = JavaClassStub(
            binaryName: "java.lang.Object", qualifiedName: "java.lang.Object", simpleName: "Object", packageName: "java.lang",
            kind: .classKind, modifiers: [.publicFlag], origin: .jdkModule("java.base")
        )
        let provider = try await makeProvider(sources: ["A.java": "class A { }", "I.java": "interface I { }"], extraStubs: [object])
        let a = try await root(provider, "class T { €A a; }")
        let aSupers = await provider.supertypes(of: a, file: nil)
        XCTAssertEqual(aSupers.map(\.qualifiedName), ["java.lang.Object"])
        XCTAssertEqual(aSupers.first?.origin, .jdk)
        XCTAssertFalse(try XCTUnwrap(aSupers.first).isProjectType)
        let i = try await root(provider, "class T { €I i; }")
        let iSupers = await provider.supertypes(of: i, file: nil)
        XCTAssertTrue(iSupers.isEmpty)
    }

    func testACycleInBrokenCodeDoesNotExpandForever() async throws {
        let provider = try await makeProvider(sources: [
            "A.java": "class A extends B { }",
            "B.java": "class B extends A { }"
        ])
        let a = try await root(provider, "class T { €A a; }")
        let first = await provider.supertypes(of: a, file: nil)
        XCTAssertEqual(first.map(\.qualifiedName), ["B"])
        let second = await provider.supertypes(of: try XCTUnwrap(first.first), file: nil)
        XCTAssertTrue(second.isEmpty, "A is already on the path")
        let subs = await provider.subtypes(of: a, file: nil)
        XCTAssertEqual(subs.map(\.qualifiedName), ["B"])
        let subsOfB = await provider.subtypes(of: try XCTUnwrap(subs.first), file: nil)
        XCTAssertTrue(subsOfB.isEmpty)
    }

    // MARK: - Subtypes

    func testSubtypesAreTheDirectProjectSubtypesSortedByName() async throws {
        let provider = try await makeProvider(sources: [
            "Shape.java": "interface Shape { }",
            "Round.java": "abstract class Round implements Shape { }",
            "Circle.java": "class Circle extends Round { }",
            "Square.java": "class Square implements Shape { }",
            "Alone.java": "class Alone { }"
        ])
        let shape = try await root(provider, "class T { €Shape s; }")
        let direct = await provider.subtypes(of: shape, file: nil)
        XCTAssertEqual(direct.map(\.qualifiedName), ["Round", "Square"])
        XCTAssertEqual(direct.first?.path, ["Shape", "Round"])
        XCTAssertTrue(try XCTUnwrap(direct.first).isProjectType)

        let round = try XCTUnwrap(direct.first)
        let below = await provider.subtypes(of: round, file: nil)
        XCTAssertEqual(below.map(\.qualifiedName), ["Circle"])
        let none = await provider.subtypes(of: try XCTUnwrap(below.first), file: nil)
        XCTAssertTrue(none.isEmpty)
    }

    func testSubtypesMatchByResolvedTypeNotJustTheSimpleName() async throws {
        let provider = try await makeProvider(sources: [
            "a/Base.java": "package a; public class Base { }",
            "b/Base.java": "package b; public class Base { }",
            "c/Child.java": "package c; import a.Base; public class Child extends Base { }"
        ])
        let a = try await root(provider, "import a.Base; class T { €Base x; }")
        let subsOfA = await provider.subtypes(of: a, file: nil)
        XCTAssertEqual(subsOfA.map(\.qualifiedName), ["c.Child"])
        let b = try await root(provider, "import b.Base; class T { €Base x; }")
        let subsOfB = await provider.subtypes(of: b, file: nil)
        XCTAssertTrue(subsOfB.isEmpty)
    }

    func testNestedTypesShowTheirOuterNameAndKind() async throws {
        let provider = try await makeProvider(sources: [
            "Outer.java": "class Outer { interface Handler { } enum Mode implements Handler { X } record R() implements Handler { } }"
        ])
        let handler = try await root(provider, "class T { Outer.€Handler h; }")
        XCTAssertEqual(handler.displayName, "Outer.Handler")
        XCTAssertEqual(handler.kind, .interfaceKind)
        let subs = await provider.subtypes(of: handler, file: nil)
        XCTAssertEqual(subs.map(\.displayName), ["Outer.Mode", "Outer.R"])
        XCTAssertEqual(subs.map(\.kind), [.enumKind, .recordKind])
    }

    func testMainSourceSetDoesNotSeeATestOnlySubtype() async throws {
        let mainDir = scratch.appendingPathComponent("src/main/java", isDirectory: true)
        let testDir = scratch.appendingPathComponent("src/test/java", isDirectory: true)
        let service = try write("Service.java", "interface Service { }", in: mainDir)
        let fake = try write("FakeService.java", "class FakeService implements Service { }", in: testDir)
        let paths = JavaIndexPaths(root: scratch.appendingPathComponent("cache", isDirectory: true))
        let mainShard = paths.projectSourcesShard(for: mainDir.standardizedFileURL)
        let testShard = paths.projectSourcesShard(for: testDir.standardizedFileURL)
        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 1, reader: try writeShard(stubs(of: service), to: mainShard), shardPath: mainShard.path),
            .init(precedence: 1, reader: try writeShard(stubs(of: fake), to: testShard), shardPath: testShard.path)
        ])
        let model = JavaGradleProjectModel(
            formatVersion: 2, gradleVersion: "9.0",
            subprojects: [.init(
                path: ":", directory: scratch,
                sourceSets: [
                    .init(name: "main", sourceDirs: [mainDir]),
                    .init(name: "test", sourceDirs: [testDir], projectDependencies: [.init(projectPath: ":", sourceSetName: "main")])
                ]
            )]
        )
        let provider = JavaTypeHierarchyProvider(index: index, indexPaths: paths)
        await provider.setSourceSetClasspath(model, indexPaths: paths)
        let found = await provider.rootType(named: "Service", file: nil)
        let node = try XCTUnwrap(found)

        let fromMain = await provider.subtypes(of: node, file: mainDir.appendingPathComponent("App.java"))
        XCTAssertTrue(fromMain.isEmpty)
        let fromTest = await provider.subtypes(of: node, file: testDir.appendingPathComponent("AppTest.java"))
        XCTAssertEqual(fromTest.map(\.qualifiedName), ["FakeService"])
    }

    // MARK: - Root

    func testRootFollowsTheCaretOnAReferenceADeclarationThisAndTheEnclosingType() async throws {
        let provider = try await makeProvider(sources: [
            "Base.java": "class Base { }",
            "Child.java": "class Child extends Base { void run() { } }"
        ])
        let reference = try await root(provider, "class T { €Child c; }")
        XCTAssertEqual(reference.qualifiedName, "Child")
        let declaration = try await root(provider, "class €Child extends Base { void run() { } }", url: scratch.appendingPathComponent("Child.java"))
        XCTAssertEqual(declaration.qualifiedName, "Child")
        let this = try await root(provider, "class Child extends Base { void run() { €this.run(); } }", url: scratch.appendingPathComponent("Child.java"))
        XCTAssertEqual(this.qualifiedName, "Child")
        // A caret on a method call falls back to the class the caret is in.
        let inside = try await root(provider, "class Child extends Base { void run() { €go(); } void go() { } }", url: scratch.appendingPathComponent("Child.java"))
        XCTAssertEqual(inside.qualifiedName, "Child")
        XCTAssertEqual(inside.path, ["Child"])
    }

    func testRootUsesTheLiveBufferForATypeNotIndexedYet() async throws {
        let provider = try await makeProvider(sources: ["Base.java": "class Base { }"])
        let node = try await root(provider, "class Fresh extends Base { void m() { €x(); } }")
        XCTAssertEqual(node.qualifiedName, "Fresh")
        XCTAssertEqual(node.path, ["Fresh"])
    }

    func testNoRootOutsideAnyType() async throws {
        let provider = try await makeProvider(sources: ["Base.java": "class Base { }"])
        let result = await provider.rootType(source: "// only a comment", fileURL: nil, utf16Offset: 3)
        XCTAssertNil(result)
        let unknown = await provider.rootType(named: "does.not.Exist", file: nil)
        XCTAssertNil(unknown)
    }

    // MARK: - Location

    func testLocationSelectsTheTypeNameInItsSourceFile() async throws {
        let provider = try await makeProvider(sources: ["Base.java": "class Base { }", "Child.java": "class Child extends Base { }"])
        let child = try await root(provider, "class T { €Child c; }")
        let supers = await provider.supertypes(of: child, file: nil)
        let found = await provider.location(of: try XCTUnwrap(supers.first), file: nil)
        let location = try XCTUnwrap(found)
        XCTAssertEqual(location.url?.lastPathComponent, "Base.java")
        let text = try String(contentsOf: try XCTUnwrap(location.url), encoding: .utf8) as NSString
        XCTAssertEqual(
            text.substring(with: NSRange(location: location.range.start.utf16Offset, length: location.range.end.utf16Offset - location.range.start.utf16Offset)),
            "Base"
        )
    }

    func testAJarTypeWithoutAttachedSourceHasNoLocation() async throws {
        let jar = scratch.appendingPathComponent("lib.jar")
        FileManager.default.createFile(atPath: jar.path, contents: Data())
        let lib = JavaClassStub(
            binaryName: "Lib", qualifiedName: "Lib", simpleName: "Lib", packageName: "",
            kind: .classKind, modifiers: [.publicFlag], origin: .jar(jar)
        )
        let provider = try await makeProvider(sources: ["Mine.java": "class Mine extends Lib { }"], extraStubs: [lib])
        let mine = try await root(provider, "class T { €Mine m; }")
        let supers = await provider.supertypes(of: mine, file: nil)
        XCTAssertEqual(supers.first?.origin, .jar)
        let location = await provider.location(of: try XCTUnwrap(supers.first), file: nil)
        XCTAssertNil(location)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let url: URL
        let source: String
    }

    private func write(_ name: String, _ source: String, in directory: URL? = nil) throws -> Fixture {
        let url = (directory ?? scratch).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: url, atomically: true, encoding: .utf8)
        return Fixture(url: url, source: source)
    }

    private func stubs(of fixture: Fixture) -> [JavaClassStub] {
        JavaSourceStubBuilder.build(source: fixture.source, url: fixture.url).classes
    }

    private func writeShard(_ stubs: [JavaClassStub], to url: URL) throws -> JavaIndexShardReader {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        return try JavaIndexShardReader(url: url)
    }

    private func makeProvider(sources: [String: String], extraStubs: [JavaClassStub] = []) async throws -> JavaTypeHierarchyProvider {
        var all = extraStubs
        for (name, source) in sources.sorted(by: { $0.key < $1.key }) {
            all.append(contentsOf: stubs(of: try write(name, source)))
        }
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try writeShard(all, to: scratch.appendingPathComponent("\(UUID().uuidString).idx")))])
        return JavaTypeHierarchyProvider(index: index, indexPaths: JavaIndexPaths(root: scratch.appendingPathComponent("cache", isDirectory: true)))
    }

    private func root(_ provider: JavaTypeHierarchyProvider, _ marked: String, url: URL? = nil) async throws -> JavaTypeHierarchyNode {
        let marker = try XCTUnwrap(marked.range(of: "€"))
        let source = marked.replacingOccurrences(of: "€", with: "")
        let utf16 = marked.utf16.distance(from: marked.utf16.startIndex, to: marker.lowerBound.samePosition(in: marked.utf16)!)
        let node = await provider.rootType(source: source, fileURL: url ?? scratch.appendingPathComponent("T.java"), utf16Offset: utf16)
        return try XCTUnwrap(node, "no type at the caret in: \(source)")
    }
}
