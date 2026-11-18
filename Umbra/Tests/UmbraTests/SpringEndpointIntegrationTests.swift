import AppKit
import EditorIntelligence
import JavaIntelligence
import SpringIntelligence
import SwiftUI
import XCTest
@testable import Umbra

/// Endpoint intelligence through the real engines: the window's `IDEIntelligenceServices` (diagnostic, navigation, completion,
/// code-action and gutter-marker registries) over Java and `.http` files written to disk and analysed by the real indexer.
@MainActor
final class SpringEndpointEngineTests: XCTestCase {
    private var root: URL!
    private var services: IDEIntelligenceServices!
    private let web = "import org.springframework.web.bind.annotation.*;"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spring-ep-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/main/java/app"), withIntermediateDirectories: true)
        services = IDEIntelligenceServices()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ name: String, _ text: String) throws -> URL {
        let u = root.appendingPathComponent("src/main/java/app/\(name).java")
        try text.write(to: u, atomically: true, encoding: .utf8)
        return u.standardizedFileURL
    }

    private func configure(profiles: Set<String>? = nil) async {
        let jar = URL(fileURLWithPath: "/h/.gradle/caches/modules-2/files-2.1/org.springframework/spring-context/6.1.2/x/spring-context-6.1.2.jar")
        let model = JavaGradleProjectModel(formatVersion: 9, gradleVersion: "8", subprojects: [
            .init(path: ":app", directory: root, sourceDirs: [root.appendingPathComponent("src/main/java")], compileClasspathJars: [jar])])
        let indexer = services.javaSupport.springIndexer
        await indexer.store.setActiveProfiles(profiles)
        await indexer.configure(model: model)
        await indexer.waitForScan()
    }

    private func document(_ url: URL?, _ text: String, at marker: String, offset: Int = 0, language: String = "java") -> EditorIntelligence.Document {
        let ns = text as NSString
        let utf16 = ns.range(of: marker).location + offset
        let prefix = ns.substring(to: utf16)
        let p = TextPosition(line: prefix.filter { $0 == "\n" }.count,
                             column: prefix.split(separator: "\n", omittingEmptySubsequences: false).last.map { $0.utf16.count } ?? 0, utf16Offset: utf16)
        return EditorIntelligence.Document(url: url, displayName: url?.lastPathComponent ?? "requests.http", contentSnapshot: TextSnapshot(version: 1, text: text),
                        selection: Selection(range: EditorIntelligence.TextRange(start: p, end: p)), cursor: Cursor(position: p),
                        viewport: Viewport(x: 0, y: 0, width: 1, height: 1), languageIdentifier: language)
    }

    private func apply(_ edits: [TextEdit], to text: String) -> String {
        var ns = text as NSString
        for e in edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            ns = ns.replacingCharacters(in: NSRange(location: e.range.start.utf16Offset, length: e.range.end.utf16Offset - e.range.start.utf16Offset), with: e.replacement) as NSString
        }
        return ns as String
    }

    private lazy var controller = """
    package app;
    \(web)
    @RestController
    @RequestMapping("/api/customers")
    class CustomerController {
        @GetMapping("/{id}")
        Customer find(@PathVariable Long id) { return null; }

        @PostMapping(consumes = "application/json")
        Customer create(@RequestBody Customer c) { return c; }
    }
    class Customer { String name; }
    """

    // MARK: Navigation

    func testARouteInAnHttpFileNavigatesToItsHandler() async throws {
        let java = try write("CustomerController", controller)
        await configure()
        let text = "### one\nGET {{baseUrl}}/api/customers/42\nAccept: application/json\n"
        let doc = document(nil, text, at: "/api/customers/42", offset: 5, language: "http")
        let result = await services.navigationEngine.navigate(context: NavigationContext(document: doc, cursor: doc.cursor, selection: doc.selection, kind: .definition))
        guard case .single(let location)? = result else { return XCTFail("expected the one handler, got \(String(describing: result))") }
        XCTAssertEqual(location.url, java)
        XCTAssertEqual(location.range.start.line, 6, "the line of `find`")
        XCTAssertTrue(location.displayName.contains("GET /api/customers/{id}"))

        let post = "POST {{baseUrl}}/api/customers\n"
        let pdoc = document(nil, post, at: "/api/customers", offset: 2, language: "http")
        let presult = await services.navigationEngine.navigate(context: NavigationContext(document: pdoc, cursor: pdoc.cursor, selection: pdoc.selection, kind: .definition))
        guard case .single(let create)? = presult else { return XCTFail("POST") }
        XCTAssertEqual(create.range.start.line, 9)
    }

    func testARouteStringInATestNavigatesToTheHandlerButTypesStayWithJava() async throws {
        let java = try write("CustomerController", controller)
        let test = try write("CustomerControllerTest", "package app;\nclass CustomerControllerTest { void t() throws Exception { mvc.perform(get(\"/api/customers/7\")); } }\n")
        await configure()
        let text = try String(contentsOf: test, encoding: .utf8)
        let doc = document(test, text, at: "/api/customers/7", offset: 4)
        guard case .single(let location)? = await services.navigationEngine.navigate(context: NavigationContext(document: doc, cursor: doc.cursor, selection: doc.selection, kind: .definition))
        else { return XCTFail("expected the handler") }
        XCTAssertEqual(location.url, java)

        // On a type name the Spring providers say nothing, so Java's own answer (or none) stands.
        let source = try String(contentsOf: java, encoding: .utf8)
        let typeDoc = document(java, source, at: "Customer find", offset: 3)
        let result = await services.navigationEngine.navigate(context: NavigationContext(document: typeDoc, cursor: typeDoc.cursor, selection: typeDoc.selection, kind: .definition))
        if case .single(let loc)? = result { XCTAssertFalse(loc.displayName.contains("GET "), "Spring must not answer for a type: \(loc.displayName)") }
    }

    func testFindUsagesOnAHandlerListsTheRequestsThatCallIt() async throws {
        let java = try write("CustomerController", controller)
        try "GET {{baseUrl}}/api/customers/1\n".write(to: root.appendingPathComponent("requests.http"), atomically: true, encoding: .utf8)
        let tests = root.appendingPathComponent("src/test/java")
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        try "class T { void t() { mvc.perform(get(\"/api/customers/9\")); } }".write(to: tests.appendingPathComponent("T.java"), atomically: true, encoding: .utf8)
        await configure()
        let text = try String(contentsOf: java, encoding: .utf8)
        let doc = document(java, text, at: "find(", offset: 1)
        let result = await services.navigationEngine.navigate(context: NavigationContext(document: doc, cursor: doc.cursor, selection: doc.selection, kind: .references))
        let locations = try XCTUnwrap(result?.locations)
        let labels = locations.compactMap { $0.usage?.kindLabel }
        XCTAssertTrue(labels.contains("HTTP request"), "\(labels)")
        XCTAssertTrue(labels.contains("Test request"), "\(labels)")
    }

    func testAPlaceholderInAMappingNavigatesToItsConfigurationKey() async throws {
        let java = try write("P", "package app;\n\(web)\n@RestController class P { @GetMapping(\"${api.path}/x\") String x() { return \"\"; } }\n")
        let resources = root.appendingPathComponent("src/main/resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let config = resources.appendingPathComponent("application.properties")
        try "api.path=/v1\n".write(to: config, atomically: true, encoding: .utf8)
        await configure()
        let text = try String(contentsOf: java, encoding: .utf8)
        let doc = document(java, text, at: "api.path", offset: 2)
        let result = await services.navigationEngine.navigate(context: NavigationContext(document: doc, cursor: doc.cursor, selection: doc.selection, kind: .definition))
        guard case .single(let location)? = result else { return XCTFail("\(String(describing: result))") }
        XCTAssertEqual(location.url?.lastPathComponent, "application.properties")
    }

    // MARK: Diagnostics and fixes

    func testMappingProblemsReachTheDiagnosticEngineAndTheirFixesApplyCleanly() async throws {
        let text = """
        package app;
        \(web)
        @RestController @RequestMapping("/c") class P {
            @GetMapping("/{id}") String f(@PathVariable Long idd) { return ""; }
            @GetMapping("/m") @PostMapping("/n") String twice() { return ""; }
        }
        @RestController class Q { @GetMapping("/c/{id}") String g() { return ""; } @GetMapping("/c/{x}") String h() { return ""; } }
        """
        let url = try write("P", text)
        await configure()
        let doc = document(url, text, at: "Long idd", offset: 5)
        let report = await services.diagnosticEngine.diagnostics(for: doc)
        let codes = Set(report.diagnostics.filter { $0.source == "Spring" }.compactMap(\.code))
        XCTAssertTrue(codes.isSuperset(of: [SpringEndpointDiagnosticCode.unknownPathVariable, SpringEndpointDiagnosticCode.multipleMappings,
                                            SpringEndpointDiagnosticCode.ambiguousVariables]), "\(codes)")

        let actions = await services.languages.codeActions.codeActions(for: doc, at: doc.cursor.position, diagnostics: report.diagnostics)
        let bind = try XCTUnwrap(actions.first { $0.title == "Bind to path variable {id}" }, "\(actions.map(\.title))")
        let fixed = apply(bind.edits, to: text)
        XCTAssertTrue(fixed.contains("@PathVariable(\"id\") Long idd"), fixed)

        let second = document(url, text, at: "@PostMapping", offset: 2)
        let moreActions = await services.languages.codeActions.codeActions(for: second, at: second.cursor.position, diagnostics: report.diagnostics)
        let remove = try XCTUnwrap(moreActions.first { $0.title.hasPrefix("Remove the ignored @PostMapping") }, "\(moreActions.map(\.title))")
        let removed = apply(remove.edits, to: fixed)
        XCTAssertFalse(removed.contains("@PostMapping(\"/n\")"), removed)

        await services.javaSupport.springIndexer.ingest(url: url, text: removed)
        let after = await services.javaSupport.springIndexer.store.endpointIndexes().first?.diagnostics ?? []
        XCTAssertFalse(after.contains { $0.code == SpringEndpointDiagnosticCode.unknownPathVariable || $0.code == SpringEndpointDiagnosticCode.multipleMappings })
    }

    // MARK: Completion

    func testPathVariableAndMediaTypeCompletionAlongsideJava() async throws {
        let text = """
        package app;
        \(web)
        @RestController @RequestMapping("/o") class O {
            @GetMapping(value = "/{orderId}/items/{itemId}", produces = "")
            String f(@PathVariable("") Long orderId) { return ""; }
        }
        """
        let url = try write("O", text)
        await configure()
        func complete(at marker: String) async throws -> [CompletionItem] {
            let d = document(url, text, at: marker, offset: marker.count)
            let ctx = CompletionContext(document: d, cursor: d.cursor, trigger: .manual, prefix: "",
                                        range: EditorIntelligence.TextRange(start: d.cursor.position, end: d.cursor.position))
            return try await services.completionEngine.complete(context: ctx)
        }
        let variables = try await complete(at: "@PathVariable(\"").map(\.label)
        XCTAssertEqual(Set(variables).intersection(["orderId", "itemId"]), ["orderId", "itemId"], "\(variables)")
        let media = try await complete(at: "produces = \"").map(\.label)
        XCTAssertTrue(media.contains("application/json"), "\(media.prefix(10))")
        let plain = try await complete(at: "String f(")
        XCTAssertFalse(plain.contains { $0.label == "application/json" }, "Spring adds nothing outside its annotation strings")
    }

    // MARK: Markers

    func testHandlersGetAnEndpointMarkerWithItsMenuThroughTheRealRegistry() async throws {
        let java = try write("CustomerController", controller)
        await configure()
        let source = try String(contentsOf: java, encoding: .utf8)
        let provider = try XCTUnwrap(services.languages.lineMarkers(for: "java"))
        let provided = await provider.lineMarkers(source: source, fileURL: java, kinds: Set(LineMarkerKind.allCases))
        let markers = try XCTUnwrap(provided)
        let endpointMarkers = markers.filter { $0.descriptor?.id == "spring.endpoint" }
        XCTAssertEqual(endpointMarkers.map(\.line), [7, 10], "one per handler method")
        XCTAssertEqual(markers.filter { $0.descriptor?.id == "spring.controller" }.map(\.line), [5], "the class keeps its own marker")
        XCTAssertTrue(endpointMarkers[0].tooltip.contains("GET /api/customers/{id}"))

        let menu = await provider.menu(for: endpointMarkers[0], source: source, fileURL: java, documentID: DocumentID())
        XCTAssertEqual(menu.map(\.title), [
            "Reveal GET /api/customers/{id} in Spring Endpoints", "Copy GET /api/customers/{id}",
            "Generate HTTP Request for GET /api/customers/{id}", "Go to Controller CustomerController",
        ])
        let classMenu = await provider.menu(for: try XCTUnwrap(markers.first { $0.descriptor?.id == "spring.controller" }), source: source, fileURL: java, documentID: DocumentID())
        XCTAssertTrue(classMenu.contains { $0.title == "Show 2 endpoints" }, "\(classMenu.map(\.title))")
    }
}

/// The tool window's Endpoints section and the workspace commands behind it.
@MainActor
final class SpringEndpointToolWindowTests: XCTestCase {
    private var root: URL!
    private var workspace: IDEWorkspace!

    /// The window's store persists the search text in the standard defaults; a test must neither inherit nor leave one.
    private static let persistedKeys = ["com.umbra.editor.spring.endpointText", "com.umbra.editor.spring.groupEndpoints"]

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        Self.persistedKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spring-ep-tw-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        let dir = root.appendingPathComponent("src/main/java/app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        package app;
        import org.springframework.boot.autoconfigure.SpringBootApplication;
        import org.springframework.web.bind.annotation.*;
        @SpringBootApplication public class App {}
        @RestController @RequestMapping("/api/customers") class CustomerController {
            @GetMapping(value = "/{id}", produces = "application/json") Customer find(@PathVariable Long id) { return null; }
            @PostMapping(consumes = "application/json") Customer create(@RequestBody Customer c) { return c; }
            @DeleteMapping("/{id}") void delete(@PathVariable Long id) {}
        }
        @RestController class HealthController { @GetMapping("/health") String health() { return "ok"; } }
        class Customer { String name; int age; }
        """.write(to: dir.appendingPathComponent("App.java"), atomically: true, encoding: .utf8)
        workspace = IDEWorkspace()
        workspace.bootstrap()
        workspace.project.setRoot(root)
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        Self.persistedKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        try? FileManager.default.removeItem(at: root)
    }

    private func loadedStore() async -> IDESpringStore {
        let jar = URL(fileURLWithPath: "/h/.gradle/caches/modules-2/files-2.1/org.springframework/spring-context/6.1.2/x/spring-context-6.1.2.jar")
        let model = JavaGradleProjectModel(formatVersion: 9, gradleVersion: "8", subprojects: [
            .init(path: ":app", directory: root, sourceDirs: [root.appendingPathComponent("src/main/java")], compileClasspathJars: [jar])])
        let indexer = workspace.javaSupport.springIndexer
        await indexer.configure(model: model)
        await indexer.waitForScan()
        let s = workspace.springStore
        s.refresh(indexer: indexer)
        await s.waitForLoad()
        return s
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for the condition") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func render<V: View>(_ view: V, size: NSSize = NSSize(width: 320, height: 560)) throws -> Double {
        let host = NSHostingView(rootView: view.environment(workspace).preferredColorScheme(.dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
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

    func testTheEndpointsSectionListsRealEndpointsAndFiltersThem() async throws {
        let store = await loadedStore()
        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(Set(store.endpointRows.map(\.title)),
                       ["GET /api/customers/{id}", "DELETE /api/customers/{id}", "POST /api/customers", "GET /health"])
        store.endpointFilter.text = "customers post"
        XCTAssertEqual(store.endpointRows.map(\.title), ["POST /api/customers"])
        store.endpointFilter = SpringEndpointFilter()
        store.endpointFilter.methods = ["GET"]
        XCTAssertEqual(Set(store.endpointRows.map(\.handler)), ["find", "health"])
        store.endpointFilter = SpringEndpointFilter()
        store.endpointFilter.sort = .controller
        XCTAssertEqual(store.endpointRows.last?.controllerSimpleName, "HealthController")
    }

    func testRevealCommandSelectsTheEndpointAndShowsTheEndpointsSection() async throws {
        let store = await loadedStore()
        await workspace.javaSupport.mirrorSpringModules()
        let endpoint = try XCTUnwrap(store.endpointRows.first { $0.handler == "create" })
        store.endpointFilter.text = "zzz-nothing-matches"
        workspace.performMarkerCommand(CodeActionCommand(id: SpringMarkers.Command.revealEndpoint, arguments: [endpoint.contextID, endpoint.id.raw]))
        await store.waitForLoad()
        XCTAssertEqual(workspace.selectedSidebarTab, .spring)
        XCTAssertEqual(store.section, .endpoints)
        XCTAssertEqual(store.selectedEndpoint?.id, endpoint.id)
        XCTAssertEqual(store.endpointFilter.text, "", "a search that would hide the endpoint is cleared")
    }

    func testGoToHandlerOpensTheSourceAtTheHandler() async throws {
        let store = await loadedStore()
        let endpoint = try XCTUnwrap(store.endpointRows.first { $0.handler == "health" })
        workspace.openSpringLocation(endpoint.handlerLocation, title: endpoint.handlerTitle)
        try await waitUntil { self.workspace.workbench.activePane.selectedDocument?.url?.standardizedFileURL == endpoint.handlerLocation.url }
        XCTAssertEqual(workspace.workbench.activePane.selectedDocument?.url?.standardizedFileURL, endpoint.handlerLocation.url)
    }

    func testGenerateHTTPRequestOpensAnUnsavedHttpBufferAndSendsNothing() async throws {
        let store = await loadedStore()
        let endpoint = try XCTUnwrap(store.endpointRows.first { $0.handler == "find" })
        workspace.performMarkerCommand(CodeActionCommand(id: SpringMarkers.Command.generateHTTPRequest, arguments: [endpoint.contextID, endpoint.id.raw]))
        try await waitUntil { self.workspace.workbench.activePane.selectedDocument?.displayName.hasSuffix(".http") == true }
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        XCTAssertNil(document.url, "an untitled buffer: nothing is written to the project")
        let text = document.text
        XCTAssertTrue(text.contains("GET {{baseUrl}}/api/customers/{{id}}"), text)
        XCTAssertTrue(text.contains("Accept: application/json"))
        XCTAssertTrue(text.contains("@baseUrl = http://localhost:<set-the-port>"), "no server.port configured: an explicit placeholder")
        XCTAssertFalse(text.contains("8080"))
        XCTAssertFalse(workspace.httpSupport.isSending, "generating never sends")
    }

    func testCopyCommandPutsTheRouteOnThePasteboard() async throws {
        _ = await loadedStore()
        workspace.performMarkerCommand(CodeActionCommand(id: SpringMarkers.Command.copyText, arguments: ["GET /health"]))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "GET /health")
    }

    func testEndpointListAndInspectorRenderForEveryState() async throws {
        let store = await loadedStore()
        store.section = .endpoints
        XCTAssertGreaterThan(try render(IDESpringPanel()), 0.003, "list with no selection")
        store.selectedEndpointID = store.endpointRows.first { $0.handler == "create" }?.id
        XCTAssertGreaterThan(try render(IDESpringPanel(), size: NSSize(width: 320, height: 700)), 0.003, "list with the inspector")
        let endpoint = try XCTUnwrap(store.selectedEndpoint)
        XCTAssertGreaterThan(try render(IDESpringEndpointInspector(endpoint: endpoint, store: store), size: NSSize(width: 300, height: 600)), 0.003)
        store.endpointFilter.text = "nothing matches this"
        XCTAssertGreaterThan(try render(IDESpringPanel()), 0.001, "the no-match state explains itself")
    }

    /// Mean brightness (0 dark … 1 light) and ink share of a render under one colour scheme.
    private func renderScheme<V: View>(_ view: V, scheme: ColorScheme, size: NSSize) throws -> (brightness: Double, host: NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: AnyView(view.environment(workspace).preferredColorScheme(scheme)))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var sum = 0.0, n = 0.0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                sum += 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent; n += 1
            }
        }
        return (n == 0 ? 0 : sum / n, host)
    }

    func testTheEndpointsSectionRendersInBothUmbraColourSchemes() async throws {
        let theme = IDEThemeStore.shared
        let saved = theme.scheme
        defer { theme.setScheme(saved) }
        let store = await loadedStore()
        store.section = .endpoints
        store.selectedEndpointID = store.endpointRows.first { $0.handler == "create" }?.id
        theme.setScheme(IDEUmbraUIColorScheme.shared)
        let dark = try renderScheme(IDESpringPanel(), scheme: .dark, size: NSSize(width: 320, height: 700)).brightness
        theme.setScheme(IDEUmbraLightUIColorScheme.shared)
        let light = try renderScheme(IDESpringPanel(), scheme: .light, size: NSSize(width: 320, height: 700)).brightness
        XCTAssertLessThan(dark, 0.45, "the dark scheme draws a dark panel: \(dark)")
        XCTAssertGreaterThan(light, 0.6, "the light scheme draws a light panel: \(light)")
    }

    func testReturnOpensTheSelectedHandlerAndDoesNothingWithoutASelection() async throws {
        let store = await loadedStore()
        XCTAssertFalse(workspace.openSelectedSpringEndpoint(in: store), "no selection: the key is not handled")
        let endpoint = try XCTUnwrap(store.endpointRows.first { $0.handler == "delete" })
        store.selectedEndpointID = endpoint.id
        XCTAssertTrue(workspace.openSelectedSpringEndpoint(in: store))
        try await waitUntil { self.workspace.workbench.activePane.selectedDocument?.url?.standardizedFileURL == endpoint.handlerLocation.url }
    }

    func testEndpointRowsAreExposedToAssistiveTechnology() async throws {
        let store = await loadedStore()
        store.section = .endpoints
        let (_, host) = try renderScheme(IDESpringPanel(), scheme: .dark, size: NSSize(width: 320, height: 700))
        func labels(_ element: Any, depth: Int = 0) -> [String] {
            guard depth < 12 else { return [] }
            var out: [String] = []
            let ax = element as? NSAccessibilityProtocol
            if let label = ax?.accessibilityLabel(), !label.isEmpty { out.append(label) }
            let children = (ax?.accessibilityChildren() as? [Any]) ?? []
            for child in children { out += labels(child, depth: depth + 1) }
            return out
        }
        let all = labels(host)
        try XCTSkipIf(all.isEmpty, "SwiftUI builds its accessibility tree only for a running assistive client; nothing to inspect here")
        XCTAssertTrue(all.contains { $0.contains("GET /health") || $0.hasPrefix("Endpoints,") }, "\(all.prefix(12))")
    }

    func testAnApplicationWithoutControllersSaysSoInsteadOfListingNothing() async throws {
        try "package app; import org.springframework.boot.autoconfigure.SpringBootApplication; @SpringBootApplication public class App {}"
            .write(to: root.appendingPathComponent("src/main/java/app/App.java"), atomically: true, encoding: .utf8)
        let store = await loadedStore()
        XCTAssertTrue(store.endpointRows.isEmpty)
        store.section = .endpoints
        XCTAssertGreaterThan(try render(IDESpringPanel()), 0.001)
    }

    func testAMappingEditRefreshesTheSnapshotWithoutRebuildingBeans() async throws {
        let store = await loadedStore()
        let indexer = workspace.javaSupport.springIndexer
        let file = root.appendingPathComponent("src/main/java/app/App.java").standardizedFileURL
        let original = try String(contentsOf: file, encoding: .utf8)
        let before = store.buildCount
        let revision = await indexer.store.revision
        await indexer.ingest(url: file, text: original.replacingOccurrences(of: "\"/health\"", with: "\"/status\""))
        store.refresh(indexer: indexer); await store.waitForLoad()
        XCTAssertEqual(store.buildCount, before + 1)
        XCTAssertTrue(store.endpointRows.contains { $0.route == "/status" })
        let after = await indexer.store.revision
        XCTAssertEqual(after, revision, "the bean model was not rebuilt for a mapping edit")
    }

    /// 1,000 endpoints in 100 controllers written to disk and read by the real indexer. Debug-build timings are printed for the
    /// record (`ENDPOINTUI`); the assertions only guard against the list doing work proportional to the whole project per row.
    func testAThousandEndpointsLoadFilterAndRender() async throws {
        let dir = root.appendingPathComponent("src/main/java/app")
        for c in 0..<100 {
            let methods = (0..<10).map { "    @GetMapping(\"/item\($0)/{id}\") String get\($0)(@PathVariable Long id) { return \"\"; }" }.joined(separator: "\n")
            try """
            package app;
            import org.springframework.web.bind.annotation.*;
            @RestController @RequestMapping("/api/c\(c)") class Big\(c) {
            \(methods)
            }
            """.write(to: dir.appendingPathComponent("Big\(c).java"), atomically: true, encoding: .utf8)
        }
        let clock = ContinuousClock()
        let started = clock.now
        let store = await loadedStore()
        let loadMs = Double((clock.now - started).components.attoseconds) / 1e15 + Double((clock.now - started).components.seconds) * 1000
        XCTAssertGreaterThanOrEqual(store.endpointRows.count, 1_000)
        store.section = .endpoints
        let renderStart = clock.now
        let ink = try render(IDESpringPanel(), size: NSSize(width: 320, height: 700))
        let renderMs = Double((clock.now - renderStart).components.attoseconds) / 1e15 + Double((clock.now - renderStart).components.seconds) * 1000
        let filterStart = clock.now
        store.endpointFilter.text = "c42 item7"
        let found = store.endpointRows.count
        let filterMs = Double((clock.now - filterStart).components.attoseconds) / 1e15 + Double((clock.now - filterStart).components.seconds) * 1000
        print("ENDPOINTUI endpoints=\(store.snapshot?.contexts.first?.endpoints.endpoints.count ?? 0) load+snapshot=\(Int(loadMs))ms render=\(Int(renderMs))ms filter=\(String(format: "%.2f", filterMs))ms (debug build)")
        XCTAssertGreaterThan(ink, 0.003)
        XCTAssertEqual(found, 1)
        XCTAssertLessThan(renderMs, 5_000, "the list is lazy: rendering does not lay out every row")
    }
}
