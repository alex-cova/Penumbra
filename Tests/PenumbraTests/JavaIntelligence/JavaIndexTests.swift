import XCTest
@testable import JavaIntelligence

final class JavaIndexTests: XCTestCase {
    private func tempShardURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).idx")
    }

    private func writeShard(_ stubs: [JavaClassStub]) throws -> JavaIndexShardReader {
        let url = tempShardURL()
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        return try JavaIndexShardReader(url: url)
    }

    private func stub(_ qualifiedName: String, kind: JavaTypeKind = .classKind) -> JavaClassStub {
        let simple = String(qualifiedName.split(separator: ".").last!)
        let pkg = qualifiedName.contains(".") ? qualifiedName.components(separatedBy: ".").dropLast().joined(separator: ".") : ""
        return JavaClassStub(
            binaryName: qualifiedName, qualifiedName: qualifiedName, simpleName: simple, packageName: pkg,
            kind: kind, modifiers: [.publicFlag], origin: .jdkModule("java.base")
        )
    }

    func testClassStubLooksUpAcrossSources() async throws {
        let jdkReader = try writeShard([stub("java.lang.String"), stub("java.util.ArrayList")])
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: jdkReader)])

        let found = await index.classStub(qualifiedName: "java.lang.String")
        XCTAssertEqual(found?.qualifiedName, "java.lang.String")
        let missing = await index.classStub(qualifiedName: "com.example.Missing")
        XCTAssertNil(missing)
    }

    func testOverlayShadowsLowerPrecedenceSource() async throws {
        let jdkReader = try writeShard([stub("com.example.Foo")])
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: jdkReader)])

        let overlaid = JavaClassStub(
            binaryName: "com.example.Foo", qualifiedName: "com.example.Foo", simpleName: "Foo", packageName: "com.example",
            kind: .classKind, modifiers: [.publicFlag, .finalFlag], origin: .source(URL(fileURLWithPath: "/tmp/Foo.java"), nameRange: 0..<3)
        )
        await index.setOverlay(["com.example.Foo": overlaid])

        let found = await index.classStub(qualifiedName: "com.example.Foo")
        XCTAssertTrue(found?.modifiers.contains(.finalFlag) == true, "overlay definition should win")
    }

    func testHigherPrecedenceSourceWinsOnCollidingQualifiedName() async throws {
        let jdkReader = try writeShard([stub("com.example.Foo")]) // precedence 3
        let sourceReader = try writeShard([{
            var s = stub("com.example.Foo")
            s = JavaClassStub(
                binaryName: s.binaryName, qualifiedName: s.qualifiedName, simpleName: s.simpleName, packageName: s.packageName,
                kind: s.kind, modifiers: [.publicFlag, .abstractFlag], origin: .jdkModule("shadowed")
            )
            return s
        }()]) // precedence 1

        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 3, reader: jdkReader),
            .init(precedence: 1, reader: sourceReader)
        ])

        let found = await index.classStub(qualifiedName: "com.example.Foo")
        XCTAssertTrue(found?.modifiers.contains(.abstractFlag) == true)
    }

    func testSimpleNamePrefixSearchIsCaseInsensitiveAndDeduplicated() async throws {
        let reader = try writeShard([stub("java.util.ArrayList"), stub("java.util.ArrayDeque"), stub("java.lang.String")])
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: reader)])

        let results = await index.classes(simpleNamePrefix: "array")
        XCTAssertEqual(Set(results.map(\.simpleName)), ["ArrayList", "ArrayDeque"])
    }

    func testSimpleNamePrefixSearchSupportsCamelHumpAbbreviation() async throws {
        let reader = try writeShard([stub("java.util.concurrent.ConcurrentHashMap"), stub("java.util.HashMap")])
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: reader)])

        let results = await index.classes(simpleNamePrefix: "CHM")
        XCTAssertEqual(results.map(\.simpleName), ["ConcurrentHashMap"])
    }

    func testSimpleNamePrefixSearchRespectsLimit() async throws {
        let stubs = (0..<20).map { stub("com.example.Item\($0)") }
        let reader = try writeShard(stubs)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: reader)])

        let results = await index.classes(simpleNamePrefix: "Item", limit: 5)
        XCTAssertEqual(results.count, 5)
    }

    func testClassesInPackage() async throws {
        let reader = try writeShard([stub("java.util.ArrayList"), stub("java.util.HashMap"), stub("java.lang.String")])
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: reader)])

        let results = await index.classes(inPackage: "java.util")
        XCTAssertEqual(Set(results.map(\.simpleName)), ["ArrayList", "HashMap"])
    }

    func testSubpackagesOfReturnsOnlyDirectChildren() async throws {
        let reader = try writeShard([
            stub("java.util.ArrayList"),
            stub("java.util.concurrent.atomic.AtomicInteger"),
            stub("java.util.concurrent.ConcurrentHashMap"),
            stub("java.lang.String")
        ])
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: reader)])

        let subpackagesOfUtil = await index.subpackages(of: "java.util")
        XCTAssertEqual(subpackagesOfUtil, ["java.util.concurrent"])

        // All fixture qualified names start with "java...", so "java" is the only direct child of
        // the root package; "java.lang"/"java.util" are two levels down and shouldn't appear here.
        let topLevel = await index.subpackages(of: "")
        XCTAssertEqual(topLevel, ["java"])
    }

    func testUpdateOverlayRemovesEntryWhenNil() async throws {
        let index = JavaIndex()
        let s = stub("com.example.Foo")
        await index.updateOverlay(qualifiedName: "com.example.Foo", stub: s)
        var found = await index.classStub(qualifiedName: "com.example.Foo")
        XCTAssertNotNil(found)
        await index.updateOverlay(qualifiedName: "com.example.Foo", stub: nil)
        found = await index.classStub(qualifiedName: "com.example.Foo")
        XCTAssertNil(found)
    }
}
