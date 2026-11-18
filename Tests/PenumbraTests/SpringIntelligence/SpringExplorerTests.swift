import XCTest
import EditorIntelligence
import JavaIntelligence
@testable import SpringIntelligence

/// The tool window's data layer (bean index, inspector, graphs) and the gutter markers, over a representative three-module application:
///
///     application  → OrderController ─▶ OrderService ─▶ PaymentGateway (interface; Stripe @Primary, Paypal under @Profile("paypal"))
///                                                    └▶ OrderRepository (persistence)
///     plus a constructor cycle (Ping ⇄ Pong), a missing bean, and a configuration with @Bean methods and an @Import.
final class SpringExplorerTests: XCTestCase {
    /// The workspace is written to disk so navigation targets can be read back, as they are in the editor.
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spring-explorer-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        for (m, n, src) in files {
            let u = url(m, n)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try src.write(to: u, atomically: true, encoding: .utf8)
        }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func module(_ path: String, deps: Set<String> = []) -> SpringModuleInfo {
        let dir = root.appendingPathComponent(String(path.dropFirst()))
        return SpringModuleInfo(
            projectPath: path, directory: dir, frameworkVersion: "6.1.0", bootVersion: "3.2.0",
            features: [.framework, .boot], sourceRoots: [dir.appendingPathComponent("src/main/java")], resourceRoots: [],
            classpathJars: [], outputDirs: [], dependencyPaths: deps, isSpring: true)
    }
    private func url(_ m: String, _ f: String) -> URL { root.appendingPathComponent("\(m.dropFirst())/src/main/java/\(f).java") }

    private let files: [(String, String, String)] = [
        (":application", "App", """
        package com.acme.app;
        import org.springframework.boot.autoconfigure.SpringBootApplication;
        import org.springframework.stereotype.*;
        import org.springframework.web.bind.annotation.RestController;
        import org.springframework.context.annotation.*;
        @SpringBootApplication(scanBasePackages = "com.acme") @Import(com.acme.app.ExtraConfig.class) public class App {}
        @RestController class OrderController { OrderController(com.acme.services.OrderService orders) {} }
        @Component class Ping { Ping(Pong pong) {} }
        @Component class Pong { Pong(Ping ping) {} }
        @Component class Lonely { Lonely(com.acme.services.Unprovided missing) {} }
        """),
        (":application", "ExtraConfig", """
        package com.acme.app;
        import org.springframework.context.annotation.*;
        @Configuration class ExtraConfig {
            @Bean com.acme.services.Clock clock() { return null; }
            @Bean @Profile("paypal") String paypalMarker() { return ""; }
        }
        """),
        (":services", "OrderService", """
        package com.acme.services;
        import org.springframework.stereotype.Service;
        import org.springframework.beans.factory.annotation.Autowired;
        @Service public class OrderService {
            @Autowired PaymentGateway gateway;
            OrderService(com.acme.persistence.OrderRepository repository, Clock clock) {}
        }
        interface Clockish {}
        public class Clock {}
        public interface Unprovided {}
        """),
        (":services", "Gateways", """
        package com.acme.services;
        import org.springframework.stereotype.Service;
        import org.springframework.context.annotation.*;
        public interface PaymentGateway {}
        @Service @Primary class Stripe implements PaymentGateway {}
        @Service @Profile("paypal") class Paypal implements PaymentGateway {}
        """),
        (":persistence", "OrderRepository", """
        package com.acme.persistence;
        import org.springframework.stereotype.Repository;
        @Repository public class OrderRepository {}
        """),
    ]

    private func project(profiles: Set<String>? = nil) async -> SpringProjectModel {
        let s = SpringProjectModel(activeProfiles: profiles)
        await s.setModules([module(":application", deps: [":services", ":persistence"]), module(":services", deps: [":persistence"]), module(":persistence")])
        for (m, n, src) in files { await s.update(url: url(m, n), source: src) }
        return s
    }

    private func context(_ s: SpringProjectModel) async throws -> SpringApplicationContext {
        let all = await s.contexts()
        return try XCTUnwrap(all.first)
    }

    private func index(_ ctx: SpringApplicationContext) -> SpringBeanIndex {
        SpringBeanIndex(context: ctx) { u in
            u.path.contains("/application/") ? ":application" : u.path.contains("/services/") ? ":services" : u.path.contains("/persistence/") ? ":persistence" : nil
        }
    }

    // MARK: Bean index

    func testRowsCarryTheirCountsKindsAndModules() async throws {
        let ctx = try await context(await project(profiles: []))
        let rows = Dictionary(uniqueKeysWithValues: index(ctx).rows.map { ($0.name, $0) })
        XCTAssertEqual(rows["orderController"]?.kindLabel, "RestController")
        XCTAssertEqual(rows["orderRepository"]?.kindLabel, "Repository")
        XCTAssertEqual(rows["extraConfig"]?.kindLabel, "Configuration")
        XCTAssertEqual(rows["clock"]?.kindLabel, "@Bean")
        XCTAssertEqual(rows["app"]?.kindLabel, "Application")
        XCTAssertEqual(rows["orderService"]?.module, ":services")
        XCTAssertEqual(rows["orderRepository"]?.module, ":persistence")
        XCTAssertEqual(rows["orderService"]?.dependencyCount, 3, "field + two constructor parameters")
        XCTAssertEqual(rows["orderService"]?.consumerCount, 1, "OrderController")
        XCTAssertEqual(rows["stripe"]?.isPrimary, true)
        XCTAssertEqual(rows["clock"]?.configurationSource, "com.acme.app.ExtraConfig")
    }

    func testSearchMatchesEveryWordAcrossNameTypeAndConfigurationAndFiltersCombine() async throws {
        let ctx = try await context(await project(profiles: []))
        let idx = index(ctx)
        func names(_ edit: (inout SpringBeanFilter) -> Void) -> [String] { var f = SpringBeanFilter(); edit(&f); return idx.search(f).map(\.name) }
        XCTAssertEqual(names { $0.text = "order serv" }, ["orderService"])
        XCTAssertEqual(names { $0.text = "orderservice" }, ["orderService"])
        XCTAssertEqual(names { $0.text = "extraconfig" }, ["clock", "extraConfig", "paypalMarker"], "@Bean methods match their configuration class")
        XCTAssertEqual(names { $0.stereotypes = [.repository] }, ["orderRepository"])
        XCTAssertEqual(names { $0.modules = [":persistence"] }, ["orderRepository"])
        XCTAssertFalse(names { $0.includeFactoryBeans = false }.contains("clock"))
        XCTAssertEqual(names { $0.conditional = .inactive }, ["paypal", "paypalMarker"], "@Profile(paypal) beans are inactive when profiles are [] ")
        XCTAssertEqual(names { $0.onlyProblems = true }, ["lonely", "ping", "pong"], "a missing dependency and a constructor cycle are problems")
        XCTAssertEqual(names { $0.text = "zzz" }, [])
        XCTAssertEqual(idx.modules, [":application", ":persistence", ":services"])
    }

    func testRowOrderIsDeterministic() async throws {
        let a = try await context(await project(profiles: []))
        let b = try await context(await project(profiles: []))
        XCTAssertEqual(index(a).rows.map(\.id), index(b).rows.map(\.id))
    }

    // MARK: Inspector

    func testInspectorListsDependenciesConsumersConditionsAndProblems() async throws {
        let ctx = try await context(await project(profiles: nil))
        let model = ctx.model
        let service = try XCTUnwrap(model.beans.first { $0.name == "orderService" })
        let inspection = try XCTUnwrap(SpringBeanInspection(bean: service.id, in: model))
        XCTAssertEqual(inspection.origin, "Component class (@Service)")
        XCTAssertEqual(inspection.consumers.map(\.ownerName), ["orderController"])
        XCTAssertTrue(inspection.consumers.allSatisfy(\.isCertain))
        let gateway = try XCTUnwrap(inspection.dependencies.first { $0.point.name == "gateway" })
        XCTAssertEqual(gateway.requiredType, "com.acme.services.PaymentGateway")
        XCTAssertEqual(gateway.status, .verified, "@Primary Stripe wins whether or not the conditional Paypal exists")
        XCTAssertEqual(gateway.targets.map(\.name), ["stripe"])

        let lonely = try XCTUnwrap(model.beans.first { $0.name == "lonely" })
        let li = try XCTUnwrap(SpringBeanInspection(bean: lonely.id, in: model))
        XCTAssertEqual(li.dependencies.first?.status, .unresolved("no bean of this type"))
        XCTAssertTrue(li.diagnostics.contains { $0.code == "spring.no-candidate" }, "the diagnostic of its own injection point appears")

        let paypal = try XCTUnwrap(model.beans.first { $0.name == "paypal" })
        let pi = try XCTUnwrap(SpringBeanInspection(bean: paypal.id, in: model))
        XCTAssertFalse(pi.conditions.isEmpty)
        XCTAssertTrue(pi.conditions[0].contains("@Profile(paypal)"))
        XCTAssertTrue(pi.consumers.isEmpty, "Paypal would be a candidate, but @Primary Stripe is what gets injected")

        let clock = try XCTUnwrap(model.beans.first { $0.name == "clock" })
        let ci = try XCTUnwrap(SpringBeanInspection(bean: clock.id, in: model))
        XCTAssertEqual(ci.configurationClass, "com.acme.app.ExtraConfig")
        XCTAssertTrue(ci.origin.hasPrefix("@Bean method clock() of ExtraConfig"))
    }

    func testEveryInspectorLocationPointsAtRealSource() async throws {
        let ctx = try await context(await project(profiles: []))
        let service = try XCTUnwrap(ctx.model.beans.first { $0.name == "orderService" })
        let inspection = try XCTUnwrap(SpringBeanInspection(bean: service.id, in: ctx.model))
        let known = Set(files.map { url($0.0, $0.1) })
        XCTAssertTrue(known.contains(inspection.bean.location.url))
        for d in inspection.dependencies { XCTAssertTrue(known.contains(d.point.location.url)); d.targets.forEach { XCTAssertTrue(known.contains($0.location.url)) } }
        for c in inspection.consumers { XCTAssertTrue(known.contains(c.point.location.url)) }
    }

    // MARK: Bean graph

    func testGraphEdgesCarryResolutionStatusCyclesAndExternalNodes() async throws {
        let ctx = try await context(await project(profiles: nil))
        let graph = SpringBeanGraph(context: ctx) { _ in nil }
        let all = graph.slice({ var o = SpringBeanGraphOptions(); o.nodeLimit = 1000; return o }())
        let byTitle = Dictionary(grouping: all.nodes, by: \.title)
        XCTAssertTrue(byTitle["ping"]?.first?.isInCycle == true && byTitle["pong"]?.first?.isInCycle == true)
        XCTAssertEqual(graph.cycleCount, 1)
        let cycleEdges = all.edges.filter(\.isInCycle)
        XCTAssertEqual(cycleEdges.count, 2)
        let missing = try XCTUnwrap(all.edges.first { $0.status == .unresolved })
        XCTAssertTrue(missing.to.hasPrefix("external:"))
        XCTAssertEqual(all.nodes.first { $0.id == missing.to }?.kind, .external)
        XCTAssertTrue(all.edges.contains { $0.label == "gateway" && $0.status == .verified }, "@Primary resolves the gateway")
        XCTAssertTrue(all.edges.contains { $0.status == .verified })
        XCTAssertFalse(all.isTruncated)
    }

    func testFocusDirectionDepthAndFilters() async throws {
        let ctx = try await context(await project(profiles: []))
        let graph = SpringBeanGraph(context: ctx) { u in u.path.contains("/persistence/") ? ":persistence" : u.path.contains("/services/") ? ":services" : ":application" }
        let service = try XCTUnwrap(ctx.model.beans.first { $0.name == "orderService" }).id
        func titles(_ edit: (inout SpringBeanGraphOptions) -> Void) -> Set<String> {
            var o = SpringBeanGraphOptions(); o.focus = service; edit(&o)
            return Set(graph.slice(o).nodes.map(\.title))
        }
        XCTAssertEqual(titles { $0.direction = .incoming; $0.depth = 1 }, ["orderService", "orderController"])
        XCTAssertEqual(titles { $0.direction = .outgoing; $0.depth = 1 }, ["orderService", "orderRepository", "clock", "stripe"])
        XCTAssertEqual(titles { $0.direction = .both; $0.depth = 0 }, ["orderService"])
        XCTAssertTrue(titles { $0.direction = .both; $0.depth = nil }.isSuperset(of: ["orderController", "orderRepository"]))
        XCTAssertEqual(titles { $0.direction = .outgoing; $0.depth = 1; $0.modules = [":persistence"] }, ["orderService", "orderRepository"], "filters drop other beans, never the focus")
        XCTAssertFalse(titles { $0.direction = .outgoing; $0.depth = 1; $0.includeFactoryBeans = false }.contains("clock"))
        var o = SpringBeanGraphOptions(); o.search = "repo"
        XCTAssertEqual(graph.slice(o).matches.count, 1)
    }

    func testNodeLimitTruncatesHonestly() async throws {
        let ctx = try await context(await project(profiles: []))
        var o = SpringBeanGraphOptions(); o.nodeLimit = 3
        let slice = SpringBeanGraph(context: ctx) { _ in nil }.slice(o)
        XCTAssertEqual(slice.nodes.count, 3)
        XCTAssertTrue(slice.isTruncated)
        XCTAssertTrue(slice.notes.contains { $0.contains("Showing the first 3") })
        XCTAssertTrue(slice.edges.allSatisfy { e in slice.nodes.contains { $0.id == e.from } && slice.nodes.contains { $0.id == e.to } }, "no dangling edges")
    }

    // MARK: Context graph

    func testContextGraphShowsImportsScansFactoryMethodsAndWhatItCannotRead() async throws {
        let ctx = try await context(await project(profiles: []))
        let g = SpringContextGraph(context: ctx) { _ in nil }
        let titles = Set(g.nodes.map(\.title))
        XCTAssertTrue(titles.isSuperset(of: ["app", "extraConfig", "clock", "com.acme"]), "\(titles)")
        XCTAssertTrue(g.edges.contains { $0.relation == .importClass && $0.status == .verified })
        XCTAssertTrue(g.edges.contains { $0.relation == .componentScan })
        XCTAssertTrue(g.edges.contains { $0.relation == .declares })
        XCTAssertTrue(g.notes.contains { $0.contains("Parent–child") }, "what is unknowable is said, not drawn")
        XCTAssertFalse(g.nodes.contains { $0.title == "ping" }, "the context graph is not the bean graph")
    }

    func testContextGraphMarksLibraryImportsAsUnknownNotAsEdges() async throws {
        let s = SpringProjectModel()
        await s.setModules([module(":application")])
        await s.update(url: url(":application", "App"), source: """
        package app;
        import org.springframework.boot.autoconfigure.SpringBootApplication;
        import org.springframework.context.annotation.*;
        @SpringBootApplication @Import(org.lib.LibConfig.class) @ImportResource("classpath:beans.xml") class App {}
        """)
        let ctx = try await context(s)
        let g = SpringContextGraph(context: ctx) { _ in nil }
        XCTAssertEqual(g.nodes.filter { $0.kind == .unknown }.count, 2)
        XCTAssertTrue(g.edges.filter { $0.relation == .importClass || $0.relation == .importResource }.allSatisfy { $0.status == .unresolved })
    }

    // MARK: Gutter markers

    func testSpringMarkersCoverBeansInjectionPointsAndApplications() async throws {
        let s = await project(profiles: nil)
        let indexer = SpringWorkspaceIndexer(store: s)
        await indexer.configureForTesting(modules: [module(":application", deps: [":services", ":persistence"]), module(":services"), module(":persistence")])
        let u = url(":application", "App")
        let source = files[0].2
        let provided = await SpringLineMarkerProvider(indexer: indexer).lineMarkers(source: source, fileURL: u, kinds: [])
        let markers = try XCTUnwrap(provided)
        let byID = Dictionary(grouping: markers, by: { $0.descriptor?.id.rawValue ?? "?" })
        XCTAssertEqual(byID["spring.application"]?.count, 1)
        XCTAssertEqual(byID["spring.controller"]?.count, 1)
        XCTAssertEqual((byID["spring.bean"]?.count ?? 0), 3, "Ping, Pong, Lonely")
        XCTAssertEqual(byID["spring.injection"]?.count, 3, "OrderController, Ping and Pong have candidates; Lonely's has none")
        XCTAssertTrue(markers.allSatisfy { $0.kind == .extended })
        XCTAssertEqual(markers.map { $0.line }, markers.map { $0.line }.sorted(), "ordered by line")
        let app = try XCTUnwrap(byID["spring.application"]?.first)
        XCTAssertEqual(app.line, 6)
        // The application line also carries the class's injection... nothing; but the Controller line has bean + injection: they stack.
        let stacks = LineMarkerPresentation.stacks(from: markers)
        let controllerLine = try XCTUnwrap(markers.first { $0.descriptor?.id == "spring.controller" }).line
        let stack = try XCTUnwrap(stacks.first { $0.line == controllerLine })
        XCTAssertTrue(stack.isStacked)
        XCTAssertEqual(stack.visible.descriptor?.id, "spring.controller", "the more specific marker is drawn; the injection point stays in the stack")
    }

    func testEveryMarkerOffersRealActions() async throws {
        let s = await project(profiles: nil)
        let indexer = SpringWorkspaceIndexer(store: s)
        await indexer.configureForTesting(modules: [module(":application", deps: [":services", ":persistence"]), module(":services"), module(":persistence")])
        let provider = SpringLineMarkerProvider(indexer: indexer)
        let u = url(":application", "App")
        let source = files[0].2
        let provided = await provider.lineMarkers(source: source, fileURL: u, kinds: [])
        let markers = try XCTUnwrap(provided)
        for marker in markers {
            let items = await provider.menu(for: marker, source: source, fileURL: u, documentID: DocumentID())
            XCTAssertFalse(items.isEmpty, "\(marker.descriptor?.id.rawValue ?? "?") on line \(marker.line) has nothing to offer")
        }
        let controller = try XCTUnwrap(markers.first { $0.descriptor?.id == "spring.controller" })
        let items = await provider.menu(for: controller, source: source, fileURL: u, documentID: DocumentID())
        XCTAssertTrue(items.contains { $0.title == "Find Usages" })
        XCTAssertTrue(items.contains { if case .command(let c) = $0.action { return c.id == SpringMarkers.Command.reveal } else { return false } })
        XCTAssertTrue(items.contains { if case .command(let c) = $0.action { return c.id == SpringMarkers.Command.dependencyGraph } else { return false } })
        let injection = try XCTUnwrap(markers.first { $0.descriptor?.id == "spring.injection" })
        let goTo = await provider.menu(for: injection, source: source, fileURL: u, documentID: DocumentID())
        guard case .open(let locations)? = goTo.first?.action else { return XCTFail("first action navigates") }
        XCTAssertFalse(locations.isEmpty)
    }

    func testDescriptorsAreUniqueNamespacedAndAccessible() {
        let ids = SpringMarkers.all.map(\.id.rawValue)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("spring.") })
        XCTAssertTrue(SpringMarkers.all.allSatisfy { !$0.accessibilityLabel.isEmpty && !$0.title.isEmpty && $0.group == "Spring" })
    }
}
