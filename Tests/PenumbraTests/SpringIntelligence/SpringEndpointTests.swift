import XCTest
import JavaIntelligence
@testable import SpringIntelligence

/// Spring MVC and WebFlux endpoint discovery over real Java sources, through the same `SpringProjectModel` the editor uses.
final class SpringEndpointTests: XCTestCase {
    private let web = "import org.springframework.web.bind.annotation.*;\n"

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/p/\(name).java") }

    private func makeStore(_ sources: [String: String], profiles: Set<String>? = nil) async -> SpringProjectModel {
        let store = SpringProjectModel(activeProfiles: profiles)
        for (name, text) in sources { await store.update(url: url(name), source: text) }
        return store
    }

    private func index(_ sources: [String: String], profiles: Set<String>? = nil) async throws -> SpringEndpointIndex {
        let store = await makeStore(sources, profiles: profiles)
        return try await idx(store)
    }

    private func idx(_ store: SpringProjectModel) async throws -> SpringEndpointIndex {
        let all = await store.endpointIndexes()
        return try XCTUnwrap(all.first)
    }

    private func firstEndpoint(_ store: SpringProjectModel) async throws -> SpringEndpoint {
        let index = try await idx(store)
        return try XCTUnwrap(index.endpoints.first)
    }

    private func endpoint(_ index: SpringEndpointIndex, _ title: String, file: StaticString = #filePath, line: UInt = #line) throws -> SpringEndpoint {
        try XCTUnwrap(index.endpoints.first { $0.title == title }, "endpoint \(title) in \(index.endpoints.map(\.title))", file: file, line: line)
    }

    private lazy var customers = """
    package app;
    \(web)
    @RestController
    @RequestMapping("/api/customers")
    class CustomerController {
        @GetMapping("/{id}") Customer find(@PathVariable Long id) { return null; }
        @PostMapping Customer create(@RequestBody Customer c) { return c; }
        @RequestMapping(path = {"/a", "b"}, method = {RequestMethod.GET, RequestMethod.HEAD}) void multi() {}
    }
    class Customer { String name; int age; }
    """

    // MARK: Discovery and route composition

    func testClassAndMethodMappingsComposeIntoFullRoutes() async throws {
        let i = try await index(["C": customers])
        XCTAssertEqual(i.endpoints.map(\.title).sorted(), [
            "GET /api/customers/{id}", "GET, HEAD /api/customers/a", "GET, HEAD /api/customers/b", "POST /api/customers",
        ])
        let find = try endpoint(i, "GET /api/customers/{id}")
        XCTAssertEqual(find.controller, "app.CustomerController")
        XCTAssertEqual(find.handler, "find")
        XCTAssertEqual(find.pathVariables, ["id"])
        XCTAssertEqual(find.parameters.map(\.bindingName), ["id"])
        XCTAssertEqual(find.parameters.first?.kind, .pathVariable)
        XCTAssertEqual(find.parameters.first?.type, "java.lang.Long")
        XCTAssertTrue(find.confidence.isExact)
    }

    func testSourceRangesPointAtTheHandlerAndTheMappingAnnotation() async throws {
        let i = try await index(["C": customers])
        let find = try endpoint(i, "GET /api/customers/{id}")
        let bytes = Array(customers.utf8)
        XCTAssertEqual(String(decoding: bytes[find.handlerLocation.byteRange], as: UTF8.self), "find")
        XCTAssertEqual(String(decoding: bytes[find.mappingLocation.byteRange], as: UTF8.self), "@GetMapping(\"/{id}\")")
        XCTAssertEqual(String(decoding: bytes[try XCTUnwrap(find.classMappingLocation).byteRange], as: UTF8.self), "@RequestMapping(\"/api/customers\")")
        XCTAssertEqual(String(decoding: bytes[find.controllerLocation.byteRange], as: UTF8.self), "CustomerController")
    }

    func testRouteCompositionFollowsPathPatternRulesNotStringConcatenation() {
        XCTAssertEqual(SpringRoute.combine("/api", "/x"), "/api/x")
        XCTAssertEqual(SpringRoute.combine("/api/", "/x"), "/api/x")
        XCTAssertEqual(SpringRoute.combine("api", "x"), "/api/x")
        XCTAssertEqual(SpringRoute.combine("", "/x"), "/x")
        XCTAssertEqual(SpringRoute.combine("/api", ""), "/api")
        XCTAssertEqual(SpringRoute.combine("", ""), "")
        XCTAssertEqual(SpringRoute.combine("/hotels/*", "/booking"), "/hotels/booking")
        XCTAssertEqual(SpringRoute.combine("/a", "/{id:\\d+}"), "/a/{id:\\d+}")
        XCTAssertEqual(SpringRoute.combine("${api.base}", "/x"), "${api.base}/x", "placeholders are kept verbatim")
    }

    func testMultiplePathsAndTheRootMappingProduceOneEndpointEach() async throws {
        let i = try await index(["R": """
        package app; \(web)
        @RestController @RequestMapping({"/v1", "/v2"}) class R {
            @GetMapping({"/a", "/b"}) String ab() { return ""; }
            @GetMapping String root() { return ""; }
        }
        """])
        XCTAssertEqual(Set(i.endpoints.map(\.route)), ["/v1/a", "/v1/b", "/v2/a", "/v2/b", "/v1", "/v2"])
        XCTAssertEqual(i.endpoints.filter { $0.handler == "ab" }.count, 4)
        let ids = Set(i.endpoints.map(\.id))
        XCTAssertEqual(ids.count, i.endpoints.count, "every route has its own stable identity")
    }

    func testAMappingWithNoPathIsTheRoot() async throws {
        let i = try await index(["R": "package app; \(web) @RestController class R { @GetMapping String root() { return \"\"; } }"])
        XCTAssertEqual(i.endpoints.map(\.route), ["/"])
    }

    func testAnnotationNamesAreResolvedNotMatchedBySpelling() async throws {
        let i = try await index(["R": """
        package app;
        @interface GetMapping { String value() default ""; }
        @org.springframework.web.bind.annotation.RestController class R {
            @GetMapping("/mine") String notSpring() { return ""; }
            @org.springframework.web.bind.annotation.GetMapping("/real") String real() { return ""; }
        }
        """])
        XCTAssertEqual(i.endpoints.map(\.route), ["/real"], "the project's own GetMapping is not Spring's")
    }

    // MARK: Composed, inherited and interface-declared mappings

    func testComposedMappingAnnotationsMergeAliasedAttributes() async throws {
        let i = try await index(["C": """
        package app; \(web)
        import org.springframework.core.annotation.AliasFor;
        @RequestMapping(method = RequestMethod.GET, produces = "application/json")
        @interface JsonGet { @AliasFor(annotation = RequestMapping.class, attribute = "path") String[] value() default {}; }
        @RestController class C {
            @JsonGet("/x") String x() { return ""; }
            @JsonGet String y() { return ""; }
        }
        """])
        let x = try endpoint(i, "GET /x")
        XCTAssertEqual(x.conditions.produces, ["application/json"])
        XCTAssertEqual(x.composedFrom, "app.JsonGet")
        XCTAssertEqual(Set(i.endpoints.map(\.route)), ["/x", "/"])
    }

    func testAComposedAnnotationWithoutAliasForDoesNotChangeThePath() async throws {
        let i = try await index(["C": """
        package app; \(web)
        @RequestMapping(value = "/fixed", method = RequestMethod.GET)
        @interface Fixed { String value() default ""; }
        @RestController class C { @Fixed("/ignored") String x() { return ""; } }
        """])
        XCTAssertEqual(i.endpoints.map(\.route), ["/fixed"], "Spring only merges attributes declared with @AliasFor")
    }

    func testMappingsDeclaredOnAnInterfaceApplyToTheImplementingController() async throws {
        let i = try await index(["O": """
        package app; \(web)
        @RequestMapping("/orders")
        interface OrdersApi {
            @GetMapping("/{id}") String get(@PathVariable("id") Long id);
            @PostMapping(consumes = "application/json") void create(@RequestBody String body);
        }
        @RestController class OrdersController implements OrdersApi {
            public String get(Long id) { return ""; }
            public void create(String body) {}
        }
        """])
        let get = try endpoint(i, "GET /orders/{id}")
        XCTAssertEqual(get.mappingDeclaredIn, "app.OrdersApi")
        XCTAssertEqual(get.parameters.first?.bindingName, "id", "the interface's @PathVariable binds the implementation's parameter")
        let create = try endpoint(i, "POST /orders")
        XCTAssertEqual(create.conditions.consumes, ["application/json"])
        XCTAssertEqual(create.requestBodyType, "java.lang.String")
    }

    func testMappingsInheritedFromASuperclassBelongToTheSubclassRoute() async throws {
        let i = try await index(["S": """
        package app; \(web)
        abstract class Base { @GetMapping("/ping") String ping() { return "pong"; } }
        @RestController @RequestMapping("/svc") class Svc extends Base {}
        """])
        XCTAssertEqual(i.endpoints.map(\.route), ["/svc/ping"])
        XCTAssertEqual(i.endpoints.first?.controller, "app.Svc")
    }

    func testMethodAndTypeLevelConditionsCombineAsSpringDoes() async throws {
        let i = try await index(["C": """
        package app; \(web)
        @RestController @RequestMapping(value = "/c", produces = "text/plain", headers = "X-A=1", params = "p")
        class C {
            @PostMapping(value = "/m", consumes = "application/json", produces = "application/json", headers = "X-B") String m() { return ""; }
            @GetMapping("/n") String n() { return ""; }
        }
        """])
        let m = try endpoint(i, "POST /c/m")
        XCTAssertEqual(m.conditions.produces, ["application/json"], "the method's produces replaces the class's")
        XCTAssertEqual(m.conditions.consumes, ["application/json"])
        XCTAssertEqual(m.conditions.headers, ["X-A=1", "X-B"], "headers are a union")
        XCTAssertEqual(m.conditions.params, ["p"])
        XCTAssertEqual(try endpoint(i, "GET /c/n").conditions.produces, ["text/plain"], "inherits the class's produces")
    }

    func testMediaTypeConstantsAreRecognised() async throws {
        let i = try await index(["C": """
        package app; \(web)
        import org.springframework.http.MediaType;
        @RestController class C { @GetMapping(value = "/j", produces = MediaType.APPLICATION_JSON_VALUE) String j() { return ""; } }
        """])
        XCTAssertEqual(i.endpoints.first?.conditions.produces, ["application/json"])
        XCTAssertTrue(i.endpoints.first?.confidence.isExact ?? false)
    }

    func testValuesTheAnalysisCannotEvaluateMakeTheEndpointPartialAndExcludeItFromConflicts() async throws {
        let i = try await index(["C": """
        package app; \(web)
        @RestController class C {
            @GetMapping(Paths.BASE) String a() { return ""; }
            @GetMapping(Paths.BASE) String b() { return ""; }
        }
        """])
        XCTAssertEqual(i.endpoints.count, 2)
        XCTAssertTrue(i.endpoints.allSatisfy { !$0.confidence.isExact })
        XCTAssertTrue(i.endpoints.allSatisfy { $0.route.contains("Paths.BASE") })
        XCTAssertTrue(i.conflicts.isEmpty, "an expression is not claimed to be equal to itself")
        XCTAssertTrue(i.diagnostics.isEmpty)
    }

    func testLiteralConcatenationIsEvaluated() async throws {
        let i = try await index(["C": "package app; \(web) @RestController class C { @GetMapping(\"/a\" + \"/b\") String x() { return \"\"; } }"])
        XCTAssertEqual(i.endpoints.map(\.route), ["/a/b"])
    }

    func testPlaceholdersStayInTheRouteAndResolveFromConfiguration() async throws {
        let store = await makeStore(["C": "package app; \(web) @RestController @RequestMapping(\"${api.base:/v1}\") class C { @GetMapping(\"/x\") String x() { return \"\"; } }"])
        let e = try await firstEndpoint(store)
        XCTAssertEqual(e.placeholderKeys, ["api.base"])
        XCTAssertEqual(e.route, "${api.base:/v1}/x")
        await store.updateConfig(url: URL(fileURLWithPath: "/p/application.properties"), text: "api.base=/shop\n")
        let config = await store.config()
        XCTAssertEqual(e.resolvedRoute(using: config).route, "/shop/x")
        let none = await makeStore([:]).config()
        XCTAssertEqual(e.resolvedRoute(using: none).route, "/v1/x", "falls back to the placeholder's default")
    }

    // MARK: Response and request shapes (WebFlux)

    func testReactiveReturnTypesExposeTheWrappedPayload() async throws {
        let i = try await index(["W": """
        package app; \(web)
        import reactor.core.publisher.Mono;
        import reactor.core.publisher.Flux;
        import org.springframework.http.ResponseEntity;
        @RestController class W {
            @GetMapping("/customers/{id}") Mono<Customer> one(@PathVariable Long id) { return null; }
            @GetMapping("/customers") Flux<Customer> all() { return null; }
            @PostMapping("/c") Mono<ResponseEntity<Customer>> make(@RequestBody Mono<Customer> body) { return null; }
            @GetMapping("/v") Mono<Void> v() { return null; }
        }
        class Customer { String name; }
        """])
        let one = try endpoint(i, "GET /customers/{id}")
        XCTAssertEqual(one.response.declared, "reactor.core.publisher.Mono<app.Customer>")
        XCTAssertEqual(one.response.payload, "app.Customer")
        XCTAssertEqual(one.response.wrappers, ["Mono"])
        XCTAssertFalse(one.response.isStream)
        XCTAssertEqual(one.stack, .webflux, "reactive handler types, no build information")
        let all = try endpoint(i, "GET /customers")
        XCTAssertEqual(all.response.payload, "app.Customer")
        XCTAssertTrue(all.response.isStream)
        let make = try endpoint(i, "POST /c")
        XCTAssertEqual(make.response.wrappers, ["Mono", "ResponseEntity"])
        XCTAssertEqual(make.response.payload, "app.Customer")
        XCTAssertEqual(make.requestBodyType, "app.Customer", "Mono<Customer> as a body is a Customer")
        XCTAssertNil(try endpoint(i, "GET /v").response.payload)
    }

    func testRestAndViewReturnsAreToldApart() async throws {
        let i = try await index(["C": """
        package app; \(web)
        import org.springframework.stereotype.Controller;
        @Controller class C {
            @GetMapping("/page") String page() { return "home"; }
            @GetMapping("/data") @ResponseBody String data() { return ""; }
        }
        """])
        XCTAssertNil(try endpoint(i, "GET /page").response.payload, "a view name is not a body")
        XCTAssertEqual(try endpoint(i, "GET /data").response.payload, "java.lang.String")
    }

    func testRequestParametersHeadersAndValidation() async throws {
        let i = try await index(["C": """
        package app; \(web)
        import jakarta.validation.Valid;
        import jakarta.validation.constraints.*;
        @RestController class C {
            @PostMapping("/p") String p(@RequestParam String name, @RequestParam(defaultValue = "10") int size,
                                         @RequestHeader("X-Trace") String trace, @Valid @RequestBody Dto body, javax.servlet.http.HttpServletRequest req, String plain) { return ""; }
        }
        class Dto { @NotBlank String title; @Size(max = 5) String code; }
        """])
        let e = try endpoint(i, "POST /p")
        let kinds = e.parameters.map { "\($0.bindingName):\($0.kind.rawValue):\($0.isRequired)" }
        XCTAssertEqual(kinds, ["name:requestParam:true", "size:requestParam:false", "X-Trace:requestHeader:true",
                               "body:requestBody:true", "plain:requestParam:false"], "the servlet request is infrastructure, not a parameter")
        XCTAssertEqual(e.parameters[1].defaultValue, "10")
        XCTAssertTrue(e.parameters.last?.isImplicit ?? false)
        XCTAssertTrue(e.validations.contains { $0.contains("Dto.title") && $0.contains("@NotBlank") }, "\(e.validations)")
        XCTAssertTrue(e.validations.contains { $0.contains("Dto.code") && $0.contains("@Size(max = 5)") })
        let skeleton = try XCTUnwrap(e.requestBodySkeleton)
        XCTAssertTrue(skeleton.contains("\"title\": \"string\""), skeleton)
    }

    // MARK: Conflicts and diagnostics

    private let conflicting = """
    package app; \(("import org.springframework.web.bind.annotation.*;"))
    @RestController class A {
        @GetMapping("/x") String a() { return ""; }
        @GetMapping(value = "/y", produces = "application/json") String y1() { return ""; }
        @PostMapping("/x") String ax() { return ""; }
        @GetMapping("/v/{a}") String v1(@PathVariable String a) { return ""; }
        @GetMapping(value = "/z") String zAny() { return ""; }
        @RequestMapping(value = "/z", method = RequestMethod.GET) String zGet() { return ""; }
    }
    @RestController class B {
        @GetMapping("/x") String b() { return ""; }
        @GetMapping(value = "/y", produces = "application/xml") String y2() { return ""; }
        @GetMapping("/v/{b}") String v2(@PathVariable String b) { return ""; }
    }
    """

    func testOnlyMappingsSpringCannotTellApartConflict() async throws {
        let i = try await index(["AB": conflicting])
        let ambiguous = i.diagnostics.filter { $0.code == SpringEndpointDiagnosticCode.ambiguous }
        // GET /x (A.a, B.b) and GET /z (A.zAny, A.zGet) are identical mappings.
        XCTAssertEqual(ambiguous.count, 4, "\(ambiguous.map(\.message))")
        XCTAssertTrue(ambiguous.allSatisfy { $0.severity == .error })
        XCTAssertTrue(ambiguous.contains { $0.message.contains("GET /x") && $0.message.contains("B.b") })
        XCTAssertFalse(i.diagnostics.contains { $0.message.contains("/y") }, "different produces: Spring ranks them")
        XCTAssertFalse(i.diagnostics.contains { $0.message.contains("POST /x") }, "different method")
        let variables = i.diagnostics.filter { $0.code == SpringEndpointDiagnosticCode.ambiguousVariables }
        XCTAssertEqual(variables.count, 2)
        XCTAssertTrue(variables.allSatisfy { $0.severity == .warning })
    }

    func testAMappingThatAcceptsAnyMethodDoesNotConflictWithOneThatNamesIt() async throws {
        let i = try await index(["C": """
        package app; \(web)
        @RestController class C {
            @RequestMapping("/any") String any() { return ""; }
            @GetMapping("/any") String get() { return ""; }
        }
        """])
        XCTAssertTrue(i.conflicts.isEmpty, "GET is more specific than any: Spring picks it, so nothing is ambiguous")
    }

    func testConflictsWithAConditionalControllerAreWarningsAndInactiveOnesAreIgnored() async throws {
        let source = """
        package app; \(web)
        import org.springframework.context.annotation.Profile;
        @RestController class A { @GetMapping("/x") String a() { return ""; } }
        @RestController @Profile("prod") class B { @GetMapping("/x") String b() { return ""; } }
        """
        let unknown = try await index(["S": source], profiles: nil)
        XCTAssertEqual(unknown.diagnostics.map(\.severity), [.warning, .warning], "B may not be registered, so Spring may not reject it")
        let dev = try await index(["S": source], profiles: ["dev"])
        XCTAssertTrue(dev.diagnostics.isEmpty)
        XCTAssertEqual(try endpoint(dev, "GET /x").certainty, .certain)
        XCTAssertTrue(dev.endpoints.contains { $0.certainty.isInactive }, "the inactive endpoint is still listed, marked inactive")
        let prod = try await index(["S": source], profiles: ["prod"])
        XCTAssertEqual(prod.diagnostics.filter { $0.code == SpringEndpointDiagnosticCode.ambiguous }.map(\.severity), [.error, .error])
    }

    func testPathVariableReferencesAreCheckedAgainstTheRoute() async throws {
        let i = try await index(["P": """
        package app; \(web)
        @RestController @RequestMapping("/c") class P {
            @GetMapping("/{id}") String f(@PathVariable Long idd) { return ""; }
            @GetMapping("/z") String g(@PathVariable("q") String q) { return ""; }
            @GetMapping("/{a}/{b}") String h(@PathVariable("a") String a, @PathVariable String c) { return ""; }
            @GetMapping("/{x}") String ok(@PathVariable(required = false) String y, @PathVariable("x") String x) { return ""; }
            @GetMapping("/{m}") String map(@PathVariable java.util.Map<String, String> all) { return ""; }
        }
        """])
        let problems = i.diagnostics.filter { $0.code == SpringEndpointDiagnosticCode.unknownPathVariable }
        XCTAssertEqual(problems.count, 3, "\(problems.map(\.message))")
        XCTAssertTrue(problems.allSatisfy { $0.severity == .error })
        XCTAssertEqual(problems.compactMap(\.suggestion).sorted(), ["b", "id"], "a suggestion only when exactly one variable is unbound")
    }

    func testMalformedPatternsAreReportedAtTheMappingAnnotation() async throws {
        let i = try await index(["M": """
        package app; \(web)
        @RestController class M {
            @GetMapping("/a/{id") String open() { return ""; }
            @GetMapping("/a/{}") String empty() { return ""; }
            @GetMapping("/**/x") String middle() { return ""; }
            @GetMapping("/ok/{id:\\\\d{3}}") String regexWithBraces() { return ""; }
        }
        """])
        let problems = i.diagnostics.filter { $0.code == SpringEndpointDiagnosticCode.malformedPattern }
        XCTAssertEqual(problems.count, 3, "\(problems.map(\.message))")
        XCTAssertEqual(problems.filter { $0.severity == .error }.count, 2)
        XCTAssertEqual(problems.filter { $0.severity == .warning }.count, 1, "'**' in the middle is only valid for AntPathMatcher")
    }

    func testDuplicateAndIgnoredMappingAnnotations() async throws {
        let i = try await index(["D": """
        package app; \(web)
        @RestController class D {
            @GetMapping({"/d", "d"}) String dup() { return ""; }
            @GetMapping("/m") @PostMapping("/n") String twice() { return ""; }
            @PostMapping("/b") String bodies(@RequestBody String a, @RequestBody String b) { return ""; }
        }
        """])
        XCTAssertEqual(i.diagnostics.filter { $0.code == SpringEndpointDiagnosticCode.duplicatePath }.count, 1)
        let ignored = try XCTUnwrap(i.diagnostics.first { $0.code == SpringEndpointDiagnosticCode.multipleMappings })
        XCTAssertTrue(ignored.message.contains("@PostMapping is ignored"), ignored.message)
        XCTAssertEqual(i.diagnostics.filter { $0.code == SpringEndpointDiagnosticCode.multipleBodies }.count, 1)
        XCTAssertEqual(Set(i.endpoints.map(\.route)), ["/d", "/m", "/b"], "the ignored annotation contributes no endpoint")
    }

    func testAWellFormedProjectHasNoEndpointDiagnostics() async throws {
        let i = try await index(["C": customers])
        XCTAssertTrue(i.diagnostics.isEmpty, "\(i.diagnostics.map(\.message))")
    }

    // MARK: Exception handlers

    func testExceptionHandlersOfTheControllerAndAdviceAreAssociated() async throws {
        let i = try await index(["E": """
        package app; \(web)
        @RestController class E {
            @GetMapping("/e") String e() { return ""; }
            @ExceptionHandler(IllegalStateException.class) String local() { return ""; }
        }
        @RestControllerAdvice class Adv { @ExceptionHandler(RuntimeException.class) String g() { return ""; } }
        @RestControllerAdvice(basePackages = "other") class Scoped { @ExceptionHandler(Exception.class) String s() { return ""; } }
        """])
        let e = try XCTUnwrap(i.endpoints.first)
        XCTAssertEqual(i.endpoints.count, 1, "an @ExceptionHandler is not an endpoint")
        let names = e.exceptionHandlers.map { "\($0.owner.split(separator: ".").last!).\($0.method):\($0.exceptions.joined())" }.sorted()
        XCTAssertEqual(names, ["Adv.g:RuntimeException", "E.local:IllegalStateException"], "a package-scoped advice that excludes the controller does not apply")
    }

    // MARK: Profiles and stacks

    func testProfileSwitchChangesRegistrationWithoutReReadingControllers() async throws {
        let store = await makeStore(["C": """
        package app; \(web)
        import org.springframework.context.annotation.Profile;
        @RestController @Profile("prod") class C { @GetMapping("/p") String p() { return ""; } }
        """], profiles: nil)
        var e = try await firstEndpoint(store)
        XCTAssertTrue(e.certainty.isConditional)
        let reads = await store.extractionCount
        await store.setActiveProfiles(["dev"])
        e = try await firstEndpoint(store)
        XCTAssertTrue(e.certainty.isInactive)
        await store.setActiveProfiles(["prod"])
        e = try await firstEndpoint(store)
        XCTAssertEqual(e.certainty, .certain)
        let after = await store.extractionCount
        XCTAssertEqual(after, reads, "extractions are context-independent and survive a profile switch")
    }

    // MARK: Incremental indexing

    private func fixtures(extra: String = "") -> [String: String] {
        [
            "C1": "package app; \(web) @RestController @RequestMapping(\"/one\") class C1 { @GetMapping(\"/a\") String a() { return \"x\"; } }",
            "C2": "package app; \(web) @RestController class C2 { @GetMapping(\"/two\") String t() { return \"\(extra)\"; } }",
            "S": "package app; import org.springframework.stereotype.Service; @Service class S { int m() { return 1; } }",
        ]
    }

    func testBodyEditsElsewhereDoNotReadAnyController() async throws {
        let store = await makeStore(fixtures())
        _ = await store.contexts()
        _ = await store.endpointIndexes()
        let reads = await store.extractionCount, revision = await store.revision
        XCTAssertEqual(reads, 2)
        await store.update(url: url("S"), source: "package app; import org.springframework.stereotype.Service; @Service class S { int m() { int k = 2; return k; } }")
        let i = try await idx(store)
        XCTAssertEqual(i.endpoints.count, 2)
        let after = await store.extractionCount
        XCTAssertEqual(after, reads, "a service's body edit costs a cache lookup per controller")
        let rev = await store.revision
        XCTAssertEqual(rev, revision)
    }

    func testEditingOneControllerRereadsOnlyThatControllerAndNoContext() async throws {
        let store = await makeStore(fixtures())
        _ = await store.contexts(); _ = await store.endpointIndexes()
        let reads = await store.extractionCount, revision = await store.revision
        // A body edit moves no declaration, so nothing is read again.
        await store.update(url: url("C2"), source: fixtures(extra: "changed body that is longer")["C2"]!)
        var i = try await idx(store)
        var after = await store.extractionCount
        XCTAssertEqual(after, reads, "the handler's name did not move")
        // Text added above the handler moves its range: that controller is read again, C1 is not.
        let shifted = fixtures()["C2"]!.replacingOccurrences(of: "@GetMapping", with: "// a comment that shifts the handler\n @GetMapping")
        await store.update(url: url("C2"), source: shifted)
        i = try await idx(store)
        after = await store.extractionCount
        XCTAssertEqual(after, reads + 1)
        let handler = try XCTUnwrap(i.endpoints.first { $0.handler == "t" })
        XCTAssertEqual(String(decoding: Array(shifted.utf8)[handler.handlerLocation.byteRange], as: UTF8.self), "t", "locations follow the edit")
        // A mapping annotation edit changes the route, and still rebuilds no context.
        await store.update(url: url("C2"), source: fixtures()["C2"]!.replacingOccurrences(of: "\"/two\"", with: "\"/deux\""))
        i = try await idx(store)
        XCTAssertTrue(i.endpoints.contains { $0.route == "/deux" })
        XCTAssertFalse(i.endpoints.contains { $0.route == "/two" })
        after = await store.extractionCount
        XCTAssertEqual(after, reads + 2)
        let rev = await store.revision
        XCTAssertEqual(rev, revision, "mapping annotations are not part of the bean model's signature")
    }

    func testChangingAClassLevelMappingRecomputesItsRoutesOnly() async throws {
        let store = await makeStore(fixtures())
        _ = await store.endpointIndexes()
        let reads = await store.extractionCount
        await store.update(url: url("C1"), source: fixtures()["C1"]!.replacingOccurrences(of: "\"/one\"", with: "\"/uno\""))
        let i = try await idx(store)
        XCTAssertEqual(Set(i.endpoints.map(\.route)), ["/uno/a", "/two"])
        let after = await store.extractionCount
        XCTAssertEqual(after, reads + 1)
    }

    func testABeanRelevantEditStillRebuildsTheContext() async throws {
        let store = await makeStore(fixtures())
        _ = await store.contexts()
        let revision = await store.revision
        await store.update(url: url("S"), source: "package app; import org.springframework.stereotype.Service; @Service @org.springframework.context.annotation.Lazy class S { }")
        let after = await store.revision
        XCTAssertGreaterThan(after, revision)
    }

    func testChangingAnInterfaceInvalidatesTheImplementingController() async throws {
        let store = await makeStore([
            "Api": "package app; \(web) interface Api { @GetMapping(\"/v1\") String get(); }",
            "Impl": "package app; \(web) @RestController class Impl implements Api { public String get() { return \"\"; } }",
        ])
        let routes = try await idx(store).endpoints.map(\.route); XCTAssertEqual(routes, ["/v1"])
        await store.update(url: url("Api"), source: "package app; \(web) interface Api { @GetMapping(\"/v2\") String get(); }")
        let moved = try await idx(store).endpoints.map(\.route); XCTAssertEqual(moved, ["/v2"])
    }

    func testRemovingAFileRemovesItsEndpoints() async throws {
        let store = await makeStore(fixtures())
        _ = await store.endpointIndexes()
        await store.remove(url: url("C1"))
        let routes = try await idx(store).endpoints.map(\.route); XCTAssertEqual(routes, ["/two"])
    }

    func testACancelledRequestLeavesTheStoreConsistent() async throws {
        let store = await makeStore(fixtures())
        let task = Task { await store.endpointIndexes().first?.endpoints.count }
        task.cancel()
        _ = await task.value
        let i = try await idx(store)
        XCTAssertEqual(i.endpoints.count, 2)
    }

    // MARK: Modules and application contexts

    private func module(_ path: String, deps: Set<String> = [], features: Set<SpringFeature>) -> SpringModuleInfo {
        SpringModuleInfo(
            projectPath: path, directory: URL(fileURLWithPath: "/ws/\(path.dropFirst())"), frameworkVersion: "6.1.0", bootVersion: nil,
            features: features, sourceRoots: [URL(fileURLWithPath: "/ws/\(path.dropFirst())/src/main/java")], resourceRoots: [],
            classpathJars: [], outputDirs: [], dependencyPaths: deps, isSpring: true)
    }

    func testEachApplicationHasItsOwnEndpointsAndStack() async throws {
        let store = SpringProjectModel()
        await store.setModules([
            module(":a", deps: [":lib"], features: [.framework, .mvc]), module(":b", deps: [":lib"], features: [.framework, .webflux]),
            module(":c", deps: [":lib"], features: [.framework, .mvc]), module(":lib", features: [.framework]),
        ])
        func file(_ m: String, _ n: String) -> URL { URL(fileURLWithPath: "/ws/\(m)/src/main/java/\(n).java") }
        let boot = "import org.springframework.boot.autoconfigure.SpringBootApplication;"
        await store.update(url: file("lib", "Lib"), source: "package com.acme.lib; \(web) @RestController public class LibController { @GetMapping(\"/lib\") String l() { return \"\"; } }")
        await store.update(url: file("a", "A"), source: "package com.acme.a; \(boot) @SpringBootApplication(scanBasePackages = {\"com.acme.a\", \"com.acme.lib\"}) public class AppA {}")
        await store.update(url: file("b", "B"), source: "package com.acme.b; \(boot) @SpringBootApplication(scanBasePackages = {\"com.acme.b\", \"com.acme.lib\"}) public class AppB {}")
        await store.update(url: file("c", "C"), source: "package com.acme.c; \(boot) @SpringBootApplication public class AppC {}")
        let indexes = await store.endpointIndexes()
        let byName = Dictionary(uniqueKeysWithValues: indexes.map { ($0.contextID, $0) })
        let a = try XCTUnwrap(byName["com.acme.a.AppA"]), b = try XCTUnwrap(byName["com.acme.b.AppB"]), c = try XCTUnwrap(byName["com.acme.c.AppC"])
        XCTAssertEqual(a.endpoints.map(\.route), ["/lib"]); XCTAssertEqual(a.endpoints.first?.stack, .mvc)
        XCTAssertEqual(b.endpoints.map(\.route), ["/lib"]); XCTAssertEqual(b.endpoints.first?.stack, .webflux)
        XCTAssertTrue(c.endpoints.isEmpty, "AppC's scan never reaches the shared controller")
        XCTAssertNotEqual(a.endpoints.first?.id, b.endpoints.first?.id, "identity includes the application context")
        XCTAssertEqual(a.endpoints.first?.module, ":lib")
        XCTAssertEqual(a.modules, [":lib"])
    }

    func testControllersOfASpringBootApplicationAreIndexedThroughItsScan() async throws {
        let i = try await index(["A": """
        package app;
        import org.springframework.boot.autoconfigure.SpringBootApplication;
        \(web)
        @SpringBootApplication public class App {}
        @RestController class H { @GetMapping("/health") String health() { return "ok"; } }
        """])
        XCTAssertEqual(i.contextID, "app.App")
        XCTAssertEqual(i.endpoints.map(\.route), ["/health"])
    }

    // MARK: Search

    func testSearchFiltersAndSorting() async throws {
        let i = try await index(["C": customers, "D": "package app; \(web) @RestController class Other { @DeleteMapping(\"/zzz\") void d() {} }"])
        var f = SpringEndpointFilter()
        f.text = "customers post"
        XCTAssertEqual(i.search(f).map(\.title), ["POST /api/customers"])
        f = SpringEndpointFilter(); f.methods = ["DELETE"]
        XCTAssertEqual(i.search(f).map(\.title), ["DELETE /zzz"])
        f = SpringEndpointFilter(); f.text = "other"
        XCTAssertEqual(i.search(f).map(\.handler), ["d"], "controller names are searched")
        f = SpringEndpointFilter(); f.sort = .method
        XCTAssertEqual(i.search(f).first?.conditions.methods.first, "GET", "GET sorts first")
        XCTAssertEqual(i.search(f).last?.methodsTitle, "DELETE")
        f = SpringEndpointFilter(); f.sort = .controller
        XCTAssertEqual(i.search(f).last?.controllerSimpleName, "Other")
    }

    func testRoutesCanBeMatchedAgainstConcreteRequests() async throws {
        let i = try await index(["C": customers])
        XCTAssertEqual(i.endpoints(matchingPath: "/api/customers/42", method: "GET").map(\.handler), ["find"])
        XCTAssertEqual(i.endpoints(matchingPath: "/api/customers", method: "POST").map(\.handler), ["create"])
        XCTAssertTrue(i.endpoints(matchingPath: "/api/customers", method: "GET").isEmpty)
        XCTAssertEqual(i.endpoints(matchingPath: "/api/customers/{{id}}", method: "GET").map(\.handler), ["find"], "an unresolved template variable matches")
        XCTAssertTrue(SpringRoute.matches(pattern: "/files/{name}.{ext}", path: "/files/a.txt"))
        XCTAssertTrue(SpringRoute.matches(pattern: "/n/{id:\\d+}", path: "/n/12"))
        XCTAssertFalse(SpringRoute.matches(pattern: "/n/{id:\\d+}", path: "/n/x"))
        XCTAssertTrue(SpringRoute.matches(pattern: "/static/**", path: "/static/a/b/c.css"))
        XCTAssertFalse(SpringRoute.matches(pattern: "/a/*", path: "/a/b/c"))
    }

    // MARK: Request generation

    func testGeneratedRequestsUsePlaceholdersAndNeverAssumeAPort() async throws {
        let i = try await index(["C": customers, "P": "package app; \(web) @RestController class P { @GetMapping(value = \"/q/{id}\", produces = \"application/json\") String q(@PathVariable Long id, @RequestParam String filter, @RequestParam(required = false) String page) { return \"\"; } }"])
        let q = try endpoint(i, "GET /q/{id}")
        let text = SpringHTTPRequest.render(q, base: .unknown)
        XCTAssertTrue(text.contains("GET {{baseUrl}}/q/{{id}}?filter={{filter}}"), text)
        XCTAssertTrue(text.contains("Accept: application/json"))
        XCTAssertTrue(text.contains("@id = 1"))
        XCTAssertTrue(text.contains("@baseUrl = http://localhost:<set-the-port>"), "an explicit placeholder, never 8080")
        XCTAssertFalse(text.contains("8080"))
        XCTAssertTrue(text.contains("Optional request parameters: page"))
        let create = try endpoint(i, "POST /api/customers")
        let post = SpringHTTPRequest.render(create, base: .unknown)
        XCTAssertTrue(post.contains("POST {{baseUrl}}/api/customers\n"), post)
        XCTAssertTrue(post.contains("Content-Type: application/json"))
        XCTAssertTrue(post.contains("\"name\": \"string\""), "the body skeleton comes from Customer's fields")
    }

    func testTheBaseURLComesFromConfigurationWhenItNamesAPort() async throws {
        let store = await makeStore(["C": customers])
        await store.updateConfig(url: URL(fileURLWithPath: "/p/application.properties"), text: "server.port=9090\nserver.servlet.context-path=/shop\n")
        let config = await store.config()
        let base = SpringHTTPRequest.baseURL(config: config, stack: .mvc)
        XCTAssertEqual(base.value, "http://localhost:9090/shop")
        XCTAssertEqual(SpringHTTPRequest.baseURL(config: nil, stack: .mvc), .unknown)
        let none = await makeStore([:])
        await none.updateConfig(url: URL(fileURLWithPath: "/p/application.properties"), text: "spring.application.name=x\n")
        let noPort = await none.config()
        XCTAssertNil(SpringHTTPRequest.baseURL(config: noPort, stack: .mvc).value, "no server.port: the default is not assumed")
        await none.updateConfig(url: URL(fileURLWithPath: "/p/application.properties"), text: "server.port=${PORT:7070}\n")
        let withDefault = await none.config()
        XCTAssertEqual(SpringHTTPRequest.baseURL(config: withDefault, stack: .mvc).value, "http://localhost:7070")
    }

    // MARK: Related references

    func testRequestsInHttpFilesAndTestsAreFoundByRouteMatch() async throws {
        let i = try await index(["C": customers])
        let find = try endpoint(i, "GET /api/customers/{id}")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("endpoint-refs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let tests = root.appendingPathComponent("src/test/java")
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        try "### list\nGET {{baseUrl}}/api/customers/42\n\nPOST {{baseUrl}}/api/customers/42\n".write(to: root.appendingPathComponent("requests.http"), atomically: true, encoding: .utf8)
        try "class T { void t() throws Exception { mvc.perform(get(\"/api/customers/7\")); mvc.perform(post(\"/api/customers/7\")); } }".write(to: tests.appendingPathComponent("T.java"), atomically: true, encoding: .utf8)
        let hits = SpringEndpointReferences.find(endpoint: find, roots: [root])
        XCTAssertEqual(hits.map(\.kind).sorted { $0.rawValue < $1.rawValue }, [.httpRequest, .test], "POSTs do not call a GET-only handler")
        XCTAssertEqual(hits.first { $0.kind == .httpRequest }?.line, 1)
    }
}
