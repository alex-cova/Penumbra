import CoreGraphics
import DiagramKit
import Foundation
import JavaIntelligence
import XCTest
@testable import Umbra

/// The pure parts of the diagram tab: graph → document conversion, layout, edge markers, ids and settings.
final class IDEDiagramDocumentTests: XCTestCase {
    private func sampleClassGraph() -> JavaClassGraph {
        JavaClassGraph(
            nodes: [
                .init(qualifiedName: "app.Shape", displayName: "Shape", packageName: "app", kind: .interfaceKind, methods: ["+ area(): double"]),
                .init(qualifiedName: "app.Circle", displayName: "Circle", packageName: "app", kind: .classKind, attributes: ["- radius: double"], methods: ["+ area(): double"]),
                .init(qualifiedName: "app.Base", displayName: "Base", packageName: "app", kind: .classKind, isAbstract: true),
                .init(qualifiedName: "java.util.List", displayName: "List", packageName: "java.util", kind: .interfaceKind, isExternal: true)
            ],
            edges: [
                .init(source: "app.Circle", destination: "app.Shape", kind: .realization),
                .init(source: "app.Circle", destination: "app.Base", kind: .inheritance),
                .init(source: "app.Base", destination: "java.util.List", kind: .aggregation, label: "items")
            ]
        )
    }

    // MARK: - Class graph

    func testClassGraphBecomesBoxesWithTheRightKinds() {
        let document = IDEDiagramDocumentBuilder.document(from: sampleClassGraph(), title: "Classes")
        XCTAssertEqual(document.nodes.count, 4)
        let kinds = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.key, $0.kind) })
        XCTAssertEqual(kinds["app.Shape"], .interfaceType)
        XCTAssertEqual(kinds["app.Circle"], .classType)
        XCTAssertEqual(kinds["app.Base"], .abstractClass)
        XCTAssertEqual(kinds["java.util.List"], .externalType)
        let shape = document.nodes.first { $0.key == "app.Shape" }
        XCTAssertEqual(shape?.subtitle, "«interface»")
        let external = document.nodes.first { $0.key == "java.util.List" }
        XCTAssertEqual(external?.subtitle, "java.util")
    }

    func testClassEdgesKeepTheirKindAndFieldLabel() throws {
        let document = IDEDiagramDocumentBuilder.document(from: sampleClassGraph(), title: "Classes")
        XCTAssertEqual(document.edges.count, 3)
        let aggregation = try XCTUnwrap(document.edges.first { $0.kind == .aggregation })
        XCTAssertEqual(aggregation.label, "items")
        XCTAssertEqual(document.node(id: aggregation.sourceID)?.key, "app.Base")
        XCTAssertEqual(document.node(id: aggregation.destinationID)?.key, "java.util.List")
    }

    func testEdgesToMissingNodesAreDropped() {
        var graph = sampleClassGraph()
        graph.edges.append(.init(source: "app.Circle", destination: "nowhere.Gone", kind: .dependency))
        let document = IDEDiagramDocumentBuilder.document(from: graph, title: "x")
        XCTAssertEqual(document.edges.count, 3)
    }

    func testBuildingTheSameGraphTwiceKeepsEveryIdentity() {
        let first = IDEDiagramDocumentBuilder.document(from: sampleClassGraph(), title: "x")
        let second = IDEDiagramDocumentBuilder.document(from: sampleClassGraph(), title: "x")
        XCTAssertEqual(first.nodes.map(\.id), second.nodes.map(\.id))
        XCTAssertEqual(first.edges.map(\.id), second.edges.map(\.id))
        XCTAssertEqual(Set(first.nodes.map(\.id)).count, first.nodes.count)
    }

    func testBoxesGrowWithTheirMembers() throws {
        let document = IDEDiagramDocumentBuilder.document(from: sampleClassGraph(), title: "x")
        let circle = try XCTUnwrap(document.nodes.first { $0.key == "app.Circle" })
        let base = try XCTUnwrap(document.nodes.first { $0.key == "app.Base" })
        XCTAssertGreaterThan(circle.frame.height, base.frame.height)
        XCTAssertGreaterThanOrEqual(circle.frame.width, IDEDiagramNodeMetrics.minimumWidth)
    }

    func testLongMemberListsAreCappedWithAMoreLine() {
        let lines = (0..<30).map { "+ m\($0)()" }
        let shown = IDEDiagramNodeMetrics.displayed(lines)
        XCTAssertEqual(shown.count, IDEDiagramNodeMetrics.maximumLines + 1)
        XCTAssertEqual(shown.last, "… 16 more")
        XCTAssertEqual(IDEDiagramNodeMetrics.displayed(["+ a()"]), ["+ a()"])
    }

    // MARK: - Gradle graph

    func testGradleGraphMapsProjectsLibrariesAndReplacements() throws {
        let graph = GradleDependencyGraph(
            project: ":app",
            configuration: "runtimeClasspath",
            rootKey: "project::app",
            components: [
                .init(key: "project::app", kind: .project, name: "app", projectPath: ":app"),
                .init(key: "project::core", kind: .project, name: "core", projectPath: ":core"),
                .init(key: "org.slf4j:slf4j-api", kind: .module, group: "org.slf4j", name: "slf4j-api", version: "2.0.9"),
                .init(key: "com.google.guava:guava", kind: .module, group: "com.google.guava", name: "guava", version: "33.0", conflictResolved: true),
                .init(key: "unresolved:x", kind: .unresolved, name: "x", message: "not found")
            ],
            edges: [
                .init(from: "project::app", to: "project::core", runtimeOnly: true),
                .init(from: "project::app", to: "org.slf4j:slf4j-api"),
                .init(from: "project::core", to: "com.google.guava:guava", requestedVersion: "31.0"),
                .init(from: "project::core", to: "unresolved:x", constraint: true)
            ]
        )
        let document = IDEDiagramDocumentBuilder.document(from: graph, title: "Deps")
        let kinds = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.key, $0.kind) })
        XCTAssertEqual(kinds["project::app"], .project)
        XCTAssertEqual(kinds["org.slf4j:slf4j-api"], .library)
        XCTAssertEqual(kinds["com.google.guava:guava"], .replacedLibrary)
        XCTAssertEqual(kinds["unresolved:x"], .unresolvedLibrary)

        let library = try XCTUnwrap(document.nodes.first { $0.key == "org.slf4j:slf4j-api" })
        XCTAssertEqual(library.subtitle, "org.slf4j · 2.0.9")

        func edge(_ to: String) -> IDEDiagramEdge? {
            document.edges.first { document.node(id: $0.destinationID)?.key == to }
        }
        XCTAssertEqual(edge("project::core")?.kind, .projectDependency)
        XCTAssertEqual(edge("project::core")?.label, "runtime")
        XCTAssertEqual(edge("org.slf4j:slf4j-api")?.kind, .libraryDependency)
        XCTAssertEqual(edge("com.google.guava:guava")?.kind, .replaced)
        XCTAssertEqual(edge("com.google.guava:guava")?.label, "asked 31.0")
        XCTAssertEqual(edge("unresolved:x")?.label, "constraint")
    }

    // MARK: - Layout

    func testHierarchicalLayoutPutsSupertypesAboveSubtypes() throws {
        let document = IDEDiagramDocumentBuilder.document(from: sampleClassGraph(), title: "x")
        let laidOut = IDEDiagramLayoutEngine.laidOut(document, kind: .hierarchical)
        let circle = try XCTUnwrap(laidOut.nodes.first { $0.key == "app.Circle" })
        let shape = try XCTUnwrap(laidOut.nodes.first { $0.key == "app.Shape" })
        let base = try XCTUnwrap(laidOut.nodes.first { $0.key == "app.Base" })
        XCTAssertLessThan(shape.frame.minY, circle.frame.minY)
        XCTAssertLessThan(base.frame.minY, circle.frame.minY)
    }

    func testEveryLayoutPlacesEveryBoxWithoutOverlap() {
        let document = IDEDiagramDocumentBuilder.document(from: sampleClassGraph(), title: "x")
        for kind in IDEDiagramLayoutKind.allCases {
            let laidOut = IDEDiagramLayoutEngine.laidOut(document, kind: kind)
            XCTAssertEqual(laidOut.nodes.count, document.nodes.count, kind.rawValue)
            for (index, node) in laidOut.nodes.enumerated() {
                for other in laidOut.nodes[(index + 1)...] {
                    XCTAssertFalse(node.frame.intersects(other.frame), "\(kind.rawValue): \(node.key) overlaps \(other.key)")
                }
            }
        }
    }

    // MARK: - Edge markers

    private let horizontal = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]

    func testInheritanceDrawsAHollowTriangleAtTheSupertype() throws {
        let geometry = IDEDiagramEdgeMarkers.geometry(kind: .inheritance, route: horizontal, size: 10)
        let shape = try XCTUnwrap(geometry.shapes.first)
        XCTAssertEqual(shape.fill, .background)
        XCTAssertTrue(shape.closed)
        XCTAssertEqual(shape.points.count, 3)
        XCTAssertEqual(shape.points[0], CGPoint(x: 100, y: 0), "the tip sits on the route's end")
        let base = try XCTUnwrap(geometry.line.last)
        XCTAssertEqual(base.x, 87, accuracy: 0.001, "the line stops at the triangle's base")
    }

    func testRealizationUsesTheSameMarkerAsInheritance() {
        let inheritance = IDEDiagramEdgeMarkers.geometry(kind: .inheritance, route: horizontal, size: 10)
        let realization = IDEDiagramEdgeMarkers.geometry(kind: .realization, route: horizontal, size: 10)
        XCTAssertEqual(inheritance, realization)
        XCTAssertTrue(IDEDiagramEdgeKind.realization.isDashed)
        XCTAssertFalse(IDEDiagramEdgeKind.inheritance.isDashed)
    }

    func testAggregationPutsADiamondAtTheOwner() throws {
        let geometry = IDEDiagramEdgeMarkers.geometry(kind: .aggregation, route: horizontal, size: 10)
        let diamond = try XCTUnwrap(geometry.shapes.first)
        XCTAssertEqual(diamond.points.count, 4)
        XCTAssertEqual(diamond.points[0], CGPoint(x: 0, y: 0))
        let start = try XCTUnwrap(geometry.line.first)
        XCTAssertGreaterThan(start.x, 10, "the line starts at the diamond's far corner")
        XCTAssertEqual(geometry.line.last, CGPoint(x: 100, y: 0))
    }

    func testAssociationIsAnOpenArrowAndKeepsTheWholeLine() throws {
        let geometry = IDEDiagramEdgeMarkers.geometry(kind: .association, route: horizontal, size: 10)
        let arrow = try XCTUnwrap(geometry.shapes.first)
        XCTAssertFalse(arrow.closed)
        XCTAssertEqual(arrow.fill, .none)
        XCTAssertEqual(arrow.points[1], CGPoint(x: 100, y: 0))
        XCTAssertEqual(geometry.line, horizontal)
    }

    func testGradleDependenciesGetAFilledArrow() throws {
        for kind in [IDEDiagramEdgeKind.projectDependency, .libraryDependency, .replaced] {
            let geometry = IDEDiagramEdgeMarkers.geometry(kind: kind, route: horizontal, size: 10)
            XCTAssertEqual(geometry.shapes.first?.fill, .stroke, "\(kind)")
        }
    }

    func testAMarkerNeverReversesAShortSegment() throws {
        let tiny = [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0)]
        let geometry = IDEDiagramEdgeMarkers.geometry(kind: .inheritance, route: tiny, size: 10)
        let end = try XCTUnwrap(geometry.line.last)
        XCTAssertGreaterThanOrEqual(end.x, 0)
        XCTAssertLessThanOrEqual(end.x, 4)
    }

    func testDegenerateRoutesProduceNoMarker() {
        XCTAssertTrue(IDEDiagramEdgeMarkers.geometry(kind: .inheritance, route: [CGPoint(x: 1, y: 1)], size: 10).shapes.isEmpty)
        let same = [CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5)]
        XCTAssertTrue(IDEDiagramEdgeMarkers.geometry(kind: .association, route: same, size: 10).shapes.isEmpty)
    }

    func testLabelsSitHalfWayAlongTheRoute() {
        let route = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)]
        let middle = IDEDiagramSceneBuilder.midpoint(of: route)
        XCTAssertEqual(middle.x, 100, accuracy: 0.001)
        XCTAssertEqual(middle.y, 0, accuracy: 0.001)
        XCTAssertEqual(IDEDiagramSceneBuilder.midpoint(of: horizontal), CGPoint(x: 50, y: 0))
    }

    // MARK: - Requests, settings, persistence

    func testRequestsForTheSameThingShareATab() {
        let file = URL(fileURLWithPath: "/tmp/p/A.java")
        XCTAssertEqual(IDEDiagramRequest.classes(.file(file)).id, IDEDiagramRequest.classes(.file(file)).id)
        XCTAssertNotEqual(IDEDiagramRequest.classes(.file(file)).id, IDEDiagramRequest.classes(.project).id)
        XCTAssertEqual(
            IDEDiagramRequest.gradleLibraries(projectPath: ":app", configuration: "runtimeClasspath").id,
            IDEDiagramRequest.gradleLibraries(projectPath: ":app", configuration: "compileClasspath").id
        )
        XCTAssertNotEqual(
            IDEDiagramRequest.gradleLibraries(projectPath: ":app", configuration: "x").id,
            IDEDiagramRequest.gradleLibraries(projectPath: ":core", configuration: "x").id
        )
        XCTAssertEqual(IDEDiagramRequest.classes(.types(["b.B", "a.A"])).id, IDEDiagramRequest.classes(.types(["a.A", "b.B"])).id)
    }

    func testSettingsSurviveARoundTripAndClampTheDepth() throws {
        let suite = "umbra.diagram.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(IDEDiagramSettings.load(from: defaults), IDEDiagramSettings())

        var settings = IDEDiagramSettings()
        settings.layout = .radial
        settings.routing = .bezier
        settings.showMembers = false
        settings.showExternalTypes = true
        settings.neighbourDepth = 2
        settings.libraryConfiguration = "compileClasspath"
        settings.save(to: defaults)
        XCTAssertEqual(IDEDiagramSettings.load(from: defaults), settings)

        defaults.set(9, forKey: "umbra.diagram.depth")
        XCTAssertEqual(IDEDiagramSettings.load(from: defaults).neighbourDepth, 2)
        XCTAssertEqual(settings.classOptions.neighbourDepth, 2)
        XCTAssertFalse(settings.classOptions.showMembers)
    }

    func testADocumentSurvivesCodable() throws {
        let document = IDEDiagramDocumentBuilder.document(from: sampleClassGraph(), title: "Classes")
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(IDEDiagramDocument.self, from: data)
        XCTAssertEqual(decoded, document)
    }

    func testRoutesAreComputedForEveryEdgeAndFingerprintTracksMovement() throws {
        var document = IDEDiagramLayoutEngine.laidOut(
            IDEDiagramDocumentBuilder.document(from: sampleClassGraph(), title: "x"), kind: .hierarchical
        )
        let routes = IDEDiagramRouting.computeRoutes(for: document)
        XCTAssertEqual(routes.count, document.edges.count)
        XCTAssertTrue(routes.allSatisfy { $0.route.points.count >= 2 })

        let before = IDEDiagramRouting.geometryFingerprint(for: document)
        XCTAssertEqual(before, IDEDiagramRouting.geometryFingerprint(for: document))
        document.nodes[0].frame.origin.x += 40
        XCTAssertNotEqual(before, IDEDiagramRouting.geometryFingerprint(for: document))
    }
}
