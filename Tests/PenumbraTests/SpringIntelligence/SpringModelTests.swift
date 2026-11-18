import XCTest
import JavaIntelligence
@testable import SpringIntelligence

final class SpringModelTests: XCTestCase {
    private func model(_ sources: [String: String], profiles: Set<String>? = nil) async -> SpringModel {
        let store = SpringProjectModel(activeProfiles: profiles)
        for (name, text) in sources { await store.update(url: URL(fileURLWithPath: "/p/\(name).java"), source: text) }
        return await store.model()
    }

    private func bean(_ m: SpringModel, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> SpringBean {
        try XCTUnwrap(m.beans.first { $0.name == name }, "bean \(name)", file: file, line: line)
    }

    private func resolution(_ m: SpringModel, owner: String, param: String) throws -> SpringResolution {
        let p = try XCTUnwrap(m.injectionPoints.first { $0.owner.raw.contains(owner) && $0.name == param })
        return try XCTUnwrap(m.resolutions[p])
    }

    // MARK: Annotation extraction

    func testAnnotationArgumentsAreExtracted() {
        let d = JavaDeclaredAnnotations.extract(source: """
        package a;
        @Foo(value = {"x", "y"}, type = Bar.class, flag = true)
        class C { @Qualifier("q") @Autowired private Svc s; void m(@Named("n") Svc p) {} }
        """)
        let t = d.types[0]
        XCTAssertEqual(t.annotations[0]["value"]?.strings, ["x", "y"])
        XCTAssertEqual(t.annotations[0]["type"]?.classLiterals, ["Bar"])
        XCTAssertEqual(t.annotations[0]["flag"]?.scalarText, "true")
        XCTAssertEqual(t.fields[0].annotations.map(\.name), ["Qualifier", "Autowired"])
        XCTAssertEqual(t.methods[0].parameters[0].annotations[0]["value"]?.strings, ["n"])
    }

    // MARK: Beans

    func testStereotypesAndDefaultNames() async throws {
        let m = await model(["A": """
        package app;
        import org.springframework.stereotype.*;
        @Service class OrderService {}
        @Component class URLParser {}
        @Component("custom") class Named {}
        class NotABean {}
        interface Repo {}
        """])
        XCTAssertEqual(Set(m.beans.map(\.name)), ["orderService", "URLParser", "custom"])
    }

    func testComposedAnnotationIsAStereotype() async throws {
        let m = await model([
            "My": "package app; import org.springframework.stereotype.Service; @Service public @interface UseCase {}",
            "S": "package app; @UseCase class Checkout {}",
        ])
        XCTAssertEqual(m.beans.map(\.name), ["checkout"])
    }

    func testFactoryMethodsNameAndType() async throws {
        let m = await model(["C": """
        package app;
        import org.springframework.context.annotation.*;
        @Configuration class Cfg {
            @Bean Clock clock() { return null; }
            @Bean("gw") Gateway gateway() { return null; }
        }
        class Clock {} class Gateway {}
        """])
        XCTAssertEqual(try bean(m, "gw").type.name, "app.Gateway")
        XCTAssertNotNil(m.beans.first { $0.name == "clock" })
        XCTAssertNotNil(m.beans.first { $0.name == "cfg" })
    }

    // MARK: Resolution

    func testConstructorInjectionResolves() async throws {
        let m = await model(["A": """
        package app;
        import org.springframework.stereotype.*;
        interface Gateway {}
        @Service class Stripe implements Gateway {}
        @Service class Orders { Orders(Gateway g) {} }
        """])
        guard case .resolved(let id) = try resolution(m, owner: "Orders", param: "g") else { return XCTFail() }
        XCTAssertEqual(m.bean(id)?.name, "stripe")
        XCTAssertTrue(m.diagnostics.isEmpty)
    }

    func testMissingCandidateForProjectTypeIsAnError() async throws {
        let m = await model(["A": """
        package app;
        import org.springframework.stereotype.*;
        interface Gateway {}
        @Service class Orders { Orders(Gateway g) {} }
        """])
        XCTAssertEqual(try resolution(m, owner: "Orders", param: "g"), .missing)
        XCTAssertEqual(m.diagnostics.map(\.code), ["spring.no-candidate"])
        XCTAssertEqual(m.diagnostics[0].message, "No matching bean candidate for Gateway")
    }

    func testLibraryTypeIsNeverProvenMissing() async throws {
        let m = await model(["A": """
        package app;
        import org.springframework.stereotype.*;
        import javax.sql.DataSource;
        @Service class Orders { Orders(DataSource ds) {} }
        """])
        guard case .uncertain = try resolution(m, owner: "Orders", param: "ds") else { return XCTFail() }
        XCTAssertTrue(m.diagnostics.isEmpty)
    }

    func testImportResourceDowngradesMissingToUncertain() async throws {
        let m = await model(["A": """
        package app;
        import org.springframework.stereotype.*;
        import org.springframework.context.annotation.*;
        interface Gateway {}
        @ImportResource("beans.xml") @Configuration class Xml {}
        @Service class Orders { Orders(Gateway g) {} }
        """])
        guard case .uncertain = try resolution(m, owner: "Orders", param: "g") else { return XCTFail() }
        XCTAssertTrue(m.diagnostics.isEmpty)
    }

    private let twoGateways = """
    package app;
    import org.springframework.stereotype.*;
    import org.springframework.context.annotation.*;
    import org.springframework.beans.factory.annotation.*;
    interface Gateway {}
    @Service %@ class Stripe implements Gateway {}
    @Service class Paypal implements Gateway {}
    @Service class Orders { Orders(%@ Gateway %@) {} }
    """

    func testAmbiguityPrimaryQualifierAndNameFallback() async throws {
        var m = await model(["A": String(format: twoGateways, "", "", "g")])
        guard case .ambiguous(let ids) = try resolution(m, owner: "Orders", param: "g") else { return XCTFail() }
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(m.diagnostics.first?.code, "spring.ambiguous-candidates")

        m = await model(["A": String(format: twoGateways, "@Primary", "", "g")])
        guard case .resolved(let p) = try resolution(m, owner: "Orders", param: "g") else { return XCTFail() }
        XCTAssertEqual(m.bean(p)?.name, "stripe")

        m = await model(["A": String(format: twoGateways, "", "@Qualifier(\"paypal\")", "g")])
        guard case .resolved(let q) = try resolution(m, owner: "Orders", param: "g") else { return XCTFail() }
        XCTAssertEqual(m.bean(q)?.name, "paypal")

        m = await model(["A": String(format: twoGateways, "", "", "paypal")])
        guard case .resolved(let n) = try resolution(m, owner: "Orders", param: "paypal") else { return XCTFail() }
        XCTAssertEqual(m.bean(n)?.name, "paypal")

        m = await model(["A": String(format: twoGateways, "", "@Qualifier(\"nope\")", "g")])
        XCTAssertEqual(try resolution(m, owner: "Orders", param: "g"), .unknownQualifier("nope"))
    }

    func testCollectionsAndOptionalsAllowZeroMatches() async throws {
        let m = await model(["A": """
        package app;
        import java.util.*;
        import org.springframework.stereotype.*;
        interface Plugin {}
        @Service class Host { Host(List<Plugin> all, Optional<Plugin> one) {} }
        """])
        XCTAssertEqual(try resolution(m, owner: "Host", param: "all"), .collection([]))
        XCTAssertEqual(try resolution(m, owner: "Host", param: "one"), .missing)
        XCTAssertTrue(m.diagnostics.isEmpty, "Optional is not required")
    }

    func testGenericArgumentsSelectTheCandidate() async throws {
        let m = await model(["A": """
        package app;
        import org.springframework.stereotype.*;
        interface Handler<T> {}
        class A {} class B {}
        @Component class HandlerA implements Handler<A> {}
        @Component class HandlerB implements Handler<B> {}
        @Service class Svc { Svc(Handler<B> h) {} }
        """])
        guard case .resolved(let id) = try resolution(m, owner: "Svc", param: "h") else { return XCTFail() }
        XCTAssertEqual(m.bean(id)?.name, "handlerB")
    }

    // MARK: Conditions and profiles

    private let profiled = """
    package app;
    import org.springframework.stereotype.*;
    import org.springframework.context.annotation.*;
    interface Gateway {}
    @Service @Profile("prod") class Live implements Gateway {}
    @Service class Orders { Orders(Gateway g) {} }
    """

    func testProfilesAreActiveInactiveOrUnknown() async throws {
        var m = await model(["A": profiled], profiles: ["prod"])
        guard case .resolved = try resolution(m, owner: "Orders", param: "g") else { return XCTFail() }

        m = await model(["A": profiled], profiles: ["dev"])
        XCTAssertTrue(try bean(m, "live").certainty.isInactive)
        XCTAssertEqual(try resolution(m, owner: "Orders", param: "g"), .missing)

        m = await model(["A": profiled], profiles: nil)
        XCTAssertTrue(try bean(m, "live").certainty.isConditional)
        guard case .uncertain = try resolution(m, owner: "Orders", param: "g") else { return XCTFail() }
        XCTAssertFalse(m.diagnostics.contains { $0.severity == .error })
    }

    func testConditionalOnBeanIsNeverCertain() async throws {
        let m = await model(["A": """
        package app;
        import org.springframework.stereotype.*;
        import org.springframework.boot.autoconfigure.condition.*;
        @Component @ConditionalOnProperty("x.enabled") class Feature {}
        """])
        XCTAssertTrue(try bean(m, "feature").certainty.isConditional)
    }

    func testProfileExpressions() {
        XCTAssertTrue(SpringModelBuilder.profileMatches("!dev", ["prod"]))
        XCTAssertFalse(SpringModelBuilder.profileMatches("!dev", ["dev"]))
        XCTAssertTrue(SpringModelBuilder.profileMatches("a & b", ["a", "b"]))
        XCTAssertFalse(SpringModelBuilder.profileMatches("a & b", ["a"]))
        XCTAssertTrue(SpringModelBuilder.profileMatches("a | b", ["b"]))
    }

    // MARK: Cycles

    func testConstructorCycleIsProvenAndFieldCycleIsConfigurationDependent() async throws {
        var m = await model(["A": """
        package app;
        import org.springframework.stereotype.*;
        @Service class A { A(B b) {} }
        @Service class B { B(A a) {} }
        """])
        XCTAssertEqual(m.cycles.map(\.strength), [.proven])
        XCTAssertEqual(m.diagnostics.first { $0.code == "spring.circular-dependency" }?.severity, .error)

        m = await model(["A": """
        package app;
        import org.springframework.stereotype.*;
        import org.springframework.beans.factory.annotation.*;
        @Service class A { @Autowired B b; }
        @Service class B { B(A a) {} }
        """])
        XCTAssertEqual(m.cycles.map(\.strength), [.dependsOnConfiguration])

        m = await model(["A": """
        package app;
        import org.springframework.stereotype.*;
        import org.springframework.context.annotation.Lazy;
        @Service class A { A(B b) {} }
        @Service class B { B(@Lazy A a) {} }
        """])
        XCTAssertTrue(m.cycles.isEmpty)
    }

    func testDuplicateBeanNames() async throws {
        let m = await model(["A": """
        package app;
        import org.springframework.stereotype.*;
        @Component("x") class One {}
        @Component("x") class Two {}
        """])
        XCTAssertEqual(m.diagnostics.filter { $0.code == "spring.duplicate-bean-name" }.count, 2)
    }

    func testApplicationEntryPointDetection() async throws {
        let m = await model(["A": """
        package app;
        import org.springframework.boot.autoconfigure.SpringBootApplication;
        @SpringBootApplication class App {}
        """])
        XCTAssertEqual(m.applications.map(\.typeName), ["app.App"])
    }

    // MARK: Incremental behaviour

    func testBodyEditDoesNotInvalidateTheModel() async throws {
        let store = SpringProjectModel()
        let url = URL(fileURLWithPath: "/p/S.java")
        let v1 = "package a; import org.springframework.stereotype.*; @Service class S { void m() { int x = 1; } }"
        let v2 = "package a; import org.springframework.stereotype.*; @Service class S { void m() { int x = 1; int y = 2; // more\n } }"
        let v3 = "package a; import org.springframework.stereotype.*; @Service @Lazy class S { void m() {} }"
        let first = await store.update(url: url, source: v1)
        XCTAssertTrue(first)
        _ = await store.model()
        let rev = await store.revision
        let bodyEdit = await store.update(url: url, source: v2)
        XCTAssertFalse(bodyEdit)
        let afterBody = await store.revision
        XCTAssertEqual(afterBody, rev)
        let annotationEdit = await store.update(url: url, source: v3)
        XCTAssertTrue(annotationEdit)
        let afterAnnotation = await store.revision
        XCTAssertGreaterThan(afterAnnotation, rev)
    }

    func testRemovingAFileRemovesItsBeans() async throws {
        let store = SpringProjectModel()
        let url = URL(fileURLWithPath: "/p/S.java")
        await store.update(url: url, source: "package a; import org.springframework.stereotype.*; @Service class S {}")
        var m = await store.model()
        XCTAssertEqual(m.beans.count, 1)
        await store.remove(url: url)
        m = await store.model()
        XCTAssertTrue(m.beans.isEmpty)
    }
}
