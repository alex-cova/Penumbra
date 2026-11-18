import AppKit
import EditorIntelligence
import JavaIntelligence
import SpringIntelligence
import SwiftUI
import XCTest
@testable import Umbra

/// The Spring tool window, its graphs, gutter conversion and preferences, over a three-module application written to disk and
/// analysed by the real indexer. Layout and appearance are asserted by rendering; what cannot be shown here (interaction with a live
/// window server) is listed in docs/SPRING_INTEGRATION.md.
@MainActor
final class SpringToolWindowTests: XCTestCase {
    private var root: URL!
    private var workspace: IDEWorkspace!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spring-tw-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        let sources: [(String, String, String)] = [
            ("application", "App", """
            package com.acme.app;
            import org.springframework.boot.autoconfigure.SpringBootApplication;
            import org.springframework.stereotype.*;
            @SpringBootApplication(scanBasePackages = "com.acme") public class App {}
            @RestController_ class OrderController { OrderController(com.acme.services.OrderService orders) {} }
            """.replacingOccurrences(of: "@RestController_", with: "@Controller")),
            ("services", "OrderService", """
            package com.acme.services;
            import org.springframework.stereotype.Service;
            @Service public class OrderService { OrderService(com.acme.persistence.OrderRepository repo) {} }
            """),
            ("persistence", "OrderRepository", """
            package com.acme.persistence;
            import org.springframework.stereotype.Repository;
            @Repository public class OrderRepository {}
            """),
        ]
        for (module, name, text) in sources {
            let dir = root.appendingPathComponent("\(module)/src/main/java")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: dir.appendingPathComponent("\(name).java"), atomically: true, encoding: .utf8)
        }
        suite = "spring-tw-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        workspace = IDEWorkspace()
        workspace.bootstrap()
        workspace.project.setRoot(root)
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func model() -> JavaGradleProjectModel {
        let jar = URL(fileURLWithPath: "/h/.gradle/caches/modules-2/files-2.1/org.springframework/spring-context/6.1.2/x/spring-context-6.1.2.jar")
        func sub(_ m: String, _ deps: [String]) -> JavaGradleProjectModel.Subproject {
            .init(path: ":\(m)", directory: root.appendingPathComponent(m),
                  sourceSets: [.init(name: "main", sourceDirs: [root.appendingPathComponent("\(m)/src/main/java")], compileClasspathJars: [jar],
                                     projectDependencies: deps.map { .init(projectPath: ":\($0)", sourceSetName: "main") },
                                     runtimeProjectDependencies: deps.map { .init(projectPath: ":\($0)", sourceSetName: "main") })])
        }
        return JavaGradleProjectModel(formatVersion: 9, gradleVersion: "8", subprojects: [
            sub("application", ["services", "persistence"]), sub("services", ["persistence"]), sub("persistence", [])])
    }

    private func loadedStore(_ store: IDESpringStore? = nil) async -> IDESpringStore {
        let indexer = workspace.javaSupport.springIndexer
        await indexer.configure(model: model())
        await indexer.waitForScan()
        let s = store ?? workspace.springStore
        s.refresh(indexer: indexer)
        await s.waitForLoad()
        return s
    }

    private func render<V: View>(_ view: V, size: NSSize = NSSize(width: 320, height: 520)) throws -> (NSBitmapImageRep, NSView) {
        let host = NSHostingView(rootView: view.environment(workspace).preferredColorScheme(.dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let folder = ProcessInfo.processInfo.environment["UMBRA_VIEW_SNAPSHOTS"], let png = rep.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("spring-\(UUID().uuidString.prefix(6)).png"))
        }
        return (rep, host)
    }

    private func inkShare(_ rep: NSBitmapImageRep) -> Double {
        var counts: [UInt32: Int] = [:]
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                counts[UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255), default: 0] += 1
            }
        }
        let total = counts.values.reduce(0, +)
        return total == 0 ? 0 : 1 - Double(counts.values.max() ?? 0) / Double(total)
    }

    // MARK: Store

    func testSnapshotIsBuiltOffTheMainActorOnceAndKeptWhileTheIndexIsUnchanged() async throws {
        let store = await loadedStore()
        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(store.snapshot?.contexts.map(\.context.name), ["App"])
        XCTAssertEqual(Set(store.rows.map(\.name)), ["app", "orderController", "orderService", "orderRepository"])
        XCTAssertEqual(store.buildCount, 1)
        store.refresh(indexer: workspace.javaSupport.springIndexer)
        await store.waitForLoad()
        store.refresh(indexer: workspace.javaSupport.springIndexer)
        await store.waitForLoad()
        XCTAssertEqual(store.buildCount, 1, "opening the panel again does not rebuild what is still valid")
    }

    func testAnEditRebuildsOnlyWhenItChangesSpringFacts() async throws {
        let store = await loadedStore()
        let indexer = workspace.javaSupport.springIndexer
        let file = root.appendingPathComponent("services/src/main/java/OrderService.java")
        let original = try String(contentsOf: file, encoding: .utf8)
        await indexer.ingest(url: file, text: original.replacingOccurrences(of: "OrderService(com", with: "OrderService(/*x*/ com"))
        store.refresh(indexer: indexer); await store.waitForLoad()
        XCTAssertEqual(store.buildCount, 1, "a comment changes no Spring fact")
        await indexer.ingest(url: file, text: original.replacingOccurrences(of: "@Service", with: "@Service(\"renamed\")"))
        store.refresh(indexer: indexer); await store.waitForLoad()
        XCTAssertEqual(store.buildCount, 2)
        XCTAssertTrue(store.rows.contains { $0.name == "renamed" })
    }

    func testOnlyTheLatestOfTwoQuickRefreshesIsApplied() async throws {
        let indexer = workspace.javaSupport.springIndexer
        await indexer.configure(model: model()); await indexer.waitForScan()
        let store = workspace.springStore
        store.refresh(indexer: indexer)
        store.refresh(indexer: indexer)
        await store.waitForLoad()
        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(store.snapshot?.contexts.count, 1)
        XCTAssertEqual(store.buildCount, 1, "the first load was cancelled, not applied twice")
    }

    func testANonSpringProjectShowsTheHonestEmptyState() async throws {
        let store = workspace.springStore
        store.refresh(indexer: workspace.javaSupport.springIndexer)
        await store.waitForLoad()
        XCTAssertEqual(store.phase, .notSpring)
        XCTAssertNil(store.snapshot)
        let (rep, _) = try render(IDESpringPanel())
        XCTAssertGreaterThan(inkShare(rep), 0.001)
    }

    func testSectionApplicationAndSearchTextPersist() async throws {
        let store = IDESpringStore(defaults: defaults)
        store.section = .configuration
        store.selectedContextID = "com.acme.app.App"
        store.filter.text = "order"
        let again = IDESpringStore(defaults: defaults)
        XCTAssertEqual(again.section, .configuration)
        XCTAssertEqual(again.selectedContextID, "com.acme.app.App")
        XCTAssertEqual(again.filter.text, "order")
        XCTAssertEqual(IDESpringStore(defaults: UserDefaults(suiteName: "spring-fresh-\(UUID())")!).section, .beans, "default section")
    }

    func testRevealSelectsTheBeanShowsBeansAndClearsASearchThatWouldHideIt() async throws {
        let store = await loadedStore()
        store.section = .runtime
        store.filter.text = "zzz"
        let bean = try XCTUnwrap(store.currentContext?.context.model.beans.first { $0.name == "orderService" })
        store.reveal(bean: bean.id, contextID: store.currentContext?.id)
        XCTAssertEqual(store.section, .beans)
        XCTAssertEqual(store.selectedBeanID, bean.id)
        XCTAssertEqual(store.filter.text, "")
        XCTAssertTrue(store.rows.contains { $0.id == bean.id })
    }

    // MARK: Views

    func testEveryPanelSectionRendersContent() async throws {
        let store = await loadedStore()
        for section in IDESpringSection.allCases {
            store.section = section
            if section == .beans { store.selectedBeanID = store.rows.first { $0.name == "orderService" }?.id }
            let (rep, _) = try render(IDESpringPanel())
            XCTAssertGreaterThan(inkShare(rep), 0.003, "\(section.title) rendered blank")
        }
    }

    func testEmptyEndpointsAndRuntimeSaySoInsteadOfInventingData() async throws {
        let store = await loadedStore()
        XCTAssertTrue(store.endpointRows.isEmpty, "a controller without request mappings has no endpoints")
        let (endpoints, _) = try render(IDESpringEndpointsView(store: store))
        let (runtime, _) = try render(IDESpringRuntimeView())
        XCTAssertGreaterThan(inkShare(endpoints), 0.001)
        XCTAssertGreaterThan(inkShare(runtime), 0.001)
    }

    func testOpeningABeanNavigatesToItsSource() async throws {
        let store = await loadedStore()
        let bean = try XCTUnwrap(store.currentContext?.context.model.beans.first { $0.name == "orderRepository" })
        workspace.openSpringBean(bean.id, in: store)
        try await waitUntil { self.workspace.workbench.activePane.selectedDocument?.url?.standardizedFileURL == bean.location.url.standardizedFileURL }
        XCTAssertEqual(workspace.workbench.activePane.selectedDocument?.url?.standardizedFileURL, bean.location.url.standardizedFileURL)
    }

    // MARK: Marker commands and graphs

    func testRevealCommandShowsTheSpringTabAndSelectsTheBean() async throws {
        let store = await loadedStore()
        await workspace.javaSupport.mirrorSpringModules()
        XCTAssertTrue(workspace.hasSpringProject, "the tab is offered once a Spring module is detected")
        let bean = try XCTUnwrap(store.currentContext?.context.model.beans.first { $0.name == "orderService" })
        workspace.performMarkerCommand(CodeActionCommand(id: SpringMarkers.Command.reveal, arguments: [store.currentContext!.id, bean.id.raw]))
        await store.waitForLoad()
        XCTAssertEqual(workspace.selectedSidebarTab, .spring)
        XCTAssertEqual(store.selectedBeanID, bean.id)
        XCTAssertEqual(store.section, .beans)
    }

    func testGraphCommandsOpenDiagramTabsAndReuseTheSameOne() async throws {
        let store = await loadedStore()
        let ctx = try XCTUnwrap(store.currentContext)
        let bean = try XCTUnwrap(ctx.context.model.beans.first { $0.name == "orderService" })
        func diagramTabs() -> Int { workspace.workbench.panes.flatMap(\.documents).filter { $0.contentKind == .diagram }.count }
        workspace.performMarkerCommand(CodeActionCommand(id: SpringMarkers.Command.dependencyGraph, arguments: [ctx.id, bean.id.raw]))
        XCTAssertEqual(diagramTabs(), 1)
        workspace.performMarkerCommand(CodeActionCommand(id: SpringMarkers.Command.dependencyGraph, arguments: [ctx.id, bean.id.raw]))
        XCTAssertEqual(diagramTabs(), 1, "the same picture selects its tab")
        workspace.performMarkerCommand(CodeActionCommand(id: SpringMarkers.Command.contextGraph, arguments: [ctx.id]))
        XCTAssertEqual(diagramTabs(), 2)
        workspace.performMarkerCommand(CodeActionCommand(id: "not.a.spring.command", arguments: []))
        XCTAssertEqual(diagramTabs(), 2, "unknown commands do nothing")
    }

    func testDiagramRequestsRoundTripAndTheLoaderBuildsTheRightPicture() async throws {
        let store = await loadedStore()
        let ctx = try XCTUnwrap(store.currentContext)
        let bean = try XCTUnwrap(ctx.context.model.beans.first { $0.name == "orderService" })
        let request = IDESpringDiagramRequest.beanGraph(contextID: ctx.id, focus: bean.id, direction: .both, depth: 1)
        guard case .beans(let contextID, let focus, let direction, let depth)? = IDESpringDiagramRequest.parse(request) else { return XCTFail("parse") }
        XCTAssertEqual([contextID, focus?.raw, direction.rawValue], [ctx.id, bean.id.raw, "both"])
        XCTAssertEqual(depth, 1)
        let loadedOptional = await IDESpringDiagram.load(request, workspace: workspace)
        let loaded = try XCTUnwrap(loadedOptional)
        XCTAssertNil(loaded.failure)
        let titles = Set(loaded.document.nodes.map(\.title))
        XCTAssertEqual(titles, ["orderService", "orderController", "orderRepository"])
        let service = try XCTUnwrap(loaded.document.nodes.first { $0.title == "orderService" })
        XCTAssertEqual(service.fileURL?.lastPathComponent, "OrderService.java")
        XCTAssertNotNil(service.sourceByteRange, "double-click opens the declaration, not just the file")
        XCTAssertEqual(loaded.document.edges.count, 2)
        XCTAssertTrue(loaded.document.edges.allSatisfy { $0.kind == .springDependency })
        XCTAssertEqual(loaded.document.nodes.first { $0.title == "orderController" }?.kind, .springController)
        XCTAssertEqual(loaded.document.nodes.first { $0.title == "orderRepository" }?.kind, .springRepository)
        let againOptional = await IDESpringDiagram.load(request, workspace: workspace)
        let again = try XCTUnwrap(againOptional)
        XCTAssertEqual(again.document.nodes.map(\.id), loaded.document.nodes.map(\.id), "ids come from content: selection survives a reload")

        let contextRequest = IDESpringDiagramRequest.contextGraph(contextID: ctx.id)
        let contextOptional = await IDESpringDiagram.load(contextRequest, workspace: workspace)
        let context = try XCTUnwrap(contextOptional)
        XCTAssertTrue(context.document.nodes.contains { $0.kind == .springPackage && $0.title == "com.acme" })
        XCTAssertNotNil(context.notice, "what the context graph cannot know is stated")
        let unknown = await IDESpringDiagram.load(IDEDiagramRequest.gradleModules, workspace: workspace)
        XCTAssertNil(unknown, "requests that are not Spring's are left to others")
    }

    func testTheOpenedGraphLoadsLaysOutAndExportsToPNGAndSVG() async throws {
        let store = await loadedStore()
        let ctx = try XCTUnwrap(store.currentContext)
        workspace.openSpringBeanGraph(focus: nil, direction: .both, store: store, contextID: ctx.id)
        let document = try XCTUnwrap(workspace.workbench.panes.flatMap(\.documents).first { $0.contentKind == .diagram })
        let session = try XCTUnwrap(workspace.diagramSessionStore.session(for: document.id))
        try await waitUntil { !session.isLoading && !session.document.nodes.isEmpty }
        XCTAssertEqual(session.document.nodes.count, 4)
        XCTAssertTrue(session.document.nodes.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 }, "laid out off the main actor")
        XCTAssertEqual(Set(session.document.nodes.map(\.frame.origin)).count, 4, "boxes do not sit on top of each other")
        let svg = String(decoding: try IDEDiagramExporter.data(for: session, format: .svg), as: UTF8.self)
        XCTAssertTrue(svg.contains("<svg") && svg.contains("orderService") && svg.contains("orderRepository"))
        let png = try IDEDiagramExporter.data(for: session, format: .png)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "a real PNG")
    }

    /// Polls a condition with a timeout; it never sleeps unconditionally.
    private func waitUntil(timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for the condition") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Gutter conversion, preferences, real-registry markers

    func testStackedMarkersBecomeOneIconWithACountAndASpokenSymbol() {
        let spring = SpringMarkers.bean, inject = SpringMarkers.injection
        let stack = LineMarkerPresentation.stacks(from: [
            LineMarker(descriptor: inject, line: 5, anchorUTF16Offset: 9, tooltip: "injects x"),
            LineMarker(descriptor: spring, line: 5, anchorUTF16Offset: 3, tooltip: "bean y"),
        ])[0]
        let gutter = IDEEditorOverlayController.gutterMarker(id: 7, stack: stack)
        XCTAssertEqual(gutter.id, 7)
        XCTAssertEqual(gutter.line, 5)
        XCTAssertEqual(gutter.icon, .custom)
        XCTAssertEqual(gutter.symbol?.name, "leaf.fill")
        XCTAssertEqual(gutter.symbol?.tint, .success)
        XCTAssertEqual(gutter.symbol?.accessibilityLabel, "Spring bean")
        XCTAssertEqual(gutter.stackCount, 2)
        XCTAssertTrue(gutter.tooltip.contains("+1 more"))
        let plain = IDEEditorOverlayController.gutterMarker(id: 0, stack: LineMarkerPresentation.stacks(from: [LineMarker(kind: .overriding, line: 1, anchorUTF16Offset: 0, tooltip: "o")])[0])
        XCTAssertEqual(plain.icon, .overriding)
        XCTAssertNil(plain.symbol)
        XCTAssertEqual(plain.stackCount, 1)
    }

    func testDisabledMarkerKindsPersistAndAreListedForSettings() {
        let preferences = IDEPreferences.shared
        let before = preferences.disabledMarkerDescriptors
        defer { preferences.disabledMarkerDescriptors = before }
        preferences.disabledMarkerDescriptors = ["spring.injection"]
        XCTAssertEqual(preferences.disabledMarkerDescriptorIDs, ["spring.injection"])
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "com.umbra.editor.disabledMarkerDescriptors"), ["spring.injection"])
        XCTAssertEqual(Set(workspace.languages.lineMarkerDescriptors.map(\.id.rawValue)), Set(SpringMarkers.all.map(\.id.rawValue)))
        XCTAssertTrue(workspace.languages.lineMarkerDescriptors.allSatisfy { $0.group == "Spring" })
    }

    func testTheRealRegistryMergesJavaAndSpringMarkersAndRoutesMenusToSpring() async throws {
        let indexer = workspace.javaSupport.springIndexer
        await indexer.configure(model: model()); await indexer.waitForScan()
        let provider = try XCTUnwrap(workspace.languages.lineMarkers(for: "java"))
        XCTAssertTrue(provider is CompositeLineMarkerProvider, "Java's and Spring's services both provide markers")
        let file = root.appendingPathComponent("application/src/main/java/App.java").standardizedFileURL
        let source = try String(contentsOf: file, encoding: .utf8)
        let provided = await provider.lineMarkers(source: source, fileURL: file, kinds: Set(LineMarkerKind.allCases))
        let markers = try XCTUnwrap(provided)
        let controller = try XCTUnwrap(markers.first { $0.descriptor?.id == "spring.controller" })
        let menu = await provider.menu(for: controller, source: source, fileURL: file, documentID: DocumentID())
        XCTAssertTrue(menu.contains { $0.title == "Reveal in Spring Tool Window" }, "the composite routed the click to Spring: \(menu.map(\.title))")
    }

    func testKeyboardTraversalOfTheBeanListFollowsTheRowOrder() async throws {
        let store = await loadedStore()
        let rows = store.rows
        XCTAssertEqual(rows.map(\.name), rows.map(\.name).sorted { $0.lowercased() < $1.lowercased() }, "arrow keys walk a stable, alphabetical list")
        store.filter.text = "order"
        XCTAssertEqual(store.rows.map(\.name), ["orderController", "orderRepository", "orderService"])
        store.filter.text = "order repo"
        XCTAssertEqual(store.rows.map(\.name), ["orderRepository"])
    }
}
