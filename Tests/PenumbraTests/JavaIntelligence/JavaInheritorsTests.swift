import XCTest
@testable import JavaIntelligence

/// F15: `JavaInheritorTable` / `JavaInheritors` answer "what extends X" for the project's classes.
final class JavaInheritorsTests: XCTestCase {
    private func ref(_ name: String) -> JavaTypeRef {
        .classType(qualifiedName: name, arguments: [], outer: nil)
    }

    private func stub(
        _ qualifiedName: String, kind: JavaTypeKind = .classKind, superclass: String? = nil, interfaces: [String] = [],
        origin: JavaStubOrigin = .jdkModule("test")
    ) -> JavaClassStub {
        let simple = String(qualifiedName.split(separator: ".").last!)
        let package = qualifiedName.split(separator: ".").dropLast().joined(separator: ".")
        return JavaClassStub(
            binaryName: qualifiedName, qualifiedName: qualifiedName, simpleName: simple, packageName: package,
            kind: kind, modifiers: [.publicFlag], superclass: superclass.map(ref), interfaces: interfaces.map(ref),
            origin: origin
        )
    }

    private func sourceStub(
        _ qualifiedName: String, kind: JavaTypeKind = .classKind, superclass: String? = nil, interfaces: [String] = []
    ) -> JavaClassStub {
        stub(qualifiedName, kind: kind, superclass: superclass, interfaces: interfaces,
             origin: .source(URL(fileURLWithPath: "/test/\(qualifiedName).java"), nameRange: 0..<1))
    }

    private func reader(_ stubs: [JavaClassStub]) throws -> JavaIndexShardReader {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try JavaIndexShardReader(url: url)
    }

    private func makeIndex(project: [JavaClassStub], jar: [JavaClassStub] = [], shardPath: String = "") async throws -> JavaIndex {
        let index = JavaIndex()
        var sources = [JavaIndex.Source(precedence: 1, reader: try reader(project), shardPath: shardPath)]
        if !jar.isEmpty { sources.append(JavaIndex.Source(precedence: 2, reader: try reader(jar))) }
        await index.setSources(sources)
        return index
    }

    private func names(_ stubs: [JavaClassStub]) -> [String] { stubs.map(\.qualifiedName) }

    func testTransitiveSubtypesThroughProjectClasses() async throws {
        let index = try await makeIndex(project: [
            stub("a.Repo", kind: .interfaceKind),
            stub("a.UserRepo", interfaces: ["a.Repo"]),
            stub("b.SqlUserRepo", superclass: "a.UserRepo"),
            stub("b.Unrelated"),
        ])
        let subtypes = await JavaInheritors.subtypes(of: "a.Repo", index: index)
        XCTAssertEqual(names(subtypes), ["a.UserRepo", "b.SqlUserRepo"])
        let direct = await JavaInheritors.directSubtypes(of: "a.Repo", index: index)
        XCTAssertEqual(names(direct), ["a.UserRepo"])
    }

    /// Two interfaces called `Repo`: the table is keyed by simple name, the answer is not.
    func testSameSimpleNameInAnotherPackageIsNotASubtype() async throws {
        let index = try await makeIndex(project: [
            stub("a.Repo", kind: .interfaceKind),
            stub("c.Repo", kind: .interfaceKind),
            stub("a.Impl", interfaces: ["a.Repo"]),
            stub("c.OtherImpl", interfaces: ["c.Repo"]),
        ])
        let subtypes = await JavaInheritors.subtypes(of: "a.Repo", index: index)
        XCTAssertEqual(names(subtypes), ["a.Impl"])
    }

    func testJarClassesAreNotIndexed() async throws {
        let index = try await makeIndex(
            project: [stub("a.Repo", kind: .interfaceKind), stub("a.Impl", interfaces: ["a.Repo"])],
            jar: [stub("lib.LibImpl", interfaces: ["a.Repo"])]
        )
        let subtypes = await JavaInheritors.subtypes(of: "a.Repo", index: index)
        XCTAssertEqual(names(subtypes), ["a.Impl"])
    }

    /// F-08: a project class that reaches the target through a library supertype (`Through`
    /// extends `lib.Base`, which implements `a.Repo`) is found via the library bridge. The
    /// project class that merely shares the library supertype's simple name (`x.Base`) is not.
    func testSubtypesThroughALibraryIntermediate() async throws {
        let index = try await makeIndex(
            project: [
                sourceStub("a.Repo", kind: .interfaceKind),
                sourceStub("a.Impl", interfaces: ["a.Repo"]),
                sourceStub("p.Through", superclass: "lib.Base"),
                sourceStub("x.Base"),
            ],
            jar: [stub("lib.Base", interfaces: ["a.Repo"])]
        )
        let subtypes = await JavaInheritors.subtypes(of: "a.Repo", index: index)
        XCTAssertEqual(names(subtypes), ["a.Impl", "p.Through"])
    }

    /// F-08: the bridge follows chains of library supertypes, not just one hop.
    func testSubtypesThroughTwoLibraryIntermediates() async throws {
        let index = try await makeIndex(
            project: [
                sourceStub("a.Repo", kind: .interfaceKind),
                sourceStub("p.Deep", superclass: "lib.Mid"),
            ],
            jar: [
                stub("lib.Mid", superclass: "lib.Bottom"),
                stub("lib.Bottom", interfaces: ["a.Repo"]),
            ]
        )
        let subtypes = await JavaInheritors.subtypes(of: "a.Repo", index: index)
        XCTAssertEqual(names(subtypes), ["p.Deep"])
    }

    /// F-08: a library subtree that never reaches the target seeds nothing.
    func testUnrelatedLibrarySubtreeIsNotSeeded() async throws {
        let index = try await makeIndex(
            project: [
                sourceStub("a.Repo", kind: .interfaceKind),
                sourceStub("q.UsesOther", superclass: "lib.Other"),
            ],
            jar: [stub("lib.Other")]
        )
        let subtypes = await JavaInheritors.subtypes(of: "a.Repo", index: index)
        XCTAssertTrue(subtypes.isEmpty)
    }

    func testOpenBufferReplacesTheSavedClassAndAddsNewOnes() async throws {
        let index = try await makeIndex(project: [
            stub("a.Repo", kind: .interfaceKind),
            stub("a.Saved", interfaces: ["a.Repo"]),
            stub("a.Dropped", interfaces: ["a.Repo"]),
        ])
        // The buffer no longer implements Repo in `Dropped`, and has a new class `Fresh`.
        await index.replaceOverlay(removing: [], adding: [stub("a.Dropped"), stub("a.Fresh", interfaces: ["a.Repo"])])
        var subtypes = await JavaInheritors.subtypes(of: "a.Repo", index: index)
        XCTAssertEqual(names(subtypes), ["a.Fresh", "a.Saved"])
        // Removing the buffer's classes brings the saved ones back.
        await index.replaceOverlay(removing: ["a.Dropped", "a.Fresh"], adding: [])
        subtypes = await JavaInheritors.subtypes(of: "a.Repo", index: index)
        XCTAssertEqual(names(subtypes), ["a.Dropped", "a.Saved"])
    }

    func testQueryScopeHidesAShard() async throws {
        let index = try await makeIndex(
            project: [stub("a.Repo", kind: .interfaceKind), stub("a.Impl", interfaces: ["a.Repo"])],
            shardPath: "/shards/test.idx"
        )
        let visible = await JavaIndex.$queryScope.withValue(["/shards/test.idx"]) {
            await JavaInheritors.subtypes(of: "a.Repo", index: index)
        }
        XCTAssertEqual(names(visible), ["a.Impl"])
        let hidden = await JavaIndex.$queryScope.withValue(["/shards/other.idx"]) {
            await JavaInheritors.subtypes(of: "a.Repo", index: index)
        }
        XCTAssertTrue(hidden.isEmpty)
    }

    func testCycleTerminates() async throws {
        let index = try await makeIndex(project: [
            stub("a.A", superclass: "a.B"),
            stub("a.B", superclass: "a.A"),
        ])
        let subtypes = await JavaInheritors.subtypes(of: "a.A", index: index)
        XCTAssertEqual(names(subtypes), ["a.B"])
    }

    func testSourcesChangeRebuildsTheTable() async throws {
        let index = try await makeIndex(project: [stub("a.Repo", kind: .interfaceKind), stub("a.One", interfaces: ["a.Repo"])])
        var subtypes = await JavaInheritors.subtypes(of: "a.Repo", index: index)
        XCTAssertEqual(names(subtypes), ["a.One"])
        await index.setSources([JavaIndex.Source(precedence: 1, reader: try reader([
            stub("a.Repo", kind: .interfaceKind), stub("a.Two", interfaces: ["a.Repo"]),
        ]))])
        subtypes = await JavaInheritors.subtypes(of: "a.Repo", index: index)
        XCTAssertEqual(names(subtypes), ["a.Two"])
    }
}
