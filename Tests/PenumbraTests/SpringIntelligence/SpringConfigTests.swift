import XCTest
import EditorIntelligence
import JavaIntelligence
@testable import SpringIntelligence

/// Spring Boot configuration intelligence over a generated fixture project: real jar metadata, nested
/// `@ConfigurationProperties`, profiles, imports, deprecations and invalid values.
final class SpringConfigTests: XCTestCase {
    private var root: URL!
    private var indexer: SpringWorkspaceIndexer!

    // A trimmed but real-shaped `spring-configuration-metadata.json`.
    static let bootMetadata = """
    {"groups":[{"name":"server","type":"o.s.b.autoconfigure.web.ServerProperties"}],
     "properties":[
      {"name":"server.port","type":"java.lang.Integer","description":"Server HTTP port.","defaultValue":8080},
      {"name":"server.servlet.context-path","type":"java.lang.String","description":"Context path of the application."},
      {"name":"server.connection-timeout","type":"java.time.Duration","description":"Connection timeout."},
      {"name":"server.max-http-header-size","type":"org.springframework.util.unit.DataSize","defaultValue":"8KB"},
      {"name":"spring.application.name","type":"java.lang.String","description":"Application name."},
      {"name":"spring.datasource.url","type":"java.lang.String","description":"JDBC URL of the database."},
      {"name":"spring.datasource.username","type":"java.lang.String"},
      {"name":"spring.datasource.hikari","type":"com.zaxxer.hikari.HikariDataSource","description":"Hikari settings."},
      {"name":"spring.jpa.show-sql","type":"java.lang.Boolean","defaultValue":false,"description":"Whether to log SQL."},
      {"name":"spring.jpa.hibernate.ddl-auto","type":"java.lang.String"},
      {"name":"spring.profiles.active","type":"java.util.List<java.lang.String>"},
      {"name":"spring.config.import","type":"java.util.List<java.lang.String>"},
      {"name":"logging.level","type":"java.util.Map<java.lang.String,org.springframework.boot.logging.LogLevel>"},
      {"name":"server.servlet.session.timeout","type":"java.time.Duration"},
      {"name":"spring.redis.host","type":"java.lang.String","deprecation":{"level":"warning","reason":"Moved to spring.data.redis.","replacement":"spring.data.redis.host"}},
      {"name":"spring.data.redis.host","type":"java.lang.String","defaultValue":"localhost"}
     ],
     "hints":[{"name":"spring.jpa.hibernate.ddl-auto","values":[{"value":"none"},{"value":"validate"},{"value":"update"},{"value":"create"},{"value":"create-drop"}]}]}
    """

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spring-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        indexer = SpringWorkspaceIndexer()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    // MARK: Fixture helpers

    @discardableResult
    private func write(_ relative: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.standardizedFileURL
    }

    /// A Boot jar in a Gradle-cache-shaped path, with the metadata inside (built with the system `zip`).
    private func bootJar() throws -> URL {
        let dir = root.appendingPathComponent("gradle/modules-2/files-2.1/org.springframework.boot/spring-boot-autoconfigure/3.2.0/h")
        let staging = root.appendingPathComponent("staging/META-INF")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Self.bootMetadata.write(to: staging.appendingPathComponent("spring-configuration-metadata.json"), atomically: true, encoding: .utf8)
        let jar = dir.appendingPathComponent("spring-boot-autoconfigure-3.2.0.jar")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = root.appendingPathComponent("staging")
        p.arguments = ["-q", "-r", jar.path, "META-INF"]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return jar
    }

    private func springJars() throws -> [URL] {
        func jar(_ g: String, _ a: String, _ v: String) -> URL {
            URL(fileURLWithPath: "/h/.gradle/caches/modules-2/files-2.1/\(g)/\(a)/\(v)/x/\(a)-\(v).jar")
        }
        return [jar("org.springframework.boot", "spring-boot", "3.2.0"), jar("org.springframework", "spring-context", "6.1.1"), try bootJar()]
    }

    private func configure(modules: [String] = ["app"]) async throws {
        let jars = try springJars()
        let subs = modules.map { m in
            JavaGradleProjectModel.Subproject(
                path: ":\(m)", directory: root.appendingPathComponent(m),
                sourceDirs: [root.appendingPathComponent("\(m)/src/main/java")], compileClasspathJars: jars)
        }
        for m in modules { try FileManager.default.createDirectory(at: root.appendingPathComponent("\(m)/src/main/resources"), withIntermediateDirectories: true) }
        await indexer.configure(model: JavaGradleProjectModel(formatVersion: 9, gradleVersion: "8", subprojects: subs))
        await indexer.waitForScan()
    }

    private func doc(_ url: URL, _ text: String, at marker: String, offset: Int = 0, language: String? = nil) -> Document {
        let ns = text as NSString
        let utf16 = ns.range(of: marker).location + offset
        let prefix = ns.substring(to: utf16)
        let line = prefix.filter { $0 == "\n" }.count
        let column = prefix.split(separator: "\n", omittingEmptySubsequences: false).last.map { $0.utf16.count } ?? 0
        let p = TextPosition(line: line, column: column, utf16Offset: utf16)
        return Document(
            url: url, displayName: url.lastPathComponent, contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: p, end: p)), cursor: Cursor(position: p),
            viewport: Viewport(x: 0, y: 0, width: 1, height: 1),
            languageIdentifier: language ?? (url.pathExtension == "java" ? "java" : url.pathExtension == "properties" ? "properties" : "yaml"))
    }

    private func codes(_ url: URL) async -> [String: [String]] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let d = doc(url, text, at: text.isEmpty ? "" : String(text.prefix(1)))
        var out: [String: [String]] = [:]
        for x in await SpringConfigDiagnosticProvider(indexer: indexer).diagnostics(for: d) { out[x.code ?? "", default: []].append(x.message) }
        return out
    }

    // MARK: Metadata

    func testMetadataLookupAndRelaxedBinding() throws {
        let m = try XCTUnwrap(SpringConfigMetadata.parse(json: Data(Self.bootMetadata.utf8), origin: "boot"))
        guard case .exact(let port) = m.match("server.port") else { return XCTFail() }
        XCTAssertEqual(port.defaultValue, "8080")
        for variant in ["Server.Port", "server.PORT", "SERVER.port"] {
            if case .exact = m.match(variant) {} else { XCTFail(variant) }
        }
        if case .exact = m.match("server.servlet.contextPath") {} else { XCTFail("camelCase leaf") }
        if case .exact = m.match("server.servlet.context_path") {} else { XCTFail("underscore notation") }
        if case .exact = m.match("server.max-http-header-size") {} else { XCTFail("kebab") }
        if case .opaque = m.match("logging.level.com.acme.Foo") {} else { XCTFail("map entries are open") }
        if case .opaque = m.match("spring.datasource.hikari.maximum-pool-size") {} else { XCTFail("unexpanded class is open") }
        if case .group = m.match("spring.datasource") {} else { XCTFail() }
        if case .unknown = m.match("server.prot") {} else { XCTFail("typo under a known group") }
        if case .foreign = m.match("acme.custom.thing") {} else { XCTFail("library without metadata is never judged") }
        if case .unknown = m.match("server.port.extra") {} else { XCTFail("child of a leaf") }
        XCTAssertEqual(m.hints["spring.jpa.hibernate.ddlauto"]?.count, 5)
    }

    // MARK: Diagnostics

    func testDiagnosticsOverPropertiesAndYAML() async throws {
        let props = try write("app/src/main/resources/application.properties", """
        server.port=eighty
        server.prot=9000
        spring.jpa.show-sql=maybe
        server.connection-timeout=30x
        server.max-http-header-size=16MB
        spring.redis.host=localhost
        spring.application.name=${missing.name}
        spring.datasource.url=jdbc:h2:${db.path:mem}
        logging.level.com.acme=DEBUG
        server.port=81
        acme.custom=1
        """)
        try await configure()
        let got = await codes(props)
        XCTAssertEqual(got["spring.config.invalid-value"]?.count, 3, "\(got)")
        XCTAssertTrue(got["spring.config.invalid-value"]!.contains { $0.contains("'eighty' is not a whole number") })
        XCTAssertTrue(got["spring.config.invalid-value"]!.contains { $0.contains("'maybe' is not a boolean") })
        XCTAssertTrue(got["spring.config.invalid-value"]!.contains { $0.contains("'30x' is not a duration") })
        XCTAssertEqual(got["spring.config.unknown-key"], ["Unknown property 'server.prot'. Did you mean 'server.port'?"])
        XCTAssertEqual(got["spring.config.deprecated"]?.count, 1)
        XCTAssertTrue(got["spring.config.deprecated"]![0].contains("Use 'spring.data.redis.host' instead."))
        XCTAssertEqual(got["spring.config.duplicate-key"]?.count, 1)
        XCTAssertEqual(got["spring.config.unresolved-placeholder"]?.count, 1, "default-bearing and defined placeholders are fine: \(got)")
        XCTAssertTrue(got["spring.config.unresolved-placeholder"]![0].contains("'missing.name'"))
        XCTAssertNil(got["spring.config.unknown-key"]?.first { $0.contains("acme") }, "third-party keys are not judged")
    }

    func testYAMLDiagnosticsRangesPointAtTheOffendingText() async throws {
        let text = "server:\n  port: abc\n  prot: 1\n"
        let yml = try write("app/src/main/resources/application.yml", text)
        try await configure()
        let d = doc(yml, text, at: "server")
        let found = await SpringConfigDiagnosticProvider(indexer: indexer).diagnostics(for: d)
        let invalid = try XCTUnwrap(found.first { $0.code == "spring.config.invalid-value" })
        XCTAssertEqual(invalid.range.start.line, 1)
        XCTAssertEqual(invalid.range.start.column, "  port: ".count)
        let unknown = try XCTUnwrap(found.first { $0.code == "spring.config.unknown-key" })
        XCTAssertEqual(unknown.range.start.line, 2)
        XCTAssertEqual(unknown.range.start.column, 2)
    }

    func testProjectConfigurationPropertiesDriveKeysAndBindingChecks() async throws {
        try write("app/src/main/java/app/MailProperties.java", """
        package app;
        import org.springframework.boot.context.properties.ConfigurationProperties;
        @ConfigurationProperties(prefix = "app.mail")
        public class MailProperties {
            private String host; private int port; private boolean enabled;
            private Retry retry = new Retry();
            @Deprecated private String legacyFrom;
            public static class Retry { private int maxAttempts; private java.time.Duration backoff; }
        }
        @ConfigurationProperties("appBad") class Bad { private String x; }
        """)
        let yml = try write("app/src/main/resources/application.yml", """
        app:
          mail:
            host: smtp
            port: ten
            retry:
              max-attempts: 3
              backoff: 2s
              maxAtempts: 4
            legacy-from: a@b
        """)
        try await configure()
        let got = await codes(yml)
        XCTAssertEqual(got["spring.config.invalid-value"]?.count, 1, "\(got)")
        XCTAssertEqual(got["spring.config.unknown-key"]?.count, 1)
        XCTAssertTrue(got["spring.config.unknown-key"]![0].contains("Did you mean 'app.mail.retry.max-attempts'?"))
        XCTAssertEqual(got["spring.config.deprecated"]?.count, 1)
        let model = await indexer.store.model()
        XCTAssertTrue(model.diagnostics.contains { $0.code == "spring.config.invalid-prefix" && $0.message.contains("appBad") })
        XCTAssertTrue(model.configurationProperties.contains { $0.name == "app.mail.retry.max-attempts" && $0.type == "int" })
    }

    // MARK: Profiles, precedence, imports

    func testEffectiveValueFollowsProfilePrecedence() async throws {
        try write("app/src/main/resources/application.yml", "server:\n  port: 1\nspring:\n  profiles:\n    active: prod\n")
        try write("app/src/main/resources/application.properties", "spring.application.name=base\n")
        try write("app/src/main/resources/application-prod.yml", "server.port: 2\n")
        try write("app/src/main/resources/application-dev.yml", "server.port: 3\n")
        try await configure()
        let config = await indexer.store.config()
        XCTAssertEqual(config.activeProfiles, ["prod"])
        let eff = try XCTUnwrap(config.effective(key: "server.port"))
        XCTAssertEqual(eff.winner.entry.value, "2")
        XCTAssertEqual(eff.overridden.map { $0.entry.value }, ["1"])
        XCTAssertEqual(eff.inactive.map { $0.profile }, ["dev"])
        XCTAssertFalse(eff.profilesAssumed)

        await indexer.store.setActiveProfiles(["dev"])
        let dev = await indexer.store.config()
        XCTAssertEqual(dev.effective(key: "server.PORT")?.winner.entry.value, "3", "relaxed binding finds the same property")
    }

    func testMultiDocumentYAMLProfileActivation() async throws {
        try write("app/src/main/resources/application.yml", "server.port: 1\n---\nspring.config.activate.on-profile: qa\nserver.port: 9\n")
        try await configure()
        await indexer.store.setActiveProfiles(["qa"])
        let config = await indexer.store.config()
        XCTAssertEqual(config.effective(key: "server.port")?.winner.entry.value, "9")
        await indexer.store.setActiveProfiles([])
        let base = await indexer.store.config()
        XCTAssertEqual(base.effective(key: "server.port")?.winner.entry.value, "1")
    }

    func testImportsAreFollowedAndMissingOnesReported() async throws {
        let main = try write("app/src/main/resources/application.properties", """
        spring.config.import=optional:file:./extra.properties,classpath:shared.yml,file:./gone.properties
        """)
        try write("app/src/main/resources/shared.yml", "shared:\n  flag: true\n")
        try write("app/src/main/resources/extra.properties", "extra.key=1\n")
        try await configure()
        let config = await indexer.store.config()
        XCTAssertTrue(config.definesKey("shared.flag"), "classpath: import resolved through resource roots")
        XCTAssertTrue(config.definesKey("extra.key"), "optional: import followed when present")
        let got = await codes(main)
        XCTAssertEqual(got["spring.config.missing-import"]?.count, 1)
        XCTAssertTrue(got["spring.config.missing-import"]![0].contains("gone.properties"))
    }

    // MARK: Hover

    func testHoverShowsMetadataEffectiveValueAndOrigin() async throws {
        let text = "server.port=9\n"
        let base = try write("app/src/main/resources/application.properties", text)
        try write("app/src/main/resources/application-prod.properties", "server.port=10\n")
        try await configure()
        await indexer.store.setActiveProfiles(["prod"])
        let d = doc(base, text, at: "port")
        let maybeHover = await SpringConfigHoverProvider(indexer: indexer).provide(context: HoverContext(document: d, cursor: d.cursor, selection: d.selection))
        let hover = try XCTUnwrap(maybeHover)
        XCTAssertTrue(hover.contents.contains("`java.lang.Integer`"))
        XCTAssertTrue(hover.contents.contains("Server HTTP port."))
        XCTAssertTrue(hover.contents.contains("Default: `8080`"))
        XCTAssertTrue(hover.contents.contains("effective value is `10` from application-prod.properties:1"), hover.contents)
        XCTAssertTrue(hover.contents.contains("Metadata: spring-boot-autoconfigure-3.2.0.jar"))
        XCTAssertTrue(hover.contents.contains("Environment variables"))
    }

    // MARK: Completion

    private func complete(_ url: URL, _ text: String, at marker: String, offset: Int = 0) async -> [CompletionItem] {
        let d = doc(url, text, at: marker, offset: offset)
        let ctx = CompletionContext(document: d, cursor: d.cursor, trigger: .manual, prefix: "",
                                    range: EditorIntelligence.TextRange(start: d.cursor.position, end: d.cursor.position))
        return await SpringConfigCompletionProvider(indexer: indexer).provide(context: ctx)
    }

    func testPropertiesKeyAndValueCompletion() async throws {
        let text = "server.po\nspring.jpa.hibernate.ddl-auto=\nspring.jpa.show-sql=\nspring.application.name=${spring.app\n"
        let url = try write("app/src/main/resources/application.properties", text)
        try await configure()
        let keys = await complete(url, text, at: "server.po", offset: 9)
        XCTAssertTrue(keys.contains { $0.label == "server.port" && $0.insertText == "server.port=" && $0.detail == "Integer" })
        XCTAssertFalse(keys.contains { $0.label.hasPrefix("spring.") })
        let hints = await complete(url, text, at: "ddl-auto=", offset: 9)
        XCTAssertEqual(Set(hints.map(\.label)), ["none", "validate", "update", "create", "create-drop"])
        let bools = await complete(url, text, at: "show-sql=", offset: 9)
        XCTAssertEqual(Set(bools.map(\.label)), ["true", "false"])
        let placeholders = await complete(url, text, at: "${spring.app", offset: 12)
        XCTAssertTrue(placeholders.contains { $0.label == "spring.application.name" })
    }

    func testYAMLNestedKeyCompletionUsesTheParentPath() async throws {
        let text = "spring:\n  jpa:\n    sh\n  datasource:\n    "
        let url = try write("app/src/main/resources/application.yml", text)
        try await configure()
        let jpa = await complete(url, text, at: "    sh", offset: 6)
        XCTAssertEqual(jpa.map(\.label), ["show-sql"])
        XCTAssertEqual(jpa.first?.insertText, "show-sql: ")
        let top = "ser"
        let url2 = try write("app/src/main/resources/application-dev.yml", top)
        await indexer.rescan(); await indexer.waitForScan()
        let roots = await complete(url2, top, at: "ser", offset: 3)
        XCTAssertTrue(roots.contains { $0.label == "server" && $0.insertText == "server:" && $0.detail == "group" })
    }

    func testProfileCompletionAndDeprecatedKeysNameTheirReplacement() async throws {
        try write("app/src/main/resources/application-staging.yml", "x: 1\n")
        let text = "spring.profiles.active=\nspring.redis.\n"
        let url = try write("app/src/main/resources/application.properties", text)
        try await configure()
        let profiles = await complete(url, text, at: "active=", offset: 7)
        XCTAssertTrue(profiles.contains { $0.label == "staging" })
        let dep = await complete(url, text, at: "spring.redis.", offset: 13)
        let host = try XCTUnwrap(dep.first { $0.label == "spring.redis.host" })
        XCTAssertTrue(host.isDeprecated)
        XCTAssertEqual(host.detail, "deprecated → spring.data.redis.host")
    }

    // MARK: Navigation

    func testNavigationBothWaysBetweenKeysAndJava() async throws {
        let java = try write("app/src/main/java/app/Props.java", """
        package app;
        import org.springframework.beans.factory.annotation.Value;
        import org.springframework.boot.context.properties.ConfigurationProperties;
        @ConfigurationProperties(prefix = "app.mail")
        class MailProps { private String host; }
        class Uses { @Value("${app.mail.host:x}") String h; }
        """)
        let ymlText = "app:\n  mail:\n    host: smtp\n"
        let yml = try write("app/src/main/resources/application.yml", ymlText)
        let prod = try write("app/src/main/resources/application-prod.yml", "app.mail.host: prod-smtp\n")
        try await configure()
        let nav = SpringConfigNavigationProvider(indexer: indexer)

        // key → Java: the bound field and the @Value usage.
        let kd = doc(yml, ymlText, at: "host", offset: 1)
        guard case .multiple(let toJava)? = await nav.provide(context: NavigationContext(document: kd, cursor: kd.cursor, selection: kd.selection, kind: .definition)) else { return XCTFail("key → java") }
        XCTAssertEqual(toJava.count, 2, "the bound field and the @Value usage: \(toJava.map(\.displayName))")
        XCTAssertTrue(toJava.contains { $0.displayName.hasPrefix("app.mail.host — app.MailProps") })
        XCTAssertTrue(toJava.contains { $0.displayName.hasPrefix("@Value") })

        // The `mail` group segment leads to the @ConfigurationProperties class that owns the prefix.
        let gd = doc(yml, ymlText, at: "mail", offset: 1)
        guard case .single(let toClass)? = await nav.provide(context: NavigationContext(document: gd, cursor: gd.cursor, selection: gd.selection, kind: .definition)) else { return XCTFail("group → class") }
        XCTAssertTrue(toClass.displayName.contains("app.MailProps"), toClass.displayName)

        // @Value placeholder → every file that sets the key (base and profile).
        let javaText = try String(contentsOf: java, encoding: .utf8)
        let vd = doc(java, javaText, at: "${app.mail.host", offset: 8)
        guard case .multiple(let toFiles)? = await nav.provide(context: NavigationContext(document: vd, cursor: vd.cursor, selection: vd.selection, kind: .definition)) else { return XCTFail("@Value → files") }
        XCTAssertEqual(Set(toFiles.compactMap { $0.url }), [yml, prod])

        // @ConfigurationProperties prefix → entries below it.
        let pd = doc(java, javaText, at: "\"app.mail\"", offset: 4)
        guard case .multiple(let underPrefix)? = await nav.provide(context: NavigationContext(document: pd, cursor: pd.cursor, selection: pd.selection, kind: .definition)) else { return XCTFail("prefix") }
        XCTAssertEqual(underPrefix.count, 2)
    }

    // MARK: Quick fixes

    func testDeprecatedAndMisspeltKeyFixes() async throws {
        let text = "spring.redis.host=h\nserver.prot=1\n"
        let url = try write("app/src/main/resources/application.properties", text)
        try await configure()
        let provider = SpringConfigCodeActionProvider(indexer: indexer)
        let d1 = doc(url, text, at: "redis")
        let a1 = await provider.codeActions(for: d1, at: d1.cursor.position, diagnostics: [])
        XCTAssertEqual(a1.map(\.title), ["Replace deprecated 'spring.redis.host' with 'spring.data.redis.host'"])
        let e = try XCTUnwrap(a1.first?.edits.first)
        XCTAssertEqual(e.replacement, "spring.data.redis.host")
        XCTAssertEqual(e.range.start.line, 0)
        XCTAssertEqual(e.range.end.column, "spring.redis.host".count)
        let d2 = doc(url, text, at: "prot")
        let a2 = await provider.codeActions(for: d2, at: d2.cursor.position, diagnostics: [])
        XCTAssertEqual(a2.map(\.title), ["Change 'server.prot' to 'server.port'"])
    }

    // MARK: Multi-module and non-Spring

    func testModulesKeepTheirOwnConfigurationFiles() async throws {
        try write("a/src/main/resources/application.properties", "server.port=1\n")
        try write("b/src/main/resources/application.properties", "server.port=2\n")
        try await configure(modules: ["a", "b"])
        let config = await indexer.store.config()
        XCTAssertEqual(config.files.count, 2)
        let infos = await indexer.modules
        XCTAssertEqual(infos.map(\.projectPath), [":a", ":b"])
        XCTAssertTrue(infos.allSatisfy { !$0.resourceRoots.isEmpty })
    }

    func testNonSpringProjectReadsNoConfigurationAndLoadsNoMetadata() async throws {
        try write("app/src/main/resources/application.properties", "server.port=1\n")
        let none = JavaGradleProjectModel(formatVersion: 9, gradleVersion: "8", subprojects: [
            .init(path: ":app", directory: root.appendingPathComponent("app"), sourceDirs: [root.appendingPathComponent("app/src/main/java")], compileClasspathJars: [])])
        await indexer.configure(model: none)
        await indexer.waitForScan()
        let config = await indexer.store.config()
        XCTAssertTrue(config.files.isEmpty)
        XCTAssertTrue(config.metadata.isEmpty)
    }
}
