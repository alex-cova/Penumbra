import XCTest
@testable import JavaIntelligence

final class JavaClassGraphBuilderTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("java-class-graph-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private let shop: [String: String] = [
        "app/Entity.java": "package app; public interface Entity { long id(); }",
        "app/Auditable.java": "package app; public interface Auditable { }",
        "app/Base.java": "package app; public abstract class Base implements Entity { protected long id; public long id() { return id; } }",
        "app/Customer.java": """
        package app;
        import java.util.List;
        public class Customer extends Base implements Auditable {
            private String name;
            private List<Order> orders;
            private Address home;
            public Order latest() { return null; }
            private void secret() { }
        }
        """,
        "app/Order.java": """
        package app;
        public class Order extends Base {
            private Customer owner;
            private Item[] items;
            public void ship(Carrier carrier) throws ShipException { }
        }
        """,
        "app/Item.java": "package app; public class Item { }",
        "app/Address.java": "package app; public class Address { }",
        "app/Carrier.java": "package app; public interface Carrier { }",
        "app/ShipException.java": "package app; public class ShipException extends Exception { }",
        "other/Unrelated.java": "package other; public class Unrelated { }"
    ]

    // MARK: - Relations

    func testFileScopeShowsInheritanceRealizationAssociationAggregationAndDependency() async throws {
        let (builder, files) = try await makeBuilder(sources: shop)
        let graph = await builder.build(scope: .file(files["app/Customer.java"]!))

        XCTAssertEqual(
            graph.nodes.map(\.qualifiedName), ["app.Auditable", "app.Base", "app.Customer", "app.Entity"],
            "Depth 0 still draws the whole supertype chain, but not field or method types"
        )
        XCTAssertEqual(kind(graph, "app.Customer", "app.Base"), .inheritance)
        XCTAssertEqual(kind(graph, "app.Customer", "app.Auditable"), .realization)
        XCTAssertEqual(kind(graph, "app.Base", "app.Entity"), .realization)
        XCTAssertNil(kind(graph, "app.Customer", "app.Order"))

        let wide = await builder.build(scope: .file(files["app/Customer.java"]!), options: .init(neighbourDepth: 1))
        let names = Set(wide.nodes.map(\.qualifiedName))
        XCTAssertTrue(names.isSuperset(of: ["app.Customer", "app.Base", "app.Auditable", "app.Order", "app.Address"]))
        XCTAssertFalse(names.contains("other.Unrelated"))

        XCTAssertEqual(kind(wide, "app.Customer", "app.Base"), .inheritance)
        XCTAssertEqual(kind(wide, "app.Customer", "app.Auditable"), .realization)
        XCTAssertEqual(kind(wide, "app.Customer", "app.Address"), .association)
        XCTAssertEqual(kind(wide, "app.Customer", "app.Order"), .aggregation, "List<Order> is aggregation, with the field as its label")
        XCTAssertEqual(wide.edges.first { $0.destination == "app.Order" && $0.source == "app.Customer" }?.label, "orders")
        XCTAssertEqual(kind(wide, "app.Order", "app.Customer"), .association)
        XCTAssertEqual(kind(wide, "app.Order", "app.Item"), nil, "Item is two hops from Customer")

        let deep = await builder.build(scope: .file(files["app/Customer.java"]!), options: .init(neighbourDepth: 2))
        XCTAssertEqual(kind(deep, "app.Order", "app.Item"), .aggregation, "An array field is aggregation")
        XCTAssertEqual(kind(deep, "app.Order", "app.Carrier"), .dependency)
    }

    func testSubtypesAndImplementersAreShownForAClass() async throws {
        let (builder, files) = try await makeBuilder(sources: shop)
        let base = await builder.build(scope: .file(files["app/Base.java"]!))
        XCTAssertEqual(
            Set(base.nodes.map(\.qualifiedName)), ["app.Base", "app.Entity", "app.Customer", "app.Order"],
            "The interface above, the subclasses below"
        )
        XCTAssertEqual(kind(base, "app.Customer", "app.Base"), .inheritance)
        XCTAssertEqual(kind(base, "app.Order", "app.Base"), .inheritance)

        let entity = await builder.build(scope: .types(["app.Entity"]))
        XCTAssertEqual(
            Set(entity.nodes.map(\.qualifiedName)), ["app.Entity", "app.Base", "app.Customer", "app.Order"],
            "Implementers are followed down through their own subclasses"
        )
        XCTAssertEqual(kind(entity, "app.Base", "app.Entity"), .realization)
    }

    func testMethodTypesAreDependenciesAndFieldsWinOverThem() async throws {
        let (builder, _) = try await makeBuilder(sources: shop)
        let graph = await builder.build(scope: .types(["app.Order", "app.Carrier", "app.ShipException", "app.Customer"]))
        XCTAssertEqual(kind(graph, "app.Order", "app.Carrier"), .dependency)
        XCTAssertEqual(kind(graph, "app.Order", "app.ShipException"), .dependency)
        XCTAssertEqual(kind(graph, "app.Customer", "app.Order"), .aggregation, "The field relation outranks latest()'s return type")
    }

    func testInterfaceExtendingInterfaceIsInheritance() async throws {
        let (builder, _) = try await makeBuilder(sources: [
            "p/A.java": "package p; interface A { }",
            "p/B.java": "package p; interface B extends A { }"
        ])
        let graph = await builder.build(scope: .project)
        XCTAssertEqual(kind(graph, "p.B", "p.A"), .inheritance)
    }

    func testResolvesSupertypesThroughTheDeclaringFilesImports() async throws {
        let (builder, _) = try await makeBuilder(sources: [
            "a/Animal.java": "package a; public class Animal { }",
            "b/Dog.java": "package b; import a.Animal; public class Dog extends Animal { }"
        ])
        let graph = await builder.build(scope: .project)
        XCTAssertEqual(kind(graph, "b.Dog", "a.Animal"), .inheritance)
    }

    // MARK: - Scopes

    func testPackageScopeKeepsOnlyThatPackage() async throws {
        let (builder, _) = try await makeBuilder(sources: shop)
        let graph = await builder.build(scope: .package("other"))
        XCTAssertEqual(graph.nodes.map(\.qualifiedName), ["other.Unrelated"])

        let app = await builder.build(scope: .package("app"))
        XCTAssertFalse(app.nodes.map(\.qualifiedName).contains("other.Unrelated"))
        XCTAssertTrue(app.nodes.map(\.qualifiedName).contains("app.Customer"))
    }

    func testDepthTwoReachesTypesTwoHopsAway() async throws {
        let (builder, _) = try await makeBuilder(sources: shop)
        let one = await builder.build(scope: .types(["app.Customer"]), options: .init(neighbourDepth: 1))
        let two = await builder.build(scope: .types(["app.Customer"]), options: .init(neighbourDepth: 2))
        XCTAssertFalse(one.nodes.map(\.qualifiedName).contains("app.Carrier"))
        XCTAssertTrue(two.nodes.map(\.qualifiedName).contains("app.Carrier"))
    }

    func testNeighboursIncludeTypesThatPointAtTheScope() async throws {
        let (builder, _) = try await makeBuilder(sources: shop)
        let graph = await builder.build(scope: .types(["app.Address"]), options: .init(neighbourDepth: 1))
        XCTAssertEqual(Set(graph.nodes.map(\.qualifiedName)), ["app.Address", "app.Customer"])
    }

    func testFileScopeReadsUnsavedBufferText() async throws {
        let (_, files) = try await makeBuilder(sources: shop)
        let url = files["app/Item.java"]!
        let index = JavaIndex()
        let builder = JavaClassGraphBuilder(index: index, openBuffer: { requested in
            requested.standardizedFileURL == url.standardizedFileURL ? "package app; public class Item { int weight; }" : nil
        })
        let graph = await builder.build(scope: .file(url))
        XCTAssertEqual(graph.nodes.first?.attributes, ["~ weight: int"])
    }

    // MARK: - Members and options

    func testMembersUseUMLVisibilityAndHidePrivateByDefault() async throws {
        let (builder, _) = try await makeBuilder(sources: shop)
        let graph = await builder.build(scope: .types(["app.Customer"]))
        let customer = try XCTUnwrap(graph.nodes.first { $0.qualifiedName == "app.Customer" })
        XCTAssertEqual(customer.attributes, [])
        XCTAssertTrue(customer.methods.contains("+ latest(): Order"))
        XCTAssertFalse(customer.methods.contains { $0.contains("secret") })

        let withPrivate = await builder.build(scope: .types(["app.Customer"]), options: .init(showPrivateMembers: true))
        let node = try XCTUnwrap(withPrivate.nodes.first { $0.qualifiedName == "app.Customer" })
        XCTAssertTrue(node.attributes.contains("- orders: List<Order>"))
        XCTAssertTrue(node.attributes.contains("- name: String"))
        XCTAssertTrue(node.methods.contains("- secret(): void"))

        let bare = await builder.build(scope: .types(["app.Customer"]), options: .init(showMembers: false))
        XCTAssertTrue(bare.nodes.allSatisfy { $0.attributes.isEmpty && $0.methods.isEmpty })
    }

    func testKindsAndAbstractFlag() async throws {
        let (builder, _) = try await makeBuilder(sources: shop)
        let graph = await builder.build(scope: .types(["app.Base", "app.Entity", "app.Customer"]))
        let byName = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.qualifiedName, $0) })
        XCTAssertEqual(byName["app.Entity"]?.kind, .interfaceKind)
        XCTAssertEqual(byName["app.Base"]?.isAbstract, true)
        XCTAssertEqual(byName["app.Customer"]?.isAbstract, false)
        XCTAssertEqual(byName["app.Customer"]?.sourceURL?.lastPathComponent, "Customer.java")
    }

    func testLibraryTypesOutsideTheHierarchyAreHiddenUnlessAsked() async throws {
        let external = JavaClassStub(
            binaryName: "lib.Exception", qualifiedName: "lib.Exception", simpleName: "Exception", packageName: "lib",
            kind: .classKind, modifiers: [.publicFlag], origin: .jar(URL(fileURLWithPath: "/tmp/lib.jar"))
        )
        let (builder, _) = try await makeBuilder(
            sources: ["p/Failure.java": "package p; public class Failure extends lib.Exception { }"],
            extraStubs: [external]
        )
        let hidden = await builder.build(scope: .project)
        XCTAssertEqual(
            hidden.nodes.map(\.qualifiedName), ["p.Failure", "lib.Exception"],
            "A library supertype is part of the hierarchy, so it is drawn even without external types"
        )
        XCTAssertEqual(kind(hidden, "p.Failure", "lib.Exception"), .inheritance)

        let shown = await builder.build(scope: .project, options: .init(showExternalTypes: true))
        let lib = try XCTUnwrap(shown.nodes.first { $0.qualifiedName == "lib.Exception" })
        XCTAssertTrue(lib.isExternal)
        XCTAssertEqual(kind(shown, "p.Failure", "lib.Exception"), .inheritance)
    }

    func testNodeLimitTruncatesAndReportsHowManyWereLeftOut() async throws {
        var sources: [String: String] = [:]
        for number in 0..<12 { sources["p/T\(number).java"] = "package p; class T\(number) { }" }
        let (builder, _) = try await makeBuilder(sources: sources)
        let graph = await builder.build(scope: .project, options: .init(nodeLimit: 5))
        XCTAssertEqual(graph.nodes.count, 5)
        XCTAssertTrue(graph.truncated)
        XCTAssertEqual(graph.omittedCount, 7)
    }

    func testUnknownScopeIsEmpty() async throws {
        let (builder, _) = try await makeBuilder(sources: shop)
        let graph = await builder.build(scope: .types(["nope.Missing"]))
        XCTAssertTrue(graph.isEmpty)
        XCTAssertFalse(graph.truncated)
    }

    func testOutputIsDeterministic() async throws {
        let (builder, _) = try await makeBuilder(sources: shop)
        let first = await builder.build(scope: .project, options: .init(showPrivateMembers: true))
        let second = await builder.build(scope: .project, options: .init(showPrivateMembers: true))
        XCTAssertEqual(first, second)
    }

    // MARK: - Helpers

    private func kind(_ graph: JavaClassGraph, _ source: String, _ destination: String) -> JavaClassGraph.EdgeKind? {
        graph.edges.first { $0.source == source && $0.destination == destination }?.kind
    }

    private func makeBuilder(
        sources: [String: String], extraStubs: [JavaClassStub] = []
    ) async throws -> (JavaClassGraphBuilder, [String: URL]) {
        var stubs: [JavaClassStub] = []
        var files: [String: URL] = [:]
        for (path, source) in sources.sorted(by: { $0.key < $1.key }) {
            let url = scratch.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try source.write(to: url, atomically: true, encoding: .utf8)
            files[path] = url
            stubs += JavaSourceStubBuilder.build(source: source, url: url).classes
        }
        let index = JavaIndex()
        var shards: [JavaIndex.Source] = [.init(precedence: 1, reader: try writeShard(stubs))]
        if !extraStubs.isEmpty { shards.append(.init(precedence: 2, reader: try writeShard(extraStubs))) }
        await index.setSources(shards)
        return (JavaClassGraphBuilder(index: index), files)
    }

    private func writeShard(_ stubs: [JavaClassStub]) throws -> JavaIndexShardReader {
        let url = scratch.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        return try JavaIndexShardReader(url: url)
    }
}
