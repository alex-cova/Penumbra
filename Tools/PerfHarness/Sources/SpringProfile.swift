import EditorIntelligence
import Foundation
import JavaIntelligence
import SpringIntelligence

/// Release-mode cost of the Spring layer on a generated project (real files, the real indexer):
///
///   swift run -c release PerfHarness spring synthetic [--beans N] [--config-lines N] [--jar <spring-boot-autoconfigure.jar>]
///
/// Reports: detection on a non-Spring classpath (the cost every Java project pays), initial indexing, model
/// build, incremental updates (a method-body edit, an annotation edit), profile switching, configuration
/// metadata load, key completion, config diagnostics, and resident memory before and after.
enum SpringProfile {
    static func run(beans: Int, configLines: Int, bootJar: String?) throws {
        try runBlocking { try await measure(beans: beans, configLines: configLines, bootJar: bootJar) }
    }

    fileprivate static func resident() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    fileprivate static func ms(_ d: Duration) -> Double { (Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * 1000 }
    fileprivate static func fmt(_ x: Double) -> String { String(format: "%.2f", x) }

    private static func measure(beans: Int, configLines: Int, bootJar: String?) async throws {
        note("=== spring (synthetic, \(beans) beans, \(configLines)-line config\(bootJar.map { ", jar \((($0) as NSString).lastPathComponent)" } ?? "")) ===")
        let clock = ContinuousClock()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perf-spring-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let javaDir = root.appendingPathComponent("src/main/java/app"), resources = root.appendingPathComponent("src/main/resources")
        try FileManager.default.createDirectory(at: javaDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        // Generated sources: `beans` services in 40 packages-worth of files, each injecting three earlier beans.
        for i in 0..<beans {
            let deps = [i - 1, i - 7, i - 31].filter { $0 >= 0 }.map { "Svc\($0) d\($0)" }.joined(separator: ", ")
            let body = (0..<12).map { "        int v\($0) = compute(\($0)) + \(i);" }.joined(separator: "\n")
            try """
            package app;
            import org.springframework.stereotype.Service;
            @Service
            class Svc\(i) {
                Svc\(i)(\(deps)) {}
                int compute(int x) {
            \(body)
                    return x;
                }
            }
            """.write(to: javaDir.appendingPathComponent("Svc\(i).java"), atomically: true, encoding: .utf8)
        }
        let lines = (0..<configLines).map { i -> String in
            switch i % 5 {
            case 0: return "app.module\(i / 5).name=value\(i)"
            case 1: return "app.module\(i / 5).enabled=true"
            case 2: return "spring.datasource.hikari.maximum-pool-size=\(i)"
            case 3: return "server.servlet.context-path=/c\(i)"
            default: return "logging.level.com.acme.p\(i)=DEBUG"
            }
        }
        try lines.joined(separator: "\n").write(to: resources.appendingPathComponent("application.properties"), atomically: true, encoding: .utf8)

        // 1. What a project WITHOUT Spring pays: one pass over its jar names.
        let plainJars = (0..<400).map { URL(fileURLWithPath: "/h/.gradle/caches/modules-2/files-2.1/org.g\($0 % 40)/lib\($0)/1.\($0)/h/lib\($0)-1.\($0).jar") }
        let plain = JavaGradleProjectModel(formatVersion: 9, gradleVersion: "8", subprojects: [
            .init(path: ":app", directory: root, sourceDirs: [javaDir], compileClasspathJars: plainJars)])
        var detectSamples: [Double] = []
        for _ in 0..<50 { let t = clock.now; _ = SpringProjectDetector.detect(in: plain); detectSamples.append(ms(clock.now - t)) }
        note("non-Spring classpath, 400 jars: detect \(fmt(median(detectSamples))) ms (no file read)")

        // 2. Spring project: real indexer over real files.
        var jars = [URL(fileURLWithPath: "/h/.gradle/caches/modules-2/files-2.1/org.springframework/spring-context/6.1.2/x/spring-context-6.1.2.jar")]
        if let bootJar { jars.append(URL(fileURLWithPath: bootJar)) }
        let model = JavaGradleProjectModel(formatVersion: 9, gradleVersion: "8", subprojects: [
            .init(path: ":app", directory: root, sourceDirs: [root.appendingPathComponent("src/main/java")], compileClasspathJars: jars)])
        let memoryBefore = resident()
        let indexer = SpringWorkspaceIndexer()
        let t0 = clock.now
        await indexer.configure(model: model)
        await indexer.waitForScan()
        let indexing = ms(clock.now - t0)
        let t1 = clock.now
        let java = await indexer.store.model()
        let build = ms(clock.now - t1)
        note("initial index (parse \(beans) files + metadata + config): \(fmt(indexing)) ms (\(fmt(indexing / Double(beans))) ms/file)")
        note("model build: \(fmt(build)) ms — \(java.beans.count) beans, \(java.injectionPoints.count) injection points, \(java.diagnostics.count) diagnostics")
        let memoryAfter = resident()
        note("resident memory: \(fmt(memoryBefore)) → \(fmt(memoryAfter)) MB (+\(fmt(memoryAfter - memoryBefore)) MB, includes transient parse buffers)")

        // 3. Incremental updates on one file.
        let file = javaDir.appendingPathComponent("Svc100.java").standardizedFileURL
        let original = try String(contentsOf: file, encoding: .utf8)
        var bodyEdit: [Double] = [], bodyModel: [Double] = [], annEdit: [Double] = []
        for i in 0..<20 {
            let edited = original.replacingOccurrences(of: "int v0 = compute(0)", with: "int v0 = compute(\(i + 1))")
            let t = clock.now; _ = await indexer.ingest(url: file, text: edited); bodyEdit.append(ms(clock.now - t))
            let m = clock.now; _ = await indexer.store.model(); bodyModel.append(ms(clock.now - m))
        }
        for i in 0..<10 {
            let edited = original.replacingOccurrences(of: "@Service\n", with: i % 2 == 0 ? "@Service\n@Lazy\n" : "@Service\n")
            let t = clock.now; _ = await indexer.ingest(url: file, text: edited); _ = await indexer.store.model(); annEdit.append(ms(clock.now - t))
        }
        note("edit not touching Spring metadata (method body): ingest \(fmt(median(bodyEdit))) ms + model \(fmt(median(bodyModel))) ms (model cached)")
        note("edit changing a bean definition: ingest + model rebuild \(fmt(median(annEdit))) ms")

        var profileSamples: [Double] = []
        for i in 0..<10 { let t = clock.now; await indexer.store.setActiveProfiles(i % 2 == 0 ? ["prod"] : ["dev"]); _ = await indexer.store.model(); profileSamples.append(ms(clock.now - t)) }
        note("profile switch (model rebuild): \(fmt(median(profileSamples))) ms")

        // 4. Configuration: metadata, completion, diagnostics.
        let config = await indexer.store.config()
        note("configuration: \(config.files.count) file(s), \(config.files.first?.entries.count ?? 0) entries, \(config.metadata.properties.count) metadata properties")
        let url = resources.appendingPathComponent("application.properties").standardizedFileURL
        let text = try String(contentsOf: url, encoding: .utf8) + "\nserver.po"
        let at = (text as NSString).length
        let p = TextPosition(line: configLines, column: 9, utf16Offset: at)
        let doc = Document(url: url, displayName: "application.properties", contentSnapshot: TextSnapshot(version: 1, text: text),
                           selection: Selection(range: EditorIntelligence.TextRange(start: p, end: p)), cursor: Cursor(position: p),
                           viewport: Viewport(x: 0, y: 0, width: 1, height: 1), languageIdentifier: "properties")
        let ctx = CompletionContext(document: doc, cursor: doc.cursor, trigger: .manual, prefix: "server.po", range: EditorIntelligence.TextRange(start: p, end: p))
        let provider = SpringConfigCompletionProvider(indexer: indexer)
        var completion: [Double] = []
        var items = 0
        _ = await provider.provide(context: ctx)   // first call ingests the buffer (parse + config rebuild)
        for _ in 0..<30 { let t = clock.now; items = await provider.provide(context: ctx).count; completion.append(ms(clock.now - t)) }
        note("key completion (\(config.metadata.properties.count) props): median \(fmt(median(completion))) ms, p95 \(fmt(percentile(completion, 0.95))) ms, \(items) items")
        let diagnosticsProvider = SpringConfigDiagnosticProvider(indexer: indexer)
        var diag: [Double] = []
        var found = 0
        for _ in 0..<10 { let t = clock.now; found = await diagnosticsProvider.diagnostics(for: doc).count; diag.append(ms(clock.now - t)) }
        note("config diagnostics (\(configLines) lines): median \(fmt(median(diag))) ms, \(found) findings")
        // 5. What ordinary Java completion pays for Spring's provider (same tier as Java's): a 20,000-line file,
        //    caret in plain code, so the provider answers [] after its textual check.
        let big = (0..<20_000).map { "    int field\($0) = \($0); // line" }.joined(separator: "\n")
        let javaText = "package app;\nclass Big {\n\(big)\n    void m() { fie }\n}\n"
        let caret = (javaText as NSString).range(of: "fie }").location + 3
        let jp = TextPosition(line: 20_002, column: 15, utf16Offset: caret)
        let javaURL = javaDir.appendingPathComponent("Svc0.java").standardizedFileURL
        let javaDoc = Document(url: javaURL, displayName: "Big.java", contentSnapshot: TextSnapshot(version: 1, text: javaText),
                               selection: Selection(range: EditorIntelligence.TextRange(start: jp, end: jp)), cursor: Cursor(position: jp),
                               viewport: Viewport(x: 0, y: 0, width: 1, height: 1), languageIdentifier: "java")
        let jctx = CompletionContext(document: javaDoc, cursor: javaDoc.cursor, trigger: .keystroke("e"), prefix: "fie",
                                     range: EditorIntelligence.TextRange(start: jp, end: jp))
        let springJava = SpringCompletionProvider(indexer: indexer)
        var extra: [Double] = []
        for _ in 0..<30 { let t = clock.now; _ = await springJava.provide(context: jctx); extra.append(ms(clock.now - t)) }
        note("Spring's cost on an ordinary Java completion (20,000-line file): median \(fmt(median(extra))) ms, p95 \(fmt(percentile(extra, 0.95))) ms")
        note("resident at end: \(fmt(resident())) MB")
        try await measureExplorer(beans: beans)
    }

    fileprivate static func note(_ text: String) { FileHandle.standardError.write("\(text)\n".data(using: .utf8)!) }

    private static func runBlocking(_ body: @escaping @Sendable () async throws -> Void) throws {
        let box = SpringBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { try await body() } catch { box.error = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = box.error { throw error }
    }

    fileprivate static func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
    fileprivate static func percentile(_ xs: [Double], _ p: Double) -> Double { xs.sorted()[min(xs.count - 1, Int(Double(xs.count) * p))] }
}

private final class SpringBox: @unchecked Sendable { var error: Error? }

extension SpringProfile {
    /// The tool window's data layer over a three-module application with `beans` services spread across the modules.
    fileprivate static func measureExplorer(beans: Int) async throws {
        let clock = ContinuousClock()
        note("--- explorer (3 modules, \(beans) beans) ---")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perf-spring-x-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        func dir(_ m: Int) -> URL { root.appendingPathComponent("m\(m)/src/main/java") }
        for m in 0..<3 { try FileManager.default.createDirectory(at: dir(m), withIntermediateDirectories: true) }
        try """
        package app;
        import org.springframework.boot.autoconfigure.SpringBootApplication;
        @SpringBootApplication(scanBasePackages = "app") public class App {}
        """.write(to: dir(0).appendingPathComponent("App.java"), atomically: true, encoding: .utf8)
        for i in 0..<beans {
            let deps = [i - 1, i - 7, i - 31].filter { $0 >= 0 }.map { "Svc\($0) d\($0)" }.joined(separator: ", ")
            let kind = i % 11 == 0 ? "@Controller" : i % 7 == 0 ? "@Repository" : "@Service"
            try """
            package app;
            import org.springframework.stereotype.*;
            \(kind) class Svc\(i) { Svc\(i)(\(deps)) { int x = \(i); } }
            """.write(to: dir(i % 3).appendingPathComponent("Svc\(i).java"), atomically: true, encoding: .utf8)
        }
        let jar = URL(fileURLWithPath: "/h/.gradle/caches/modules-2/files-2.1/org.springframework/spring-context/6.1.2/x/spring-context-6.1.2.jar")
        func sub(_ m: Int, _ deps: [Int]) -> JavaGradleProjectModel.Subproject {
            .init(path: ":m\(m)", directory: root.appendingPathComponent("m\(m)"),
                  sourceSets: [.init(name: "main", sourceDirs: [dir(m)], compileClasspathJars: [jar],
                                     projectDependencies: deps.map { .init(projectPath: ":m\($0)", sourceSetName: "main") },
                                     runtimeProjectDependencies: deps.map { .init(projectPath: ":m\($0)", sourceSetName: "main") })])
        }
        let model = JavaGradleProjectModel(formatVersion: 9, gradleVersion: "8", subprojects: [sub(0, [1, 2]), sub(1, [2]), sub(2, [])])
        let before = resident()
        let indexer = SpringWorkspaceIndexer()
        let t0 = clock.now
        await indexer.configure(model: model)
        await indexer.waitForScan()
        note("index (3 modules): \(fmt(ms(clock.now - t0))) ms, resident \(fmt(resident())) MB (+\(fmt(resident() - before)))")
        let store = indexer.store
        let modules = await indexer.modules
        let resolver = SpringModuleResolver(modules: modules)
        func moduleOf(_ u: URL) -> String? { resolver.owner(of: u) }

        let tc = clock.now
        let contexts = await store.contexts()
        note("cross-module contexts (scan + import resolution + resolve): \(fmt(ms(clock.now - tc))) ms — \(contexts.count) context, \(contexts[0].model.beans.count) beans, modules \(contexts[0].moduleIDs.count)")
        note("  after contexts: resident \(fmt(resident())) MB (+\(fmt(resident() - before)))")
        let context = contexts[0]

        // Tool window initialisation: everything the snapshot holds.
        let ti = clock.now
        let index = SpringBeanIndex(context: context, moduleOf: moduleOf)
        let tIndex = ms(clock.now - ti)
        let tg = clock.now
        let graph = SpringBeanGraph(context: context, moduleOf: moduleOf)
        let tGraph = ms(clock.now - tg)
        let tx = clock.now
        _ = SpringContextGraph(context: context, moduleOf: moduleOf)
        let tContext = ms(clock.now - tx)
        note("  after index+graph: resident \(fmt(resident())) MB (+\(fmt(resident() - before)))")
        note("tool window snapshot: bean index \(fmt(tIndex)) ms, bean graph \(fmt(tGraph)) ms (\(graph.nodeCount) nodes, \(graph.edgeCount) edges), context graph \(fmt(tContext)) ms")

        // Search and filters.
        var search: [Double] = []
        var f = SpringBeanFilter()
        for q in ["svc1", "svc12 svc", "repository", "m1", "zzz", "svc99", ""] { for _ in 0..<5 {
            f.text = q; let t = clock.now; _ = index.search(f); search.append(ms(clock.now - t)) } }
        f.text = ""; f.stereotypes = [.repository]; f.modules = [":m1"]
        let tf = clock.now; let filtered = index.search(f).count; let filterMs = ms(clock.now - tf)
        note("bean search over \(index.rows.count) beans: median \(fmt(median(search))) ms, p95 \(fmt(percentile(search, 0.95))) ms; combined filter \(fmt(filterMs)) ms (\(filtered) rows)")

        // Selection and inspector.
        var inspect: [Double] = []
        for row in index.rows.prefix(200) { let t = clock.now; _ = SpringBeanInspection(bean: row.id, in: context.model); inspect.append(ms(clock.now - t)) }
        note("bean selection → inspector over \(context.model.injectionPoints.count) points: median \(fmt(median(inspect))) ms, p95 \(fmt(percentile(inspect, 0.95))) ms")

        // Graph slices.
        var focus: [Double] = [], filtersMs: [Double] = []
        for row in index.rows.prefix(100) {
            var o = SpringBeanGraphOptions(); o.focus = row.id; o.depth = 2
            let t = clock.now; _ = graph.slice(o); focus.append(ms(clock.now - t))
            o.modules = [":m1"]; o.showExternal = false
            let u = clock.now; _ = graph.slice(o); filtersMs.append(ms(clock.now - u))
        }
        var whole = SpringBeanGraphOptions(); whole.nodeLimit = 300
        let tw = clock.now; let slice = graph.slice(whole); let wholeMs = ms(clock.now - tw)
        note("graph slice: focus depth 2 median \(fmt(median(focus))) ms, with filters \(fmt(median(filtersMs))) ms, whole graph capped at 300 nodes \(fmt(wholeMs)) ms (\(slice.nodes.count) nodes, \(slice.edges.count) edges)")

        // Profile switching and invalidation.
        var profile: [Double] = []
        for i in 0..<6 { let t = clock.now; await store.setActiveProfiles(i % 2 == 0 ? ["prod"] : ["dev"]); _ = await store.contexts(); profile.append(ms(clock.now - t)) }
        note("profile switch (all contexts rebuilt): median \(fmt(median(profile))) ms")
        let shared = dir(2).appendingPathComponent("Svc2.java").standardizedFileURL
        let text = try String(contentsOf: shared, encoding: .utf8)
        var body: [Double] = [], bean: [Double] = []
        for i in 0..<5 {
            let t = clock.now; _ = await indexer.ingest(url: shared, text: text.replacingOccurrences(of: "int x = 2;", with: "int x = \(i + 100);")); _ = await store.contexts(); body.append(ms(clock.now - t))
        }
        for i in 0..<5 {
            let t = clock.now; _ = await indexer.ingest(url: shared, text: text.replacingOccurrences(of: "@Service", with: i % 2 == 0 ? "@Service @Lazy" : "@Service")); _ = await store.contexts(); bean.append(ms(clock.now - t))
        }
        note("cross-module invalidation: body edit in a shared module median \(fmt(median(body))) ms; bean-definition edit (rebuilds the application's context) median \(fmt(median(bean))) ms")
        note("resident: \(fmt(before)) → \(fmt(resident())) MB (+\(fmt(resident() - before)) MB for \(beans) beans, graph, index and contexts)")
    }
}
