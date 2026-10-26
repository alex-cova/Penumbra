import AppKit
import Foundation
import JavaIntelligence
import Penumbra
import XCTest
@testable import Umbra

/// Diagram tabs in the workspace: opening, reusing, loading, closing and not leaking.
@MainActor
final class IDEDiagramTabTests: XCTestCase {
    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private func diagramDocuments(_ workspace: IDEWorkspace) -> [WorkbenchDocument] {
        workspace.workbench.allDocuments().filter { $0.contentKind == .diagram }
    }

    private func isolatedSettings() -> IDEDiagramSettings {
        IDEDiagramSettings()
    }

    /// Settings changes made by a session under test land here, not in the developer's preferences.
    private func makeSession(_ request: IDEDiagramRequest) -> IDEDiagramSession {
        IDEDiagramSession(
            request: request,
            settings: isolatedSettings(),
            defaults: UserDefaults(suiteName: "umbra.diagram.tests.\(UUID().uuidString)") ?? .standard
        )
    }

    private func twoTypeGraph(extra: Int = 0) -> JavaClassGraph {
        var nodes: [JavaClassGraph.Node] = [
            .init(qualifiedName: "a.A", displayName: "A", packageName: "a", kind: .classKind),
            .init(qualifiedName: "a.B", displayName: "B", packageName: "a", kind: .classKind)
        ]
        for index in 0 ..< extra {
            nodes.append(.init(qualifiedName: "a.X\(index)", displayName: "X\(index)", packageName: "a", kind: .classKind))
        }
        return JavaClassGraph(nodes: nodes, edges: [.init(source: "a.A", destination: "a.B", kind: .inheritance)])
    }

    // MARK: - Workspace

    func testOpeningTheProjectDiagramReusesTheTabAndClosingFreesTheSession() async throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }

        workspace.openDiagram(.classes(.project))
        XCTAssertEqual(diagramDocuments(workspace).count, 1)
        let document = try XCTUnwrap(diagramDocuments(workspace).first)
        XCTAssertEqual(document.displayName, "Classes: Project")
        let session = try XCTUnwrap(workspace.diagramSessions[document.id])
        try await waitUntil { session.loadedAt != nil }

        workspace.openDiagram(.classes(.project))
        XCTAssertEqual(diagramDocuments(workspace).count, 1)

        workspace.closeTab(document.id)
        XCTAssertTrue(diagramDocuments(workspace).isEmpty)
        XCTAssertTrue(workspace.diagramSessions.isEmpty)
    }

    func testDifferentRequestsOpenDifferentTabs() {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        workspace.openDiagram(.classes(.project))
        workspace.openDiagram(.classes(.package("com.example")))
        workspace.openDiagram(.gradleModules)
        XCTAssertEqual(diagramDocuments(workspace).count, 3)
        XCTAssertEqual(
            Set(diagramDocuments(workspace).compactMap { workspace.diagramSessions[$0.id]?.request.id }).count, 3
        )
    }

    func testDiagramTabsAreNotRestored() {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        workspace.openDiagram(.gradleModules)
        let snapshot = EditorPaneSnapshot(pane: workspace.workbench.activePane)
        XCTAssertTrue(snapshot.documents.allSatisfy { $0.contentKind != .diagram })
    }

    func testTheTabRowCarriesTheDiagramIcon() throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        workspace.openDiagram(.gradleModules)
        let document = try XCTUnwrap(diagramDocuments(workspace).first)
        let row = workspace.tabsByPane[workspace.workbench.activePane.id]?.first { $0.id == document.id }
        XCTAssertEqual(row?.symbolName, IDEDiagramRequest.gradleModules.symbolName)
    }

    func testAGradleDiagramInAPlainFolderReportsItInsteadOfRunningGradle() async throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        workspace.openDiagram(.gradleLibraries(projectPath: ":", configuration: "runtimeClasspath"))
        let document = try XCTUnwrap(diagramDocuments(workspace).first)
        let session = try XCTUnwrap(workspace.diagramSessions[document.id])
        try await waitUntil {
            if case .failed = session.state { return true }
            return false
        }
        guard case let .failed(message) = session.state else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("not a Gradle project"), message)
        XCTAssertFalse(workspace.gradle.isBusy)
    }

    func testAClosedWorkspaceWithADiagramTabIsFreed() async throws {
        weak var weakWorkspace: IDEWorkspace?
        weak var weakSession: IDEDiagramSession?
        do {
            let workspace = IDEWorkspace()
            workspace.bootstrap()
            weakWorkspace = workspace
            workspace.openDiagram(.classes(.project))
            let document = try XCTUnwrap(diagramDocuments(workspace).first)
            weakSession = workspace.diagramSessions[document.id]
            try await waitUntil { weakSession?.loadedAt != nil }
            workspace.teardown()
        }
        for _ in 0 ..< 50 where weakWorkspace != nil || weakSession != nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(weakSession, "the diagram session outlived its workspace")
        XCTAssertNil(weakWorkspace, "the workspace with a diagram tab is still alive")
    }

    // MARK: - Session

    func testASessionLoadsLaysOutAndSummarises() async throws {
        let session = makeSession(.classes(.project))
        var received: (JavaClassGraphScope?, JavaClassGraphOptions)?
        session.load = { [graph = twoTypeGraph()] request, settings in
            received = (request.classScope, settings.classOptions)
            return IDEDiagramDocumentBuilder.load(from: graph, title: request.title)
        }
        session.reload()
        try await waitUntil { session.state == .ready }
        XCTAssertEqual(session.document.nodes.count, 2)
        XCTAssertEqual(session.summary, "2 types · 1 link")
        XCTAssertEqual(received?.0, .project)
        XCTAssertEqual(received?.1.showMembers, true)
        let a = try XCTUnwrap(session.document.nodes.first { $0.key == "a.A" })
        let b = try XCTUnwrap(session.document.nodes.first { $0.key == "a.B" })
        XCTAssertLessThan(b.frame.minY, a.frame.minY, "the supertype sits above its subtype")
    }

    func testAnEmptyGraphShowsTheEmptyState() async throws {
        let session = makeSession(.classes(.project))
        session.load = { request, _ in
            IDEDiagramDocumentBuilder.load(from: JavaClassGraph(), title: request.title)
        }
        session.reload()
        try await waitUntil { if case .empty = session.state { return true } else { return false } }
        XCTAssertTrue(session.document.nodes.isEmpty)
    }

    func testATruncatedGraphSaysSo() async throws {
        let session = makeSession(.classes(.project))
        var graph = twoTypeGraph()
        graph.truncated = true
        graph.omittedCount = 40
        session.load = { request, _ in
            IDEDiagramDocumentBuilder.load(from: graph, title: request.title)
        }
        session.reload()
        try await waitUntil { session.state == .ready }
        XCTAssertEqual(session.notice?.contains("40 more"), true)
    }

    func testAGradleFailureIsShownAndRetryRecovers() async throws {
        let session = makeSession(.gradleModules)
        var succeed = false
        session.load = { request, _ in
            if succeed {
                return IDEDiagramDocumentBuilder.load(
                    from: GradleDependencyGraph(
                        rootKey: "project::",
                        components: [.init(key: "project::", kind: .project, name: "root", projectPath: ":")]
                    ),
                    title: request.title,
                    emptyMessage: "This Gradle build has no project modules."
                )
            }
            return IDEDiagramLoad(document: .empty(title: request.title), failure: "not synced")
        }
        session.reload()
        try await waitUntil { if case .failed = session.state { return true } else { return false } }
        XCTAssertEqual(session.state, .failed("not synced"))

        succeed = true
        session.refresh()
        try await waitUntil { session.state == .ready }
        XCTAssertEqual(session.document.nodes.map(\.kind), [.project])
    }

    func testANewerLoadWinsOverASlowerOlderOne() async throws {
        let session = makeSession(.classes(.project))
        var calls = 0
        session.load = { [slow = twoTypeGraph(extra: 3), fast = twoTypeGraph()] request, _ in
            calls += 1
            let graph = calls == 1 ? slow : fast
            if calls == 1 { try? await Task.sleep(nanoseconds: 300_000_000) }
            return IDEDiagramDocumentBuilder.load(from: graph, title: request.title)
        }
        session.reload()
        try await Task.sleep(nanoseconds: 30_000_000)
        session.reload()
        try await waitUntil { session.state == .ready }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(session.document.nodes.count, 2, "the stale result replaced the newer one")
    }

    func testReloadingKeepsTheSelectionOfBoxesThatStillExist() async throws {
        let session = makeSession(.classes(.project))
        session.load = { [graph = twoTypeGraph()] request, _ in
            IDEDiagramDocumentBuilder.load(from: graph, title: request.title)
        }
        session.reload()
        try await waitUntil { session.state == .ready }
        let selected = try XCTUnwrap(session.document.nodes.first { $0.key == "a.A" }?.id)
        session.host.selection = [selected, UUID()]
        session.reload()
        try await waitUntil { session.state == .ready }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(session.host.selection, [selected])
        XCTAssertEqual(session.selectedNode?.key, "a.A")
    }

    func testChangingTheLayoutMovesTheBoxesWithoutReloading() async throws {
        let session = makeSession(.classes(.project))
        var loads = 0
        session.load = { [graph = twoTypeGraph(extra: 4)] request, _ in
            loads += 1
            return IDEDiagramDocumentBuilder.load(from: graph, title: request.title)
        }
        session.reload()
        try await waitUntil { session.state == .ready }
        let before = session.document.nodes.map(\.frame.origin)
        session.settings.layout = .grid
        XCTAssertNotEqual(session.document.nodes.map(\.frame.origin), before)
        XCTAssertEqual(loads, 1)
    }

    func testChangingWhatIsShownReloadsTheGraph() async throws {
        let session = makeSession(.classes(.project))
        var optionsSeen: [JavaClassGraphOptions] = []
        session.load = { [graph = twoTypeGraph()] request, settings in
            optionsSeen.append(settings.classOptions)
            return IDEDiagramDocumentBuilder.load(from: graph, title: request.title)
        }
        session.reload()
        try await waitUntil { session.state == .ready }
        session.settings.neighbourDepth = 2
        try await waitUntil { optionsSeen.count == 2 }
        XCTAssertEqual(optionsSeen.last?.neighbourDepth, 2)
    }

    func testSwitchingTheGradleConfigurationRetargetsTheRequest() async throws {
        let session = makeSession(.gradleLibraries(projectPath: ":app", configuration: "runtimeClasspath"))
        var configurations: [String] = []
        session.load = { request, settings in
            configurations.append(settings.libraryConfiguration)
            return IDEDiagramDocumentBuilder.load(
                from: GradleDependencyGraph(
                    rootKey: "project::app",
                    components: [.init(key: "project::app", kind: .project, name: "app", projectPath: ":app")]
                ),
                title: request.title,
                emptyMessage: ""
            )
        }
        session.reload()
        try await waitUntil { session.state == .ready }
        session.setLibraryConfiguration("compileClasspath")
        try await waitUntil { configurations.count == 2 }
        XCTAssertEqual(configurations, ["runtimeClasspath", "compileClasspath"])
        XCTAssertEqual(session.libraryConfiguration, "compileClasspath")
        XCTAssertEqual(session.request.id, "gradle:libraries::app")
    }

    func testExportsProduceAPNGAPDFAndAnSVG() async throws {
        let session = makeSession(.classes(.project))
        session.load = { [graph = twoTypeGraph(extra: 2)] request, _ in
            IDEDiagramDocumentBuilder.load(from: graph, title: request.title)
        }
        session.reload()
        try await waitUntil { session.state == .ready }

        let png = try IDEDiagramExporter.data(for: session, format: .png)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let pdf = try IDEDiagramExporter.data(for: session, format: .pdf)
        XCTAssertEqual(String(decoding: pdf.prefix(4), as: UTF8.self), "%PDF")
        let svg = String(decoding: try IDEDiagramExporter.data(for: session, format: .svg), as: UTF8.self)
        XCTAssertTrue(svg.contains("<svg"))
        XCTAssertTrue(svg.contains(">A</text>"))
        XCTAssertTrue(svg.contains("<polyline"))
    }

    func testExportingAnEmptyDiagramFails() {
        let session = makeSession(.classes(.project))
        XCTAssertThrowsError(try IDEDiagramExporter.data(for: session, format: .png))
    }

    func testExportFileNamesAreSafe() {
        XCTAssertEqual(IDEDiagramExporter.fileName(for: "Classes: Foo.java"), "Classes-Foo-java")
        XCTAssertEqual(IDEDiagramExporter.fileName(for: "///"), "diagram")
    }

    func testNodeActionsReachTheWorkspaceClosures() async throws {
        let session = makeSession(.classes(.project))
        let url = URL(fileURLWithPath: "/tmp/a/A.java")
        session.load = { request, _ in
            IDEDiagramDocumentBuilder.load(
                from: JavaClassGraph(nodes: [.init(
                    qualifiedName: "a.A", displayName: "A", packageName: "a", kind: .classKind, sourceURL: url
                )]),
                title: request.title
            )
        }
        var opened: URL?
        var diagram: (IDEDiagramRequest, Int)?
        session.openSource = { opened = $0 }
        session.openDiagram = { diagram = ($0, $1) }
        session.relatedTypeDiagram = { node in
            (IDEDiagramRequest.classes(.types([node.key])), 1)
        }
        session.reload()
        try await waitUntil { session.state == .ready }
        let node = try XCTUnwrap(session.document.nodes.first)
        session.open(node)
        session.showDiagramAround(node)
        XCTAssertEqual(opened, url)
        XCTAssertEqual(diagram?.0, .classes(.types(["a.A"])))
        XCTAssertEqual(diagram?.1, 1)
    }

    func testADependencyDiagramLoadsWithoutAJavaGraph() async throws {
        let request = IDEDiagramRequest(
            id: "npm:dependencies", title: "Dependencies", symbolName: "shippingbox", presentation: .dependencies
        )
        let session = makeSession(request)
        session.load = { request, _ in
            let document = IDEDiagramDocument(
                meta: .init(title: request.title),
                canvas: .init(),
                nodes: [IDEDiagramNode(key: "pkg:left-pad", kind: .library, title: "left-pad")],
                edges: []
            )
            return IDEDiagramLoad(document: document, emptyMessage: "No dependencies.")
        }
        session.reload()
        try await waitUntil { session.state == .ready }
        XCTAssertEqual(session.document.nodes.map(\.title), ["left-pad"])
        XCTAssertEqual(session.summary, "1 node · 0 links")
    }
}
