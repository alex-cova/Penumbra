import XCTest
import EditorIntelligence
import JavaIntelligence
@testable import SpringIntelligence

final class SpringWorkspaceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func jar(_ group: String, _ artifact: String, _ version: String) -> URL {
        URL(fileURLWithPath: "/home/.gradle/caches/modules-2/files-2.1/\(group)/\(artifact)/\(version)/abc/\(artifact)-\(version).jar")
    }

    private func gradleModel(path: String = ":app", dir: URL, jars: [URL]) -> JavaGradleProjectModel {
        JavaGradleProjectModel(formatVersion: 9, gradleVersion: "8", subprojects: [
            .init(path: path, directory: dir, sourceDirs: [dir.appendingPathComponent("src/main/java")], compileClasspathJars: jars)
        ])
    }

    private func document(_ url: URL, _ source: String) -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            url: url, displayName: url.lastPathComponent,
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java")
    }

    private func write(_ relative: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.standardizedFileURL
    }

    func testDetectionReadsJarCoordinates() throws {
        let m = gradleModel(dir: root, jars: [
            jar("org.springframework.boot", "spring-boot", "3.2.1"),
            jar("org.springframework", "spring-context", "6.1.2"),
            jar("org.springframework", "spring-webmvc", "6.1.2"),
            jar("org.springframework.data", "spring-data-jpa", "3.2.1"),
        ])
        let found = SpringProjectDetector.detect(in: m)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].bootVersion, "3.2.1")
        XCTAssertEqual(found[0].frameworkVersion, "6.1.2")
        XCTAssertEqual(found[0].features, [.boot, .framework, .mvc, .dataJPA])
    }

    func testNonSpringProjectIsNotDetected() {
        let m = gradleModel(dir: root, jars: [jar("com.google.guava", "guava", "33.0"), jar("org.junit.jupiter", "junit-jupiter", "5.10")])
        XCTAssertTrue(SpringProjectDetector.detect(in: m).isEmpty)
    }

    func testOnlySpringModulesOfAMultiModuleBuildAreDetected() {
        let m = JavaGradleProjectModel(formatVersion: 9, gradleVersion: "8", subprojects: [
            .init(path: ":api", directory: root, sourceDirs: [root], compileClasspathJars: [jar("org.springframework", "spring-context", "6.1.2")]),
            .init(path: ":lib", directory: root, sourceDirs: [root], compileClasspathJars: [jar("com.google.guava", "guava", "33.0")]),
        ])
        XCTAssertEqual(SpringProjectDetector.detect(in: m).map(\.projectPath), [":api"])
    }

    func testIndexerIsInertWithoutSpringAndReadsNothing() async throws {
        _ = try write("src/main/java/app/A.java", "package app; class A {}")
        let indexer = SpringWorkspaceIndexer()
        await indexer.configure(model: gradleModel(dir: root, jars: [jar("com.google.guava", "guava", "33.0")]))
        await indexer.waitForScan()
        let active = await indexer.isActive
        XCTAssertFalse(active)
        let model = await indexer.store.model()
        XCTAssertTrue(model.beans.isEmpty)
    }

    func testIndexerScansSourcesAndProviderReportsInBufferText() async throws {
        let orders = try write("src/main/java/app/Orders.java", """
        package app;
        import org.springframework.stereotype.Service;
        @Service class Orders { Orders(Gateway g) {} }
        """)
        _ = try write("src/main/java/app/Gateway.java", "package app; interface Gateway {}")
        let indexer = SpringWorkspaceIndexer()
        await indexer.configure(model: gradleModel(dir: root, jars: [jar("org.springframework", "spring-context", "6.1.2")]))
        await indexer.waitForScan()

        let text = try String(contentsOf: orders, encoding: .utf8)
        let doc = document(orders, text)
        let found = await SpringDiagnosticProvider(indexer: indexer).diagnostics(for: doc)
        XCTAssertEqual(found.map(\.code), ["spring.no-candidate"])
        XCTAssertEqual(found[0].message, "No matching bean candidate for Gateway")
        XCTAssertEqual(found[0].range.start.line, 2)
        XCTAssertEqual(found[0].severity, .error)

        // An unsaved edit that adds an implementation elsewhere is not visible until ingested; ingesting
        // the implementing file clears the diagnostic.
        let impl = root.appendingPathComponent("src/main/java/app/Stripe.java").standardizedFileURL
        let changed = await indexer.ingest(url: impl, text: "package app; import org.springframework.stereotype.Service; @Service class Stripe implements Gateway {}")
        XCTAssertTrue(changed)
        let after = await SpringDiagnosticProvider(indexer: indexer).diagnostics(for: doc)
        XCTAssertTrue(after.isEmpty)
    }

    func testFilesOutsideSpringModulesGetNoDiagnostics() async throws {
        let outside = try write("other/X.java", "package x; import org.springframework.stereotype.*; @Service class X { X(Missing m) {} } interface Missing {}")
        let indexer = SpringWorkspaceIndexer()
        await indexer.configure(model: gradleModel(dir: root, jars: [jar("org.springframework", "spring-context", "6.1.2")]))
        await indexer.waitForScan()
        let doc = document(outside, try String(contentsOf: outside, encoding: .utf8))
        let found = await SpringDiagnosticProvider(indexer: indexer).diagnostics(for: doc)
        XCTAssertTrue(found.isEmpty)
    }
}

// MARK: - Phase 2: navigation, quick fixes, completion

final class SpringEditorFeatureTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spring2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/main/java/app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/main/resources"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("src/main/resources/application-staging.yml").path, contents: Data())
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private let service = """
    package app;
    import org.springframework.stereotype.Service;
    import org.springframework.context.annotation.Profile;
    interface Gateway {}
    @Service class Stripe implements Gateway {}
    @Service @Profile("prod") class Paypal implements Gateway {}
    @Service class Orders {
        private final Gateway gateway;
        Orders(Gateway gateway) { this.gateway = gateway; }
    }
    """

    private func makeIndexer(_ files: [String: String]) async throws -> (SpringWorkspaceIndexer, [String: URL]) {
        var urls: [String: URL] = [:]
        for (name, text) in files {
            let u = root.appendingPathComponent("src/main/java/app/\(name).java")
            try text.write(to: u, atomically: true, encoding: .utf8)
            urls[name] = u.standardizedFileURL
        }
        let jar = URL(fileURLWithPath: "/h/.gradle/caches/modules-2/files-2.1/org.springframework/spring-context/6.1.2/x/spring-context-6.1.2.jar")
        let model = JavaGradleProjectModel(formatVersion: 9, gradleVersion: "8", subprojects: [
            .init(path: ":app", directory: root, sourceDirs: [root.appendingPathComponent("src/main/java")], compileClasspathJars: [jar])])
        let indexer = SpringWorkspaceIndexer()
        await indexer.configure(model: model)
        await indexer.waitForScan()
        return (indexer, urls)
    }

    private func document(_ url: URL, _ text: String, caret: Int) -> Document {
        let r = SpringTextRanges(text: text)
        let p = r.position(text.utf8.count - (text as NSString).substring(from: caret).utf8.count)
        return Document(
            url: url, displayName: url.lastPathComponent, contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: p, end: p)), cursor: Cursor(position: p),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java")
    }

    func testGoToDefinitionOnInjectedNameFindsTheBean() async throws {
        let src = service.replacingOccurrences(of: "@Service @Profile(\"prod\") class Paypal implements Gateway {}\n", with: "")
        let (indexer, urls) = try await makeIndexer(["A": src])
        let caret = (src as NSString).range(of: "Gateway gateway) {").location + "Gateway ga".count
        let doc = document(urls["A"]!, src, caret: caret)
        let ctx = NavigationContext(document: doc, cursor: doc.cursor, selection: doc.selection, kind: .definition)
        guard case .single(let loc)? = await SpringNavigationProvider(indexer: indexer).provide(context: ctx) else { return XCTFail("no result") }
        XCTAssertTrue(loc.displayName.hasPrefix("stripe"))
        let line = src.components(separatedBy: "\n")[loc.range.start.line]
        XCTAssertTrue(line.contains("class Stripe"), line)
    }

    func testTypeNameIsLeftToJava() async throws {
        let (indexer, urls) = try await makeIndexer(["A": service])
        let caret = (service as NSString).range(of: "Orders(Gateway gateway)").location + "Orders(Gat".count
        let doc = document(urls["A"]!, service, caret: caret)
        let ctx = NavigationContext(document: doc, cursor: doc.cursor, selection: doc.selection, kind: .definition)
        let result = await SpringNavigationProvider(indexer: indexer).provide(context: ctx)
        XCTAssertNil(result)
    }

    func testAmbiguousInjectionOffersQualifierFixes() async throws {
        let (indexer, urls) = try await makeIndexer(["A": service])
        await indexer.store.setActiveProfiles(["prod"])
        let caret = (service as NSString).range(of: "Orders(Gateway gateway)").location + "Orders(Gat".count
        let doc = document(urls["A"]!, service, caret: caret)
        let all = await SpringCodeActionProvider(indexer: indexer).codeActions(for: doc, at: doc.cursor.position, diagnostics: [])
        XCTAssertEqual(Set(all.filter { $0.workspacePlan != nil }.map(\.title)), [
            "Make stripe the @Primary Gateway bean", "Make paypal the @Primary Gateway bean"], "cross-file fixes go through the preview")
        let actions = all.filter { $0.workspacePlan == nil }
        XCTAssertEqual(Set(actions.map(\.title)), [
            "Add @Qualifier(\"stripe\") to select Stripe bean", "Add @Qualifier(\"paypal\") to select Paypal bean"])
        let edit = try XCTUnwrap(actions.first?.edits.first)
        XCTAssertTrue(edit.replacement.hasPrefix("@org.springframework.beans.factory.annotation.Qualifier(\""))
        XCTAssertEqual(edit.range.start, edit.range.end, "an insertion, not a replacement")
        XCTAssertEqual(edit.range.start.line, 8)
        XCTAssertEqual(edit.range.start.column, "    Orders(".count)
    }

    func testUnknownQualifierOffersExistingBeanNames() async throws {
        let src = service.replacingOccurrences(of: "Orders(Gateway gateway)", with: "Orders(@Qualifier(\"nope\") Gateway gateway)")
            .replacingOccurrences(of: "import org.springframework.stereotype.Service;", with: "import org.springframework.stereotype.Service;\nimport org.springframework.beans.factory.annotation.Qualifier;")
        let (indexer, urls) = try await makeIndexer(["A": src])
        let caret = (src as NSString).range(of: "Gateway gateway)").location + 3
        let doc = document(urls["A"]!, src, caret: caret)
        let actions = await SpringCodeActionProvider(indexer: indexer).codeActions(for: doc, at: doc.cursor.position, diagnostics: [])
        XCTAssertTrue(actions.contains { $0.title == "Change qualifier 'nope' to 'stripe'" })
        let fix = try XCTUnwrap(actions.first { $0.title.hasSuffix("'stripe'") }).edits[0]
        XCTAssertEqual(fix.replacement, "@Qualifier(\"stripe\")")
    }

    func testQualifierAndProfileCompletion() async throws {
        let beanSrc = service.replacingOccurrences(of: "Orders(Gateway gateway)", with: "Orders(@Qualifier(\"\") Gateway gateway)")
        let (indexer, urls) = try await makeIndexer(["A": beanSrc])
        let provider = SpringCompletionProvider(indexer: indexer)

        func items(_ text: String, atMarker marker: String) async -> [String] {
            let caret = (text as NSString).range(of: marker).location + marker.count
            let doc = document(urls["A"]!, text, caret: caret)
            let ctx = CompletionContext(document: doc, cursor: doc.cursor, trigger: .manual, prefix: "", range: EditorIntelligence.TextRange(start: doc.cursor.position, end: doc.cursor.position))
            return await provider.provide(context: ctx).map(\.label)
        }
        let beans = await items(beanSrc, atMarker: "@Qualifier(\"")
        XCTAssertEqual(Set(beans), ["stripe", "paypal"])

        let profileSrc = service.replacingOccurrences(of: "@Profile(\"prod\") class", with: "@Profile(\"\") class")
        let profiles = await items(profileSrc, atMarker: "@Profile(\"")
        XCTAssertTrue(profiles.contains("staging"), "from application-staging.yml")
    }

    func testSiteDetection() {
        let t = "    Orders(@Resource(name = \"ab"
        XCTAssertEqual(SpringCompletionProvider.site(in: t, caretUTF16: (t as NSString).length)?.site, .beanName)
        XCTAssertNil(SpringCompletionProvider.site(in: "@Autowired Foo f = \"x", caretUTF16: 20))
        // The fully qualified spelling the quick fix itself writes.
        let q = "Orders(@org.springframework.beans.factory.annotation.Qualifier(\""
        XCTAssertEqual(SpringCompletionProvider.site(in: q, caretUTF16: (q as NSString).length)?.site, .beanName)
    }
}
