import SwiftIntelligence
import XCTest
@testable import SwiftIntelligence
@testable import Umbra

final class SwiftIndexTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private func makeProject(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        roots.append(root)
        return root
    }

    private let projectFiles: [String: String] = [
        "Sources/App/Point.swift": """
        struct Point {
            var x: Int
            var y: Int
            func moved(by d: Int) -> Point { self }
        }
        """,
        "Sources/App/Point+Math.swift": """
        extension Point {
            func length() -> Double { 0 }
            static let zero = Point(x: 0, y: 0)
        }
        """,
        "Sources/App/Shape.swift": """
        protocol Shape { var area: Double { get } }
        extension Shape { func describe() -> String { "" } }
        class Base { func run() {}; func stop() {} }
        final class Circle: Base, Shape {
            var radius: Double = 1
            var area: Double { 0 }
            override func run() {}
        }
        """,
        "Sources/App/main.swift": """
        let p = Point(x: 1, y: 2)
        let q = p.moved(by: 1).moved(by: 2)
        let points: [Point] = []
        for point in points { print(point) }
        let name: String = ""
        let n = name.count
        """,
        "Sources/Lib/Lib.swift": "public struct LibThing { public func go() {} }\n",
        ".build/ignored/Hidden.swift": "struct Hidden {}\n"
    ]

    func testMembersMergeExtensionsAcrossFilesAndFollowInheritance() async throws {
        let root = try makeProject(projectFiles)
        let index = SwiftIndex()
        await index.setRoot(root)

        let point = await index.members(ofType: "Point", visibleFrom: nil).map(\.declaration.name)
        XCTAssertEqual(Set(point), ["x", "y", "moved", "length", "zero"])

        let circle = await index.members(ofType: "Circle", visibleFrom: nil)
        let names = circle.map(\.declaration.name)
        for expected in ["radius", "area", "run", "stop", "describe"] {
            XCTAssertTrue(names.contains(expected), "\(expected) missing from \(names)")
        }
        // `run` is declared by Circle and Base: the override shadows the inherited one.
        XCTAssertEqual(circle.filter { $0.declaration.name == "run" }.count, 1)
        XCTAssertEqual(circle.first { $0.declaration.name == "run" }?.owner, "Circle")
        XCTAssertEqual(circle.first { $0.declaration.name == "describe" }?.isInExtension, true)

        let hasHidden = await index.contains(root.appendingPathComponent(".build/ignored/Hidden.swift"))
        XCTAssertFalse(hasHidden)
        let subtypes = await index.subtypes(of: "Shape", visibleFrom: nil).map(\.declaration.name)
        XCTAssertEqual(Set(subtypes), ["Circle"])
    }

    func testAnOpenBufferReplacesTheIndexedFileWithoutASave() async throws {
        let root = try makeProject(projectFiles)
        let index = SwiftIndex()
        await index.setRoot(root)
        let file = root.appendingPathComponent("Sources/App/Point.swift")
        let before = await index.members(ofType: "Point", visibleFrom: nil).map(\.declaration.name)
        XCTAssertFalse(before.contains("scaled"))

        await index.noteOpenDocument(url: file, text: "struct Point {\n    var x: Int\n    func scaled() {}\n}\n")
        let after = await index.members(ofType: "Point", visibleFrom: nil).map(\.declaration.name)
        XCTAssertTrue(after.contains("scaled"))
        XCTAssertFalse(after.contains("moved"))
        // The other file's extension is still merged in.
        XCTAssertTrue(after.contains("length"))
    }

    func testAFileSeesItsOwnModuleAndTheOnesItImports() async throws {
        let root = try makeProject(projectFiles)
        let index = SwiftIndex()
        let app = root.appendingPathComponent("Sources/App").standardizedFileURL.path
        let lib = root.appendingPathComponent("Sources/Lib").standardizedFileURL.path
        await index.setModuleResolver { url in
            let path = url.standardizedFileURL.path
            if path.hasPrefix(app) { return "App" }
            if path.hasPrefix(lib) { return "Lib" }
            return nil
        }
        await index.setRoot(root)
        let main = root.appendingPathComponent("Sources/App/main.swift")

        let hidden = await index.types(named: "LibThing", visibleFrom: main)
        XCTAssertTrue(hidden.isEmpty, "Lib is not imported yet")

        await index.noteOpenDocument(url: main, text: "import Lib\nlet p = Point(x: 1, y: 2)\n")
        let visible = await index.types(named: "LibThing", visibleFrom: main)
        XCTAssertEqual(visible.count, 1)
        let moduleOfMain = await index.module(of: main)
        XCTAssertEqual(moduleOfMain, "App")
    }

    func testTheIndexSkipsTheManifestAndKeepsOnlyWhatLookupsNeed() async throws {
        var files = projectFiles
        files["Package.swift"] = "import PackageDescription\nlet package = Package(name: \"X\")\n"
        let root = try makeProject(files)
        let index = SwiftIndex()
        await index.setRoot(root)
        let hasManifest = await index.contains(root.appendingPathComponent("Package.swift"))
        XCTAssertFalse(hasManifest)
        let globals = await index.topLevel(named: "package", visibleFrom: nil)
        XCTAssertTrue(globals.isEmpty)

        let model = try XCTUnwrap(SwiftAnalysis.parseModel("struct A { func f() { let x = 1; print(x) } }"))
        XCTAssertFalse(model.uses.isEmpty)
        XCTAssertFalse(model.bindings.isEmpty)
        let indexed = model.indexed()
        XCTAssertTrue(indexed.uses.isEmpty && indexed.bindings.isEmpty && indexed.errors.isEmpty)
        XCTAssertEqual(indexed.declarations.count, 1)
        XCTAssertEqual(indexed.identifiers, model.identifiers)
    }

    func testResolverTypesChainsElementsAndStandardLibraryMembers() async throws {
        let root = try makeProject(projectFiles)
        let index = SwiftIndex()
        await index.setRoot(root)
        let main = root.appendingPathComponent("Sources/App/main.swift")
        let source = try String(contentsOf: main, encoding: .utf8)
        let parsed = try XCTUnwrap(SwiftAnalysis.parse(source))
        let resolver = SwiftResolver(index: index, model: parsed.model, url: main)
        let end = source.utf8.count

        // `p = Point(x:y:)` then `q = p.moved(by:).moved(by:)`: Point through a chain of written return types.
        let p = await resolver.value(of: SwiftChain(base: .name("p", at: end), steps: []), at: end)
        XCTAssertEqual(p, .instance("Point"))
        let q = await resolver.value(of: SwiftChain(base: .name("q", at: end), steps: []), at: end)
        XCTAssertEqual(q, .instance("Point"))
        // `for point in points` with `points: [Point]`.
        let loop = (source as NSString).range(of: "print(point)").location
        let point = await resolver.value(of: SwiftChain(base: .name("point", at: loop), steps: []), at: loop)
        XCTAssertEqual(point, .instance("Point"))
        // A standard-library member: `name.count`.
        let count = await resolver.value(of: SwiftChain(base: .name("n", at: end), steps: []), at: end)
        XCTAssertEqual(count, .instance("Int"))
        // A static member through the type.
        let zero = await resolver.value(
            of: SwiftChain(base: .name("Point", at: end), steps: [.member("zero")]), at: end
        )
        XCTAssertEqual(zero, .instance("Point"))
    }

    func testTargetsPickTheOverloadWithTheCallsLabels() async throws {
        let source = """
        struct Box {
            func put(_ value: Int) {}
            func put(value: Int, at index: Int) {}
        }
        func f(box: Box) {
            box.put(value: 1, at: 2)
            box.put(1)
        }
        """
        let parsed = try XCTUnwrap(SwiftAnalysis.parse(source))
        let index = SwiftIndex()
        await index.noteOpenDocument(url: URL(fileURLWithPath: "/tmp/Box.swift"), text: source)
        let resolver = SwiftResolver(index: index, model: parsed.model, url: URL(fileURLWithPath: "/tmp/Box.swift"))
        let uses = parsed.model.uses.filter { $0.name == "put" }
        XCTAssertEqual(uses.count, 2)
        let labelled = try XCTUnwrap(uses.first { $0.callLabels == ["value", "at"] })
        let plain = try XCTUnwrap(uses.first { $0.callLabels == ["_"] })
        guard case .declaration(_, let first, _)? = await resolver.target(forNameAt: labelled.bytes),
              case .declaration(_, let second, _)? = await resolver.target(forNameAt: plain.bytes) else {
            return XCTFail("no targets")
        }
        XCTAssertEqual(first.parameters.map { $0.label ?? "_" }, ["value", "at"])
        XCTAssertEqual(second.parameters.map { $0.label ?? "_" }, ["_"])
    }
}
