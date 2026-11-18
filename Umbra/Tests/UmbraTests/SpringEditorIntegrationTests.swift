import EditorIntelligence
import Penumbra
import JavaIntelligence
import SpringIntelligence
import XCTest
@testable import Umbra

/// Spring through the window's real engines (`IDEIntelligenceServices`): the registry order, Java's own
/// providers, the generic providers and the dependency filter are all in the path. This is as far as the
/// editor workflow can be driven without a live `TextView`; the controller-level popup and gutter are not covered.
@MainActor
final class SpringEditorIntegrationTests: XCTestCase {
    private var root: URL!
    private var services: IDEIntelligenceServices!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spring-int-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/main/java/app"), withIntermediateDirectories: true)
        services = IDEIntelligenceServices()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func project(_ source: String, profiles: Set<String>? = nil) async throws -> (URL, SpringWorkspaceIndexer) {
        let url = root.appendingPathComponent("src/main/java/app/A.java").standardizedFileURL
        try source.write(to: url, atomically: true, encoding: .utf8)
        let jar = URL(fileURLWithPath: "/h/.gradle/caches/modules-2/files-2.1/org.springframework/spring-context/6.1.2/x/spring-context-6.1.2.jar")
        let model = JavaGradleProjectModel(formatVersion: 9, gradleVersion: "8", subprojects: [
            .init(path: ":app", directory: root, sourceDirs: [root.appendingPathComponent("src/main/java")], compileClasspathJars: [jar])])
        let indexer = services.javaSupport.springIndexer
        await indexer.store.setActiveProfiles(profiles)
        await indexer.configure(model: model)
        await indexer.waitForScan()
        return (url, indexer)
    }

    private func document(_ url: URL, _ text: String, before marker: String, offset: Int = 0) -> Document {
        let ns = text as NSString
        let utf16 = ns.range(of: marker).location + offset
        let prefix = ns.substring(to: utf16)
        let line = prefix.filter { $0 == "\n" }.count
        let column = prefix.split(separator: "\n", omittingEmptySubsequences: false).last.map { $0.utf16.count } ?? 0
        let p = TextPosition(line: line, column: column, utf16Offset: utf16)
        return Document(
            url: url, displayName: url.lastPathComponent, contentSnapshot: TextSnapshot(version: 1, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: p, end: p)), cursor: Cursor(position: p),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java")
    }

    private func apply(_ edits: [TextEdit], to text: String) -> String {
        var ns = text as NSString
        for e in edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            ns = ns.replacingCharacters(in: NSRange(location: e.range.start.utf16Offset,
                                                     length: e.range.end.utf16Offset - e.range.start.utf16Offset),
                                        with: e.replacement) as NSString
        }
        return ns as String
    }

    private let header = """
    package app;
    import org.springframework.stereotype.Service;
    import org.springframework.context.annotation.Profile;
    interface Gateway {}
    @Service class Stripe implements Gateway {}
    """

    private func source(extra: String, orders: String = "Orders(Gateway gateway) { }") -> String {
        header + "\n" + extra + "\n@Service class Orders {\n    " + orders + "\n}\n"
    }

    // MARK: Navigation through the real engine

    func testGoToDefinitionOnInjectedNameBeatsJavaSelfResult() async throws {
        let text = source(extra: "")
        let (url, _) = try await project(text)
        let doc = document(url, text, before: "gateway) { }", offset: 2)
        let ctx = NavigationContext(document: doc, cursor: doc.cursor, selection: doc.selection, kind: .definition)
        guard case .single(let loc)? = await services.navigationEngine.navigate(context: ctx) else { return XCTFail("no navigation result") }
        XCTAssertTrue(loc.displayName.hasPrefix("stripe"), loc.displayName)
    }

    func testAmbiguousAndConditionalCandidatesAreListed() async throws {
        var text = source(extra: "@Service class Paypal implements Gateway {}")
        var (url, _) = try await project(text)
        var doc = document(url, text, before: "gateway) { }", offset: 2)
        var ctx = NavigationContext(document: doc, cursor: doc.cursor, selection: doc.selection, kind: .definition)
        guard case .multiple(let ambiguous)? = await services.navigationEngine.navigate(context: ctx) else { return XCTFail("ambiguous") }
        XCTAssertEqual(Set(ambiguous.map { $0.displayName.components(separatedBy: " ")[0] }), ["stripe", "paypal"])

        text = source(extra: "@Service @Profile(\"prod\") class Paypal implements Gateway {}")
        (url, _) = try await project(text, profiles: nil)
        doc = document(url, text, before: "gateway) { }", offset: 2)
        ctx = NavigationContext(document: doc, cursor: doc.cursor, selection: doc.selection, kind: .definition)
        guard case .multiple(let conditional)? = await services.navigationEngine.navigate(context: ctx) else { return XCTFail("conditional") }
        XCTAssertEqual(conditional.count, 2, "a conditional candidate is offered, not hidden")
    }

    func testTypeNameStillGoesToJavaNotSpring() async throws {
        let text = source(extra: "")
        let (url, _) = try await project(text)
        let doc = document(url, text, before: "Gateway gateway) { }", offset: 3)
        let ctx = NavigationContext(document: doc, cursor: doc.cursor, selection: doc.selection, kind: .definition)
        let result = await services.navigationEngine.navigate(context: ctx)
        if case .single(let loc)? = result { XCTAssertFalse(loc.displayName.hasPrefix("stripe")) }
    }

    // MARK: Diagnostics + code actions through the registry

    func testDiagnosticsReachTheEngineAndFixesApplyCleanly() async throws {
        let text = source(extra: "@Service class Paypal implements Gateway {}")
        let (url, indexer) = try await project(text)
        let doc = document(url, text, before: "gateway) { }", offset: 2)
        let report = await services.diagnosticEngine.diagnostics(for: doc)
        let spring = report.diagnostics.filter { $0.source == "Spring" }
        XCTAssertEqual(spring.map(\.code), ["spring.ambiguous-candidates"])

        let actions = await services.languages.codeActions.codeActions(for: doc, at: doc.cursor.position, diagnostics: report.diagnostics)
        let fix = try XCTUnwrap(actions.first { $0.title.contains("\"stripe\"") }, "titles: \(actions.map(\.title))")
        let fixed = apply(fix.edits, to: text)
        XCTAssertTrue(fixed.contains("Orders(@org.springframework.beans.factory.annotation.Qualifier(\"stripe\") Gateway gateway)"), fixed)

        await indexer.ingest(url: url, text: fixed)
        let after = await indexer.store.model()
        XCTAssertTrue(after.diagnostics.filter { $0.code == "spring.ambiguous-candidates" }.isEmpty)
        XCTAssertTrue(after.resolutions.values.contains { if case .resolved = $0 { return true } else { return false } })
    }

    func testNonSpringFilesAreUnaffected() async throws {
        let (_, _) = try await project(source(extra: ""))
        let other = root.appendingPathComponent("Other.java")
        let text = "class Other { void m(Missing x) {} }"
        try text.write(to: other, atomically: true, encoding: .utf8)
        let doc = document(other.standardizedFileURL, text, before: "x)")
        let report = await services.diagnosticEngine.diagnostics(for: doc)
        XCTAssertTrue(report.diagnostics.filter { $0.source == "Spring" }.isEmpty)
        let actions = await services.languages.codeActions.codeActions(for: doc, at: doc.cursor.position, diagnostics: [])
        XCTAssertFalse(actions.contains { $0.title.contains("@Qualifier") })
    }

    // MARK: Completion alongside Java and the generic providers

    func testQualifierCompletionAndCoexistenceWithJava() async throws {
        let text = source(extra: "@Service class Paypal implements Gateway {}", orders: "Orders(@org.springframework.beans.factory.annotation.Qualifier(\"\") Gateway gateway) { }")
        let (url, _) = try await project(text)
        let ns = text as NSString
        let inString = ns.range(of: "Qualifier(\"").location + "Qualifier(\"".count
        let sdoc = document(url, text, before: "Qualifier(\"", offset: "Qualifier(\"".count)
        _ = inString
        let sctx = CompletionContext(document: sdoc, cursor: sdoc.cursor, trigger: .manual, prefix: "",
                                     range: EditorIntelligence.TextRange(start: sdoc.cursor.position, end: sdoc.cursor.position))
        let items = try await services.completionEngine.complete(context: sctx)
        // The registry retags every item of a language with the language's name, so identify them by label.
        XCTAssertEqual(Set(items.map(\.label)).intersection(["stripe", "paypal"]), ["stripe", "paypal"],
                       "all items: \(items.map { "\($0.source):\($0.label)" })")
        XCTAssertEqual(items.filter { ["stripe", "paypal"].contains($0.label) }.count, 2, "no duplicates")

        // Ordinary code position: Java stays primary, Spring adds nothing.
        let cdoc = document(url, text, before: "Gateway gateway) { }", offset: 3)
        let cctx = CompletionContext(document: cdoc, cursor: cdoc.cursor, trigger: .manual, prefix: "Gat",
                                     range: EditorIntelligence.TextRange(start: cdoc.cursor.position, end: cdoc.cursor.position))
        let codeItems = try await services.completionEngine.complete(context: cctx)
        XCTAssertTrue(codeItems.filter { ["stripe", "paypal"].contains($0.label) }.isEmpty, "Spring adds nothing outside its annotations")
    }

    func testCancellationLeavesTheEngineUsable() async throws {
        let text = source(extra: "@Service class Paypal implements Gateway {}", orders: "Orders(@org.springframework.beans.factory.annotation.Qualifier(\"\") Gateway gateway) { }")
        let (url, _) = try await project(text)
        let doc = document(url, text, before: "Qualifier(\"", offset: "Qualifier(\"".count)
        let ctx = CompletionContext(document: doc, cursor: doc.cursor, trigger: .manual, prefix: "",
                                    range: EditorIntelligence.TextRange(start: doc.cursor.position, end: doc.cursor.position))
        let engine = services.completionEngine
        let task = Task { try await engine.complete(context: ctx) }
        task.cancel()
        _ = try? await task.value
        let again = try await engine.complete(context: ctx)
        XCTAssertTrue(again.contains { $0.label == "stripe" })
    }
}

// MARK: - Configuration files through the real registry and engines

@MainActor
final class SpringConfigEditorIntegrationTests: XCTestCase {
    private var root: URL!
    private var services: IDEIntelligenceServices!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spring-cfg-int-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/main/java/app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/main/resources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("meta/META-INF"), withIntermediateDirectories: true)
        services = IDEIntelligenceServices()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ rel: String, _ text: String) throws -> URL {
        let u = root.appendingPathComponent(rel)
        try text.write(to: u, atomically: true, encoding: .utf8)
        return u.standardizedFileURL
    }

    private func configure() async {
        let jar = URL(fileURLWithPath: "/h/.gradle/caches/modules-2/files-2.1/org.springframework/spring-context/6.1.2/x/spring-context-6.1.2.jar")
        let model = JavaGradleProjectModel(formatVersion: 9, gradleVersion: "8", subprojects: [
            .init(path: ":app", directory: root,
                  sourceSets: [.init(name: "main", sourceDirs: [root.appendingPathComponent("src/main/java")],
                                     outputDirs: [root.appendingPathComponent("meta")], compileClasspathJars: [jar])])])
        let indexer = services.javaSupport.springIndexer
        await indexer.configure(model: model)
        await indexer.waitForScan()
    }

    private func document(_ url: URL, _ text: String, at marker: String, offset: Int = 0) -> Document {
        let identifier = LanguageDefinitionRegistryLookup.identifier(forExtension: url.pathExtension)
        let ns = text as NSString
        let utf16 = ns.range(of: marker).location + offset
        let prefix = ns.substring(to: utf16)
        let line = prefix.filter { $0 == "\n" }.count
        let column = prefix.split(separator: "\n", omittingEmptySubsequences: false).last.map { $0.utf16.count } ?? 0
        let p = TextPosition(line: line, column: column, utf16Offset: utf16)
        return Document(url: url, displayName: url.lastPathComponent, contentSnapshot: TextSnapshot(version: 1, text: text),
                        selection: Selection(range: EditorIntelligence.TextRange(start: p, end: p)), cursor: Cursor(position: p),
                        viewport: Viewport(x: 0, y: 0, width: 1, height: 1), languageIdentifier: identifier)
    }

    func testPropertiesFilesAreClaimedByTheSpringConfigService() throws {
        XCTAssertEqual(LanguageDefinitionRegistryLookup.identifier(forExtension: "properties"), "properties")
        let services = IDEIntelligenceServices().languages.services(for: "properties")
        XCTAssertTrue(services.contains { $0.name == "umbra.spring-config" })
        XCTAssertTrue(IDEIntelligenceServices().languages.services(for: "yaml").contains { $0.name == "umbra.spring-config" })
    }

    func testCompletionHoverDiagnosticsAndFixThroughTheEngines() async throws {
        _ = try write("meta/META-INF/spring-configuration-metadata.json", SpringConfigTestMetadata.json)
        let text = "server.prot=1\nserver.port=abc\nserver.servlet.con\n"
        let props = try write("src/main/resources/application.properties", text)
        await configure()

        // Diagnostics through the diagnostic engine (with the dependency filter in the path).
        let d0 = document(props, text, at: "server.prot")
        let report = await services.diagnosticEngine.diagnostics(for: d0)
        let spring = report.diagnostics.filter { $0.source == "Spring" }
        XCTAssertEqual(Set(spring.compactMap(\.code)), ["spring.config.unknown-key", "spring.config.invalid-value"], "\(spring)")

        // Completion through the completion engine.
        let d1 = document(props, text, at: "server.servlet.con\n", offset: 18)
        let ctx = CompletionContext(document: d1, cursor: d1.cursor, trigger: .manual, prefix: "server.servlet.con",
                                    range: EditorIntelligence.TextRange(start: d1.cursor.position, end: d1.cursor.position))
        let items = try await services.completionEngine.complete(context: ctx)
        XCTAssertTrue(items.contains { $0.label == "server.servlet.context-path" }, "\(items.prefix(8).map(\.label))")
        XCTAssertFalse(items.contains { $0.label == "server.port" }, "keys already set in the file are not offered again")

        // Hover through the hover engine.
        let d2 = document(props, text, at: "port=abc", offset: 1)
        let hover = await services.hoverEngine.hover(context: HoverContext(document: d2, cursor: d2.cursor, selection: d2.selection))
        XCTAssertTrue(hover?.contents.contains("Server HTTP port.") == true, hover?.contents ?? "no hover")

        // Quick fix through the registry's routed code actions.
        let d3 = document(props, text, at: "prot", offset: 1)
        let actions = await services.languages.codeActions.codeActions(for: d3, at: d3.cursor.position, diagnostics: report.diagnostics)
        let fix = try XCTUnwrap(actions.first { $0.title.contains("'server.port'") }, "\(actions.map(\.title))")
        var ns = text as NSString
        let e = fix.edits[0]
        ns = ns.replacingCharacters(in: NSRange(location: e.range.start.utf16Offset, length: e.range.end.utf16Offset - e.range.start.utf16Offset), with: e.replacement) as NSString
        XCTAssertTrue((ns as String).hasPrefix("server.port=1\n"))
    }

    func testNavigationFromValuePlaceholderThroughTheEngine() async throws {
        _ = try write("meta/META-INF/spring-configuration-metadata.json", SpringConfigTestMetadata.json)
        let java = try write("src/main/java/app/U.java", "package app;\nimport org.springframework.beans.factory.annotation.Value;\nclass U { @Value(\"${app.name}\") String n; }\n")
        _ = try write("src/main/resources/application.properties", "app.name=x\n")
        await configure()
        let text = try String(contentsOf: java, encoding: .utf8)
        let d = document(java, text, at: "${app.name", offset: 5)
        guard case .single(let loc)? = await services.navigationEngine.navigate(context: NavigationContext(document: d, cursor: d.cursor, selection: d.selection, kind: .definition)) else { return XCTFail("no result") }
        XCTAssertEqual(loc.url?.lastPathComponent, "application.properties")
    }
}

enum LanguageDefinitionRegistryLookup {
    static func identifier(forExtension ext: String) -> String? { Penumbra.LanguageDefinitionRegistry.shared.identifier(forFileExtension: ext) }
}

enum SpringConfigTestMetadata {
    static let json = """
    {"properties":[
      {"name":"server.port","type":"java.lang.Integer","description":"Server HTTP port.","defaultValue":8080},
      {"name":"server.servlet.context-path","type":"java.lang.String"},
      {"name":"app.name","type":"java.lang.String"}]}
    """
}

// MARK: - Phase 4: reusable architecture exercised by Spring, through the real registry

@MainActor
final class SpringArchitectureIntegrationTests: XCTestCase {
    private var root: URL!
    private var services: IDEIntelligenceServices!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spring-arch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/main/java/app"), withIntermediateDirectories: true)
        services = IDEIntelligenceServices()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ name: String, _ text: String) throws -> URL {
        let u = root.appendingPathComponent("src/main/java/app/\(name).java")
        try text.write(to: u, atomically: true, encoding: .utf8)
        return u.standardizedFileURL
    }

    private func configure() async {
        let jar = URL(fileURLWithPath: "/h/.gradle/caches/modules-2/files-2.1/org.springframework/spring-context/6.1.2/x/spring-context-6.1.2.jar")
        let model = JavaGradleProjectModel(formatVersion: 9, gradleVersion: "8", subprojects: [
            .init(path: ":app", directory: root, sourceDirs: [root.appendingPathComponent("src/main/java")], compileClasspathJars: [jar])])
        await services.javaSupport.springIndexer.configure(model: model)
        await services.javaSupport.springIndexer.waitForScan()
    }

    private func document(_ url: URL, _ marker: String, offset: Int = 0) throws -> Document {
        let text = try String(contentsOf: url, encoding: .utf8)
        let ns = text as NSString
        let utf16 = ns.range(of: marker).location + offset
        let prefix = ns.substring(to: utf16)
        let p = TextPosition(line: prefix.filter { $0 == "\n" }.count,
                             column: prefix.split(separator: "\n", omittingEmptySubsequences: false).last.map { $0.utf16.count } ?? 0, utf16Offset: utf16)
        return Document(url: url, displayName: url.lastPathComponent, contentSnapshot: TextSnapshot(version: 1, text: text),
                        selection: Selection(range: EditorIntelligence.TextRange(start: p, end: p)), cursor: Cursor(position: p),
                        viewport: Viewport(x: 0, y: 0, width: 1, height: 1), languageIdentifier: "java")
    }

    /// What the host's preview sheet does with a plan once the user accepts it.
    private func accept(_ plan: WorkspaceEditPlan) throws {
        let edit = plan.workspaceEdit()
        for (url, edits) in edit.changes {
            var ns = try String(contentsOf: url, encoding: .utf8) as NSString
            for e in edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
                ns = ns.replacingCharacters(in: NSRange(location: e.range.start.utf16Offset, length: e.range.end.utf16Offset - e.range.start.utf16Offset), with: e.replacement) as NSString
            }
            try (ns as String).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func testFindUsagesOfABeanAddsItsInjectionPointsToTheLanguagesUsages() async throws {
        let a = try write("A", """
        package app;
        import org.springframework.stereotype.Service;
        interface Gateway {}
        @Service class Stripe implements Gateway {}
        @Service class Orders { Orders(Gateway gateway) {} }
        @Service class Billing { private final Gateway gw; Billing(Gateway gw) { this.gw = gw; } }
        """)
        await configure()
        let d = try document(a, "class Stripe", offset: 8)
        let result = await services.navigationEngine.navigate(context: NavigationContext(document: d, cursor: d.cursor, selection: d.selection, kind: .references))
        let locations = try XCTUnwrap(result?.locations)
        XCTAssertEqual(Set(locations.map(\.displayName)), ["orders.gateway", "billing.gw"], "\(locations.map(\.displayName))")
        XCTAssertTrue(locations.allSatisfy { $0.usage?.kindLabel == "Spring injection" })
        XCTAssertTrue(locations.allSatisfy { $0.usage?.isAmbiguous == false })
    }

    func testAmbiguousFixMakingABeanPrimaryIsPreviewedAndResolvesTheInjection() async throws {
        let a = try write("A", """
        package app;
        import org.springframework.stereotype.Service;
        interface Gateway {}
        @Service class Stripe implements Gateway {}
        @Service class Paypal implements Gateway {}
        @Service class Orders { Orders(Gateway gateway) {} }
        """)
        await configure()
        let d = try document(a, "Gateway gateway", offset: 10)
        let actions = await services.languages.codeActions.codeActions(for: d, at: d.cursor.position, diagnostics: [])
        let primary = try XCTUnwrap(actions.first { $0.title == "Make stripe the @Primary Gateway bean" }, "\(actions.map(\.title))")
        let plan = try XCTUnwrap(primary.workspacePlan)
        XCTAssertTrue(primary.edits.isEmpty, "nothing is edited in the open document; the change goes through the preview")
        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertTrue(plan.entries[0].lineText.contains("class Stripe"))
        XCTAssertNotNil(primary.preview)

        try accept(plan)
        let after = try String(contentsOf: a, encoding: .utf8)
        XCTAssertTrue(after.contains("@org.springframework.context.annotation.Primary\n@Service class Stripe"), after)
        await services.javaSupport.springIndexer.ingest(url: a, text: after)
        let model = await services.javaSupport.springIndexer.store.model()
        XCTAssertTrue(model.diagnostics.filter { $0.code == "spring.ambiguous-candidates" }.isEmpty)
        XCTAssertTrue(model.beans.first { $0.name == "stripe" }?.isPrimary == true)
    }

    func testMissingCandidateOffersToRegisterTheUnregisteredImplementation() async throws {
        let a = try write("A", """
        package app;
        import org.springframework.stereotype.Service;
        interface Gateway {}
        class Stripe implements Gateway {}
        @Service class Orders { Orders(Gateway gateway) {} }
        """)
        await configure()
        let d = try document(a, "Gateway gateway", offset: 10)
        let actions = await services.languages.codeActions.codeActions(for: d, at: d.cursor.position, diagnostics: [])
        let register = try XCTUnwrap(actions.first { $0.title == "Register Stripe as a Spring bean (@Component)" }, "\(actions.map(\.title))")
        try accept(try XCTUnwrap(register.workspacePlan))
        await services.javaSupport.springIndexer.ingest(url: a, text: try String(contentsOf: a, encoding: .utf8))
        let model = await services.javaSupport.springIndexer.store.model()
        XCTAssertTrue(model.diagnostics.filter { $0.code == "spring.no-candidate" }.isEmpty)
        XCTAssertEqual(model.beans.map(\.name).sorted(), ["orders", "stripe"])
    }
}
