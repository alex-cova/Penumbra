import XCTest
import JavaIntelligence
@testable import SpringIntelligence

/// Compares the endpoint index with what Spring Framework itself registers. The same controllers are compiled against the real
/// Spring 6.1 jars (from the local Maven repository), loaded into a `RequestMappingHandlerMapping`, and its mapping table is dumped
/// next to the index's. Skipped when `javac`, `java` or the jars are not on this machine.
final class SpringRuntimeParityTests: XCTestCase {
    private let sources = """
    package fx;
    import org.springframework.web.bind.annotation.*;
    import org.springframework.core.annotation.AliasFor;
    import java.lang.annotation.*;

    @RestController @RequestMapping("/api/customers")
    class CustomerController {
        @GetMapping("/{id}") String find(@PathVariable Long id) { return ""; }
        @PostMapping(consumes = "application/json") String create(@RequestBody String b) { return ""; }
        @RequestMapping(path = {"/a", "b"}, method = {RequestMethod.GET, RequestMethod.HEAD}) void multi() {}
        @GetMapping(value = "/regex/{n:[0-9]+}", params = {"x", "y=1"}, headers = "X-A=1") String regex() { return ""; }
    }

    @Retention(RetentionPolicy.RUNTIME) @Target(ElementType.METHOD)
    @RequestMapping(method = RequestMethod.GET, produces = "application/json")
    @interface JsonGet { @AliasFor(annotation = RequestMapping.class, attribute = "path") String[] value() default {}; }
    @RestController class ComposedController { @JsonGet("/x") String x() { return ""; } @JsonGet String y() { return ""; } }

    @RequestMapping("/orders")
    interface OrdersApi {
        @GetMapping("/{id}") String get(@PathVariable("id") Long id);
        @PostMapping(consumes = "application/json") void create(@RequestBody String b);
    }
    @RestController class OrdersController implements OrdersApi { public String get(Long id) { return ""; } public void create(String b) {} }

    abstract class Base { @GetMapping("/ping") String ping() { return "pong"; } }
    @RestController @RequestMapping("/svc") class Svc extends Base {}

    @RestController @RequestMapping({"/v1", "/v2"}) class Multi {
        @GetMapping({"/a", "/b"}) String ab() { return ""; }
        @GetMapping String root() { return ""; }
    }
    @RestController @RequestMapping("/hotels/*") class Star { @GetMapping("/booking") String b() { return ""; } }
    @RestController @RequestMapping("/slash/") class Slash {
        @GetMapping("/x") String x() { return ""; }
        @GetMapping("y") String y() { return ""; }
    }
    @RestController @RequestMapping("${api.base:/v1}") class Placeholder { @GetMapping("/p") String p() { return ""; } }
    @RestController @RequestMapping(value = "/c", produces = "text/plain", headers = "X-A=1", params = "p")
    class Combine {
        @PostMapping(value = "/m", consumes = "application/json", produces = "application/json", headers = "X-B") String m() { return ""; }
        @GetMapping("/n") String n() { return ""; }
    }
    @RestController class Any {
        @RequestMapping("/any") String any() { return ""; }
        @GetMapping("/any") String get() { return ""; }
    }
    """

    private let scenarios = """
    package fx;
    import org.springframework.web.bind.annotation.*;
    @RestController class IdA { @GetMapping("/same") String a() { return ""; } }
    @RestController class IdB { @GetMapping("/same") String b() { return ""; } }
    @RestController class DiA {
        @GetMapping(value = "/same", produces = "application/json") String json() { return ""; }
        @PostMapping("/same") String post() { return ""; }
        @RequestMapping("/any") String any() { return ""; }
    }
    @RestController class DiB {
        @GetMapping(value = "/same", produces = "application/xml") String xml() { return ""; }
        @GetMapping("/any") String get() { return ""; }
    }
    @RestController class VarA { @GetMapping("/v/{a}") String a(@PathVariable String a) { return ""; } }
    @RestController class VarB { @GetMapping("/v/{b}") String b(@PathVariable String b) { return ""; } }
    """

    private let dump = """
    package fx;
    import java.util.*;
    import java.util.stream.*;
    import org.springframework.mock.web.MockServletContext;
    import org.springframework.web.context.support.AnnotationConfigWebApplicationContext;
    import org.springframework.web.servlet.config.annotation.WebMvcConfigurationSupport;
    import org.springframework.web.servlet.mvc.method.RequestMappingInfo;
    import org.springframework.web.servlet.mvc.method.annotation.RequestMappingHandlerMapping;
    import org.springframework.web.method.HandlerMethod;

    public class Dump {
        static String s(Collection<?> c) { return c.stream().map(Object::toString).sorted().collect(Collectors.joining(",")); }
        public static void main(String[] args) throws Exception {
            var ctx = new AnnotationConfigWebApplicationContext();
            ctx.setServletContext(new MockServletContext());
            List<String> probes = new ArrayList<>();
            boolean probing = false;
            for (String n : args) {
                if (n.equals("--probe")) { probing = true; continue; }
                if (probing) probes.add(n); else ctx.register(Class.forName("fx." + n));
            }
            ctx.register(WebMvcConfigurationSupport.class);
            try { ctx.refresh(); } catch (Exception e) {
                Throwable t = e; while (t.getCause() != null) t = t.getCause();
                System.out.println("STARTUP-ERROR " + t.getMessage().split("\\n")[0]);
                return;
            }
            var mapping = ctx.getBean(RequestMappingHandlerMapping.class);
            for (Map.Entry<RequestMappingInfo, HandlerMethod> e : mapping.getHandlerMethods().entrySet()) {
                RequestMappingInfo i = e.getKey(); HandlerMethod h = e.getValue();
                System.out.println(String.join("|", s(i.getMethodsCondition().getMethods()), s(i.getPathPatternsCondition().getPatternValues()),
                    s(i.getConsumesCondition().getExpressions()), s(i.getProducesCondition().getExpressions()),
                    s(i.getParamsCondition().getExpressions()), s(i.getHeadersCondition().getExpressions()),
                    h.getBeanType().getSimpleName() + "#" + h.getMethod().getName()));
            }
            for (String path : probes) {
                try { mapping.getHandler(new org.springframework.mock.web.MockHttpServletRequest("GET", path)); System.out.println("PROBE " + path + " OK"); }
                catch (Exception e) { System.out.println("PROBE " + path + " ERROR " + e.getMessage()); }
            }
        }
    }
    """

    private let controllers = ["CustomerController", "ComposedController", "OrdersController", "Svc", "Multi", "Star", "Slash",
                               "Placeholder", "Combine", "Any"]

    private func jar(_ group: String, _ artifact: String, _ version: String) -> String? {
        let path = NSHomeDirectory() + "/.m2/repository/\(group.replacingOccurrences(of: ".", with: "/"))/\(artifact)/\(version)/\(artifact)-\(version).jar"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func run(_ tool: String, _ args: [String], in dir: URL) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [tool] + args
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testTheIndexMatchesSpringsOwnMappingTable() async throws {
        let spring = "6.1.11"
        let needed: [(String, String, String)] = [
            ("org.springframework", "spring-web", spring), ("org.springframework", "spring-webmvc", spring), ("org.springframework", "spring-core", spring),
            ("org.springframework", "spring-beans", spring), ("org.springframework", "spring-context", spring), ("org.springframework", "spring-aop", spring),
            ("org.springframework", "spring-expression", spring), ("org.springframework", "spring-jcl", spring), ("org.springframework", "spring-test", spring),
            ("io.micrometer", "micrometer-observation", "1.12.8"), ("io.micrometer", "micrometer-commons", "1.12.8"),
            ("jakarta.servlet", "jakarta.servlet-api", "6.0.0"),
        ]
        let jars = needed.compactMap { jar($0.0, $0.1, $0.2) }
        try XCTSkipIf(jars.count != needed.count, "Spring \(spring) jars are not in ~/.m2")
        let probe = try run("javac", ["-version"], in: FileManager.default.temporaryDirectory)
        try XCTSkipIf(probe.status != 0, "no javac")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spring-parity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src/fx"), out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try sources.write(to: src.appendingPathComponent("Controllers.java"), atomically: true, encoding: .utf8)
        try scenarios.write(to: src.appendingPathComponent("Scenarios.java"), atomically: true, encoding: .utf8)
        try dump.write(to: src.appendingPathComponent("Dump.java"), atomically: true, encoding: .utf8)
        let classpath = jars.joined(separator: ":")
        let compiled = try run("javac", ["-parameters", "-cp", classpath, "-d", out.path] + ["Controllers", "Scenarios", "Dump"].map { src.appendingPathComponent("\($0).java").path }, in: dir)
        XCTAssertEqual(compiled.status, 0, "the fixtures must be valid Java against real Spring:\n\(compiled.output)")
        let ran = try run("java", ["-cp", out.path + ":" + classpath, "fx.Dump"] + controllers, in: dir)
        XCTAssertEqual(ran.status, 0, ran.output)

        // What Spring registered.
        struct Row: Hashable { let methods, route, consumes, produces, params, headers, handler: String }
        // Spring keeps one mapping per annotation with all its patterns; the index lists one endpoint per route. An empty pattern
        // and "/" are the same root route.
        let runtime = Set(ran.output.split(separator: "\n").flatMap { line -> [Row] in
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 7 else { return [] }
            let routes = Set(f[1].split(separator: ",", omittingEmptySubsequences: false).map { $0.isEmpty ? "/" : String($0) })
            return routes.map { Row(methods: f[0], route: $0, consumes: f[2], produces: f[3], params: f[4], headers: f[5], handler: f[6]) }
        })
        XCTAssertGreaterThan(runtime.count, 15, "Spring's table was read: \(ran.output)")

        // What the index finds in the same sources.
        let store = SpringProjectModel()
        await store.update(url: URL(fileURLWithPath: "/p/Controllers.java"), source: sources)
        await store.updateConfig(url: URL(fileURLWithPath: "/p/application.properties"), text: "other=1\n")
        let config = await store.config()
        let all = await store.endpointIndexes()
        let index = try XCTUnwrap(all.first)
        let indexed = Set(index.endpoints.map { e -> Row in
            Row(methods: e.conditions.methods.sorted().joined(separator: ","),
                route: e.placeholderKeys.isEmpty ? e.route : e.resolvedRoute(using: config).route,
                consumes: e.conditions.consumes.sorted().joined(separator: ","), produces: e.conditions.produces.sorted().joined(separator: ","),
                params: e.conditions.params.sorted().joined(separator: ","), headers: e.conditions.headers.sorted().joined(separator: ","),
                handler: "\(e.controllerSimpleName)#\(e.handler)")
        })
        XCTAssertEqual(indexed.subtracting(runtime).sorted { "\($0)" < "\($1)" }.map(\.debugLine), [], "in the index but not in Spring")
        XCTAssertEqual(runtime.subtracting(indexed).sorted { "\($0)" < "\($1)" }.map(\.debugLine), [], "in Spring but not in the index")
        XCTAssertEqual(indexed.count, runtime.count)

        // Conflicts: what Spring rejects, the index reports as an error; what it accepts, the index leaves alone.
        func scenario(_ classes: [String], probes: [String] = []) async throws -> (spring: String, index: SpringEndpointIndex) {
            let output = try run("java", ["-cp", out.path + ":" + classpath, "fx.Dump"] + classes + (probes.isEmpty ? [] : ["--probe"] + probes), in: dir).output
            let scoped = SpringProjectModel()
            await scoped.update(url: URL(fileURLWithPath: "/p/Scenarios.java"), source: scenarios)
            let all = await scoped.endpointIndexes()
            let only = all.first!
            // Only the classes this run registered: filter the index to them.
            let kept = only.endpoints.filter { classes.contains($0.controllerSimpleName) }
            return (output, SpringEndpointIndex(contextID: only.contextID, endpoints: kept, extractionDiagnostics: []))
        }
        let identical = try await scenario(["IdA", "IdB"])
        XCTAssertTrue(identical.spring.contains("STARTUP-ERROR Ambiguous mapping"), "Spring rejects identical mappings: \(identical.spring)")
        XCTAssertEqual(identical.index.diagnostics.filter { $0.code == SpringEndpointDiagnosticCode.ambiguous && $0.severity == .error }.count, 2)

        let distinct = try await scenario(["DiA", "DiB"])
        XCTAssertFalse(distinct.spring.contains("STARTUP-ERROR"), "Spring accepts mappings that differ in produces, method or specificity: \(distinct.spring)")
        XCTAssertTrue(distinct.index.diagnostics.isEmpty, "\(distinct.index.diagnostics.map(\.message))")

        let variables = try await scenario(["VarA", "VarB"], probes: ["/v/1"])
        XCTAssertFalse(variables.spring.contains("STARTUP-ERROR"), "different pattern strings register fine")
        XCTAssertTrue(variables.spring.contains("PROBE /v/1 ERROR Ambiguous handler methods"), "but the first request fails: \(variables.spring)")
        XCTAssertEqual(variables.index.diagnostics.filter { $0.code == SpringEndpointDiagnosticCode.ambiguousVariables }.count, 2)
    }
}

private extension Mirror {
    static func line(_ value: Any) -> String { Mirror(reflecting: value).children.map { "\($0.label ?? "")=\($0.value)" }.joined(separator: " ") }
}

private extension Hashable {
    var debugLine: String { Mirror.line(self) }
}
