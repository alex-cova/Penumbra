import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// Show Siblings and Method Hierarchy, over small project families.
final class JavaMethodHierarchyTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("java-methodh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Show Siblings

    func testSiblingsAreTheOtherImplementationsOfTheSuperMethod() async throws {
        let shape = try write("Shape.java", "interface Shape { double area(); }")
        let circle = try write("Circle.java", "class Circle implements Shape { public double area() { return 1; } }")
        let square = try write("Square.java", "class Square implements Shape { public double area() { return 2; } }")
        let triangle = try write("Triangle.java", "class Triangle implements Shape { public double area() { return 3; } }")
        let files = [shape, circle, square, triangle]

        let hits = try await siblings(
            "class Circle implements Shape { public double €area() { return 1; } }", url: circle.url, indexing: files
        )

        XCTAssertEqual(hits.map(\.file).sorted(), ["Square.java", "Triangle.java"])
        XCTAssertEqual(Set(hits.map(\.text)), ["area"])
    }

    func testSiblingsOfAMethodThroughAClassChainSkipTheMethodItself() async throws {
        let base = try write("Base.java", "abstract class Base { abstract void run(); }")
        let mid = try write("Mid.java", "class Mid extends Base { void run() {} }")
        let leaf = try write("Leaf.java", "class Leaf extends Mid { void run() {} }")
        let other = try write("Other.java", "class Other extends Base { void run() {} }")

        let hits = try await siblings(
            "class Mid extends Base { void €run() {} }", url: mid.url, indexing: [base, mid, leaf, other]
        )

        XCTAssertEqual(hits.map(\.file).sorted(), ["Leaf.java", "Other.java"])
    }

    func testAMethodWithNoSuperMethodHasNoSiblings() async throws {
        let lonely = try write("Lonely.java", "class Lonely { void run() {} }")
        let hits = try await siblings("class Lonely { void €run() {} }", url: lonely.url, indexing: [lonely])
        XCTAssertTrue(hits.isEmpty)
    }

    func testSiblingsWorkFromACallToo() async throws {
        let shape = try write("Shape.java", "interface Shape { double area(); }")
        let circle = try write("Circle.java", "class Circle implements Shape { public double area() { return 1; } }")
        let square = try write("Square.java", "class Square implements Shape { public double area() { return 2; } }")
        let hits = try await siblings(
            "class T { double m(Circle c) { return c.€area(); } }", indexing: [shape, circle, square]
        )
        XCTAssertEqual(hits.map(\.file), ["Square.java"], "the called method is Circle.area; its sibling is Square's")
    }

    // MARK: - Method Hierarchy

    private func animals() throws -> [Fixture] {
        [
            try write("Animal.java", "abstract class Animal { abstract String speak(); }"),
            try write("Dog.java", "class Dog extends Animal { String speak() { return \"woof\"; } }"),
            try write("Cat.java", "class Cat extends Animal { String speak() { return \"meow\"; } }"),
            try write("Fish.java", "class Fish extends Animal { }"),
            try write("Bird.java", "abstract class Bird extends Animal { }"),
            try write("Puppy.java", "class Puppy extends Dog { }")
        ]
    }

    private let dogSource = "class Dog extends Animal { String speak() { return \"woof\"; } }"
    private var dogSpeakOffset: Int { "class Dog extends Animal { String ".utf16.count }

    /// The hierarchy's root, asked from the caret on `Dog.speak`.
    private func dogRoot(_ provider: JavaMethodHierarchyProvider, files: [Fixture]) async throws -> JavaMethodHierarchyNode {
        let root = await provider.rootNode(source: dogSource, fileURL: files[1].url, utf16Offset: dogSpeakOffset)
        return try XCTUnwrap(root)
    }

    private func child(_ name: String, of node: JavaMethodHierarchyNode, in provider: JavaMethodHierarchyProvider) async throws -> JavaMethodHierarchyNode {
        let children = await provider.subtypes(of: node, file: nil)
        return try XCTUnwrap(children.first { $0.type.qualifiedName == name }, "no \(name) under \(node.type.qualifiedName)")
    }

    func testTheRootIsTheTopmostClassThatDeclaresTheMethod() async throws {
        let files = try animals()
        let provider = try await methodProvider(indexing: files)
        let root = try await dogRoot(provider, files: files)
        XCTAssertEqual(root.type.qualifiedName, "Animal")
        XCTAssertEqual(root.status, .defines)
        XCTAssertEqual(root.subject.displayName, "speak()")
        XCTAssertEqual(root.subject.currentClass, "Dog")
        XCTAssertFalse(root.isCurrent)
    }

    func testSubtypesAreMarkedDefinesInheritsOrMissing() async throws {
        let files = try animals()
        let provider = try await methodProvider(indexing: files)
        let root = try await dogRoot(provider, files: files)

        let children = await provider.subtypes(of: root, file: files[1].url)
        let status = Dictionary(uniqueKeysWithValues: children.map { ($0.type.qualifiedName, $0.status) })
        XCTAssertEqual(status, [
            "Bird": .inherits,       // abstract: not expected to implement it
            "Cat": .defines,
            "Dog": .defines,
            "Fish": .shouldDefine    // concrete, and the nearest declaration is abstract
        ])
        XCTAssertEqual(children.filter(\.isCurrent).map(\.type.qualifiedName), ["Dog"])

        let dog = try await child("Dog", of: root, in: provider)
        let grandchildren = await provider.subtypes(of: dog, file: files[1].url)
        XCTAssertEqual(grandchildren.map(\.type.qualifiedName), ["Puppy"])
        XCTAssertEqual(grandchildren.first?.status, .inherits, "Puppy gets Dog's implementation")
    }

    func testAConcreteClassBelowAnImplementedMethodInheritsItEvenIfAnAncestorIsAbstract() async throws {
        let files = try animals() + [try write("Beagle.java", "class Beagle extends Puppy { }")]
        let provider = try await methodProvider(indexing: files)
        let root = try await dogRoot(provider, files: files)
        let dog = try await child("Dog", of: root, in: provider)
        let puppy = try await child("Puppy", of: dog, in: provider)
        let beagle = try await child("Beagle", of: puppy, in: provider)
        XCTAssertEqual(beagle.status, .inherits, "Dog implements speak(); the abstract Animal declaration is no longer the nearest")
    }

    func testTheCaretOnACallBuildsTheSameHierarchy() async throws {
        let files = try animals()
        let provider = try await methodProvider(indexing: files)
        let source = "class T { String m(Dog d) { return d.speak(); } }"
        let found = await provider.rootNode(source: source, fileURL: nil, utf16Offset: (source as NSString).range(of: "speak").location)
        let root = try XCTUnwrap(found)
        XCTAssertEqual(root.type.qualifiedName, "Animal")
        XCTAssertEqual(root.subject.currentClass, "Dog")
    }

    func testNoMethodAtTheCaretMeansNoHierarchy() async throws {
        let files = try animals()
        let provider = try await methodProvider(indexing: files)
        let source = "class T { int field; }"
        let root = await provider.rootNode(source: source, fileURL: nil, utf16Offset: (source as NSString).range(of: "field").location)
        XCTAssertNil(root)
    }

    func testSupertypesAreJudgedByThemselves() async throws {
        let files = try animals()
        let provider = try await methodProvider(indexing: files)
        let root = try await dogRoot(provider, files: files)
        let dog = try await child("Dog", of: root, in: provider)
        let ups = await provider.supertypes(of: dog, file: nil)
        XCTAssertEqual(ups.first { $0.type.qualifiedName == "Animal" }?.status, .defines)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let url: URL
        let source: String
    }

    private struct Hit {
        let location: Location
        let source: String
        var file: String { location.url?.lastPathComponent ?? "" }
        var text: String {
            let ns = source as NSString
            let start = max(0, min(location.range.start.utf16Offset, ns.length))
            let end = max(start, min(location.range.end.utf16Offset, ns.length))
            return ns.substring(with: NSRange(location: start, length: end - start))
        }
    }

    private func write(_ name: String, _ source: String) throws -> Fixture {
        let url = scratch.appendingPathComponent(name)
        try source.write(to: url, atomically: true, encoding: .utf8)
        return Fixture(url: url, source: source)
    }

    private func makeIndex(_ files: [Fixture]) async throws -> JavaIndex {
        let stubs = files.flatMap { JavaSourceStubBuilder.build(source: $0.source, url: $0.url).classes }
        let url = scratch.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: url))])
        return index
    }

    private func methodProvider(indexing files: [Fixture]) async throws -> JavaMethodHierarchyProvider {
        let index = try await makeIndex(files)
        let types = JavaTypeHierarchyProvider(index: index, indexPaths: JavaIndexPaths(root: scratch.appendingPathComponent("cache")))
        return JavaMethodHierarchyProvider(typeHierarchy: types)
    }

    private func siblings(_ marked: String, url: URL? = nil, indexing files: [Fixture]) async throws -> [Hit] {
        let index = try await makeIndex(files)
        let provider = JavaGoToDefinitionProvider(
            index: index, indexPaths: JavaIndexPaths(root: scratch.appendingPathComponent("cache", isDirectory: true))
        )
        let marker = marked.range(of: "€")!
        let source = marked.replacingOccurrences(of: "€", with: "")
        let utf16 = marked.utf16.distance(from: marked.utf16.startIndex, to: marker.lowerBound.samePosition(in: marked.utf16)!)
        let position = JavaNavigationText.position(utf16Offset: utf16, in: source)
        let documentURL = url ?? scratch.appendingPathComponent("T.java")
        let document = Document(
            url: documentURL, displayName: documentURL.lastPathComponent,
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
        let result = await provider.provide(context: NavigationContext(
            document: document, cursor: Cursor(position: position), selection: document.selection, kind: .siblings
        ))
        let locations: [Location]
        switch result {
        case .single(let location)?: locations = [location]
        case .multiple(let all)?: locations = all
        case nil: return []
        }
        return try locations.map { location in
            let url = try XCTUnwrap(location.url)
            return Hit(location: location, source: try String(contentsOf: url, encoding: .utf8))
        }
    }
}

/// The hierarchy scope tells test sources from production ones.
final class JavaHierarchyScopeTests: XCTestCase {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testAllContainsEverything() {
        XCTAssertTrue(JavaHierarchyScope.contains(url("/p/src/test/java/A.java"), scope: .all, model: nil))
        XCTAssertTrue(JavaHierarchyScope.contains(nil, scope: .all, model: nil))
    }

    func testWithoutAModelTheFolderDecides() {
        XCTAssertTrue(JavaHierarchyScope.contains(url("/p/src/main/java/A.java"), scope: .production, model: nil))
        XCTAssertFalse(JavaHierarchyScope.contains(url("/p/src/test/java/ATest.java"), scope: .production, model: nil))
        XCTAssertTrue(JavaHierarchyScope.contains(url("/p/src/test/java/ATest.java"), scope: .tests, model: nil))
        XCTAssertFalse(JavaHierarchyScope.contains(url("/p/src/main/java/A.java"), scope: .tests, model: nil))
    }

    func testAFileWithNoProjectPathIsProductionNotTest() {
        XCTAssertTrue(JavaHierarchyScope.contains(nil, scope: .production, model: nil))
        XCTAssertFalse(JavaHierarchyScope.contains(nil, scope: .tests, model: nil))
    }

    func testTheSubtypeSearchHonoursTheScope() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("java-scope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let mainDirectory = scratch.appendingPathComponent("src/main/java", isDirectory: true)
        let testDirectory = scratch.appendingPathComponent("src/test/java", isDirectory: true)
        try FileManager.default.createDirectory(at: mainDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        let sources: [(URL, String)] = [
            (mainDirectory.appendingPathComponent("Base.java"), "class Base { }"),
            (mainDirectory.appendingPathComponent("Prod.java"), "class Prod extends Base { }"),
            (testDirectory.appendingPathComponent("FakeBase.java"), "class FakeBase extends Base { }")
        ]
        var stubs: [JavaClassStub] = []
        for (url, text) in sources {
            try text.write(to: url, atomically: true, encoding: .utf8)
            stubs += JavaSourceStubBuilder.build(source: text, url: url).classes
        }
        let shard = scratch.appendingPathComponent("project.idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: shard))])
        let provider = JavaTypeHierarchyProvider(index: index, indexPaths: JavaIndexPaths(root: scratch.appendingPathComponent("cache")))
        let found = await provider.rootType(named: "Base", file: nil)
        let base = try XCTUnwrap(found)

        let everything = await provider.subtypes(of: base, file: nil, scope: .all).map(\.qualifiedName)
        let production = await provider.subtypes(of: base, file: nil, scope: .production).map(\.qualifiedName)
        let tests = await provider.subtypes(of: base, file: nil, scope: .tests).map(\.qualifiedName)
        XCTAssertEqual(everything, ["FakeBase", "Prod"])
        XCTAssertEqual(production, ["Prod"])
        XCTAssertEqual(tests, ["FakeBase"])
    }
}
