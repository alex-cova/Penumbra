import Foundation
import JavaIntelligence
import SpringIntelligence

/// Release-mode cost of the endpoint index on a generated project:
///
///   swift run -c release PerfHarness spring-endpoints synthetic [--endpoints N] [--modules M]
///
/// `N` endpoints in controllers of ten each, spread over `M` build modules (the application depends on all of them). Reports the
/// first index (reading every controller), annotation, class-mapping, shifted and body edits, a profile switch, search and the
/// memory the index holds. Everything runs in memory through the same `SpringProjectModel` the editor uses.
enum SpringEndpointProfile {
    static func run(endpoints: Int, modules: Int) throws {
        let done = DispatchSemaphore(value: 0)
        let failure = Box()
        Task.detached {
            do { try await measure(endpoints: endpoints, modules: modules) } catch { failure.error = error }
            done.signal()
        }
        done.wait()
        if let error = failure.error { throw error }
    }

    private final class Box: @unchecked Sendable { var error: Error? }

    private static func note(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
    private static func ms(_ d: Duration) -> Double { (Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * 1000 }
    private static func fmt(_ x: Double) -> String { String(format: "%.2f", x) }
    private static func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
    private static func p95(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[min(v.count - 1, Int(Double(v.count) * 0.95))] }

    /// Resident size after asking malloc to hand back freed pages, so what is reported is what the index keeps, not allocator garbage.
    private static func resident() -> Double {
        malloc_zone_pressure_relief(nil, 0)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    private static func controller(_ index: Int, module: Int, perController: Int = 10, tag: String = "") -> String {
        let methods = (0..<perController).map { m -> String in
            switch m % 4 {
            case 0: return "    @GetMapping(\"/items\(m)/{id}\(tag)\") Item get\(m)(@PathVariable Long id) { return null; }"
            case 1: return "    @PostMapping(value = \"/items\(m)\", consumes = \"application/json\") Item create\(m)(@RequestBody Item item) { return item; }"
            case 2: return "    @RequestMapping(path = \"/search\(m)\", method = RequestMethod.GET, produces = \"application/json\") List<Item> search\(m)(@RequestParam String q, @RequestParam(defaultValue = \"10\") int size) { return null; }"
            default: return "    @DeleteMapping(\"/items/{id}/part\(m)\") void remove\(m)(@PathVariable(\"id\") Long id) { int x = \(m); }"
            }
        }.joined(separator: "\n")
        return """
        package com.acme.m\(module).web;
        import org.springframework.web.bind.annotation.*;
        import java.util.List;
        @RestController
        @RequestMapping("/api/m\(module)/c\(index)")
        class Controller\(index) {
        \(methods)
        }
        """
    }

    private static func measure(endpoints: Int, modules: Int) async throws {
        note("=== spring endpoints (synthetic, \(endpoints) endpoints, \(modules) module\(modules == 1 ? "" : "s")) ===")
        let clock = ContinuousClock()
        let perController = 10
        let controllers = max(1, endpoints / perController)
        func file(_ module: Int, _ name: String) -> URL { URL(fileURLWithPath: "/ws/m\(module)/src/main/java/\(name).java") }
        func info(_ i: Int) -> SpringModuleInfo {
            SpringModuleInfo(projectPath: ":m\(i)", directory: URL(fileURLWithPath: "/ws/m\(i)"), frameworkVersion: "6.1.0", bootVersion: nil,
                             features: [.framework, .mvc], sourceRoots: [URL(fileURLWithPath: "/ws/m\(i)/src/main/java")], resourceRoots: [],
                             classpathJars: [], outputDirs: [], dependencyPaths: i == 0 ? Set((1..<max(1, modules)).map { ":m\($0)" }) : [], isSpring: true)
        }
        let store = SpringProjectModel()
        await store.setModules((0..<modules).map(info))
        let before = resident()

        var sources: [(URL, String)] = []
        sources.append((file(0, "App"), "package com.acme.m0.web; import org.springframework.boot.autoconfigure.SpringBootApplication; @SpringBootApplication(scanBasePackages = \"com.acme\") class App {}"))
        for c in 0..<controllers { let m = c % modules; sources.append((file(m, "Controller\(c)"), controller(c, module: m))) }
        for m in 0..<modules { sources.append((file(m, "Item"), "package com.acme.m\(m).web; public class Item { String name; int count; }")) }
        sources.append((file(0, "Svc"), "package com.acme.m0.web; import org.springframework.stereotype.Service; @Service class Svc { int m() { int x = 1; return x; } }"))

        let tu = clock.now
        for (url, text) in sources { await store.update(url: url, source: text) }
        note("read \(sources.count) files (parse + declarations): \(fmt(ms(clock.now - tu))) ms")

        let tc = clock.now
        let contexts = await store.contexts()
        let contextMs = ms(clock.now - tc)
        let afterContexts = resident()
        let ti = clock.now
        let indexes = await store.endpointIndexes()
        let firstMs = ms(clock.now - ti)
        guard let index = indexes.first else { note("no context"); return }
        note("context build (\(contexts[0].model.beans.count) beans): \(fmt(contextMs)) ms; first endpoint index: \(fmt(firstMs)) ms → \(index.endpoints.count) endpoints, \(index.diagnostics.count) diagnostics")
        note("  resident: \(fmt(before)) → \(fmt(afterContexts)) MB after the sources and contexts (+\(fmt(afterContexts - before))), → \(fmt(resident())) MB with the endpoint index (+\(fmt(resident() - afterContexts)) for \(index.endpoints.count) endpoints)")

        for d in index.diagnostics.prefix(3) { note("  sample diagnostic: \(d.code) \(d.message)") }
        let assemble = clock.now
        let rebuilt = SpringEndpointIndex(contextID: index.contextID, endpoints: index.endpoints, extractionDiagnostics: [])
        note("assembling the index from \(rebuilt.endpoints.count) extracted endpoints (sort, search text, conflicts, orders): \(fmt(ms(clock.now - assemble))) ms")

        // Search and filters.
        var search: [Double] = []
        var filter = SpringEndpointFilter()
        for q in ["items", "get c1", "search", "m1 delete", "zzz", "/api/m0/c5", ""] { for _ in 0..<10 {
            filter.text = q; let t = clock.now; _ = index.search(filter); search.append(ms(clock.now - t)) } }
        filter = SpringEndpointFilter(); filter.methods = ["POST"]; filter.sort = .controller
        let tf = clock.now; let posts = index.search(filter).count; let filterMs = ms(clock.now - tf)
        note("search over \(index.endpoints.count) endpoints: median \(fmt(median(search))) ms, p95 \(fmt(p95(search))) ms; method filter + controller sort \(fmt(filterMs)) ms (\(posts) rows)")
        var route: [Double] = []
        for i in 0..<20 { let t = clock.now; _ = index.endpoints(matchingPath: "/api/m0/c\(i * 5 % controllers)/items/42", method: "GET"); route.append(ms(clock.now - t)) }
        note("route → handler (request path matched against every route): median \(fmt(median(route))) ms")

        // Edits. A "shifted" edit moves the handler without changing what it says.
        let c0 = controller(0, module: 0)
        var annotation: [Double] = [], classMapping: [Double] = [], shifted: [Double] = [], body: [Double] = [], service: [Double] = []
        let url0 = file(0, "Controller0")
        let readsBefore = await store.extractionCount
        for i in 0..<10 {
            let t = clock.now
            await store.update(url: url0, source: c0.replacingOccurrences(of: "\"/items0/{id}\"", with: "\"/renamed\(i)/{id}\""))
            _ = await store.endpointIndexes(); annotation.append(ms(clock.now - t))
        }
        for i in 0..<10 {
            let t = clock.now
            await store.update(url: url0, source: c0.replacingOccurrences(of: "\"/api/m0/c0\"", with: "\"/api/v\(i)/c0\""))
            _ = await store.endpointIndexes(); classMapping.append(ms(clock.now - t))
        }
        for i in 0..<10 {
            let t = clock.now
            await store.update(url: url0, source: c0.replacingOccurrences(of: "@RestController", with: "// \(String(repeating: "x", count: i + 1))\n@RestController"))
            _ = await store.endpointIndexes(); shifted.append(ms(clock.now - t))
        }
        for i in 0..<10 {
            let t = clock.now
            await store.update(url: url0, source: c0.replacingOccurrences(of: "int x = 0;", with: "int x = \(i + 7); int y = x;"))
            _ = await store.endpointIndexes(); body.append(ms(clock.now - t))
        }
        let svc = "package com.acme.m0.web; import org.springframework.stereotype.Service; @Service class Svc { int m() { int x = %d; return x; } }"
        for i in 0..<10 {
            let t = clock.now
            await store.update(url: file(0, "Svc"), source: String(format: svc, i + 2))
            _ = await store.endpointIndexes(); service.append(ms(clock.now - t))
        }
        let readsAfter = await store.extractionCount
        note("edit → refreshed index: mapping annotation \(fmt(median(annotation))) ms, class-level mapping \(fmt(median(classMapping))) ms, text above the handler \(fmt(median(shifted))) ms, method body \(fmt(median(body))) ms, unrelated service body \(fmt(median(service))) ms")
        note("  controllers re-read from source over 50 edits: \(readsAfter - readsBefore) (one per edit that changed what the controller says or where)")

        var profile: [Double] = []
        for i in 0..<6 { let t = clock.now; await store.setActiveProfiles(i % 2 == 0 ? ["prod"] : ["dev"]); _ = await store.endpointIndexes(); profile.append(ms(clock.now - t)) }
        note("profile switch (contexts and index rebuilt, controllers not re-read): median \(fmt(median(profile))) ms")

        // The request generator and inspector data for one endpoint.
        let endpoint = index.endpoints[index.endpoints.count / 2]
        let tg = clock.now
        for _ in 0..<200 { _ = SpringHTTPRequest.render(endpoint, base: .unknown) }
        note("generate an HTTP request: \(fmt(ms(clock.now - tg) / 200)) ms")
        note("resident at the end: \(fmt(resident())) MB (+\(fmt(resident() - before)) MB for \(index.endpoints.count) endpoints, \(contexts[0].model.beans.count) beans and their contexts)")
    }
}
