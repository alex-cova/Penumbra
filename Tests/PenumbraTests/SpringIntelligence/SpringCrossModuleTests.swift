import XCTest
import JavaIntelligence
@testable import SpringIntelligence

/// Application contexts over a multi-module workspace:
///
///     application/ (Application)  →  services/ (PaymentService)  →  persistence/ (PaymentRepository)
///
/// Spring registers only what its scan reaches, so a bean in a dependency module is *not* a bean of the application until
/// a scan or an `@Import` includes it.
final class SpringCrossModuleTests: XCTestCase {
    private func module(_ path: String, deps: Set<String> = [], isSpring: Bool = true) -> SpringModuleInfo {
        SpringModuleInfo(
            projectPath: path, directory: URL(fileURLWithPath: "/ws/\(path.dropFirst())"), frameworkVersion: "6.1.0", bootVersion: nil,
            features: [.framework], sourceRoots: [URL(fileURLWithPath: "/ws/\(path.dropFirst())/src/main/java")], resourceRoots: [],
            classpathJars: [], outputDirs: [], dependencyPaths: deps, isSpring: isSpring)
    }

    private func url(_ module: String, _ file: String) -> URL { URL(fileURLWithPath: "/ws/\(module.dropFirst())/src/main/java/\(file).java") }

    private func store(_ files: [(String, String, String)], modules: [SpringModuleInfo], profiles: Set<String>? = nil) async -> SpringProjectModel {
        let store = SpringProjectModel(activeProfiles: profiles)
        await store.setModules(modules)
        for (m, name, source) in files { await store.update(url: url(m, name), source: source) }
        return store
    }

    private func firstContext(_ s: SpringProjectModel) async throws -> SpringApplicationContext {
        let contexts = await s.contexts()
        return try XCTUnwrap(contexts.first)
    }
    private func chain() -> [SpringModuleInfo] {
        [module(":application", deps: [":services", ":persistence"]), module(":services", deps: [":persistence"]), module(":persistence")]
    }

    private let repository = "package com.acme.persistence; import org.springframework.stereotype.Repository; @Repository public class PaymentRepository {}"
    private let service = """
    package com.acme.services;
    import org.springframework.stereotype.Service;
    import com.acme.persistence.PaymentRepository;
    @Service public class PaymentService { public PaymentService(PaymentRepository repository) {} }
    """
    private func application(_ annotation: String, body: String = "") -> String {
        """
        package com.acme.app;
        import org.springframework.boot.autoconfigure.SpringBootApplication;
        import org.springframework.context.annotation.*;
        import org.springframework.stereotype.Component;
        \(annotation) public class Application {}
        @Component class Controller { Controller(com.acme.services.PaymentService payments) {} }
        \(body)
        """
    }

    func testDependencyModuleBeansOutsideTheScanAreNotBeansOfTheApplication() async throws {
        let s = await store([(":application", "Application", application("@SpringBootApplication")),
                             (":services", "PaymentService", service), (":persistence", "PaymentRepository", repository)], modules: chain())
        let contexts = await s.contexts()
        XCTAssertEqual(contexts.map(\.name), ["Application"])
        let ctx = contexts[0]
        XCTAssertEqual(ctx.scanPackages, ["com.acme.app"], "default scan is the entry class's package")
        XCTAssertEqual(ctx.moduleIDs, [":application", ":persistence", ":services"])
        XCTAssertEqual(Set(ctx.model.beans.map(\.name)), ["application", "controller"], "PaymentService is in a package no scan reaches")
        let point = try XCTUnwrap(ctx.model.injectionPoints.first { $0.name == "payments" })
        XCTAssertEqual(ctx.model.resolutions[point], .missing, "a project type, no bean: the error Spring itself would raise")
        XCTAssertEqual(ctx.model.unregistered[point]?.map(\.typeName), ["com.acme.services.PaymentService"],
                       "and the fix offered is to register the class in the other module")
    }

    func testScanBasePackagesReachAcrossModules() async throws {
        let s = await store([(":application", "Application", application("@SpringBootApplication(scanBasePackages = \"com.acme\")")),
                             (":services", "PaymentService", service), (":persistence", "PaymentRepository", repository)], modules: chain())
        let ctx = try await firstContext(s)
        XCTAssertEqual(Set(ctx.model.beans.map(\.name)), ["application", "controller", "paymentService", "paymentRepository"])
        let controller = try XCTUnwrap(ctx.model.injectionPoints.first { $0.name == "payments" })
        guard case .resolved(let id)? = ctx.model.resolutions[controller] else { return XCTFail("\(String(describing: ctx.model.resolutions[controller]))") }
        XCTAssertEqual(ctx.model.bean(id)?.location.url, url(":services", "PaymentService"), "resolved across the module boundary")
        let repoPoint = try XCTUnwrap(ctx.model.injectionPoints.first { $0.name == "repository" })
        guard case .resolved? = ctx.model.resolutions[repoPoint] else { return XCTFail("service → repository") }
        XCTAssertTrue(ctx.model.diagnostics.isEmpty, "\(ctx.model.diagnostics)")
    }

    func testBasePackageClassesAndComponentScanOnAConfigurationClass() async throws {
        let config = """
        package com.acme.app;
        import org.springframework.context.annotation.*;
        @Configuration @ComponentScan(basePackageClasses = com.acme.services.PaymentService.class) class ScanConfig {}
        """
        let s = await store([(":application", "Application", application("@SpringBootApplication")),
                             (":application", "ScanConfig", config),
                             (":services", "PaymentService", service), (":persistence", "PaymentRepository", repository)], modules: chain())
        let ctx = try await firstContext(s)
        XCTAssertTrue(ctx.model.beans.contains { $0.name == "paymentService" }, "the scan requested by a registered configuration class is followed")
        XCTAssertFalse(ctx.model.beans.contains { $0.name == "paymentRepository" }, "persistence package is not scanned")
        XCTAssertTrue(ctx.scanPackages.contains("com.acme.services"))
    }

    func testImportRegistersAClassOutsideTheScanEvenWithoutAStereotype() async throws {
        let servicesConfig = """
        package com.acme.services;
        import org.springframework.context.annotation.*;
        @Configuration public class ServicesConfig { @Bean public Clock clock() { return null; } }
        class Clock {}
        """
        let plain = "package com.acme.services; public class Plain {}"
        let app = application("@SpringBootApplication @Import({com.acme.services.ServicesConfig.class, com.acme.services.Plain.class})")
        let s = await store([(":application", "Application", app), (":services", "ServicesConfig", servicesConfig), (":services", "Plain", plain)], modules: chain())
        let ctx = try await firstContext(s)
        XCTAssertTrue(Set(ctx.model.beans.map(\.name)).isSuperset(of: ["servicesConfig", "clock", "plain"]), "\(ctx.model.beans.map(\.name))")
        XCTAssertEqual(Set(ctx.importedTypes), ["com.acme.services.ServicesConfig", "com.acme.services.Plain"])
    }

    func testImportOfALibraryConfigurationMakesTheContextOpaqueNotWrong() async throws {
        let app = application("@SpringBootApplication @Import(org.somelib.LibraryConfig.class)")
        let s = await store([(":application", "Application", app), (":services", "PaymentService", service), (":persistence", "PaymentRepository", repository)], modules: chain())
        let ctx = try await firstContext(s)
        let point = try XCTUnwrap(ctx.model.injectionPoints.first { $0.name == "payments" })
        guard case .uncertain? = ctx.model.resolutions[point] else { return XCTFail("a library @Import may register it: \(String(describing: ctx.model.resolutions[point]))") }
    }

    func testTwoApplicationsSharingAModuleDoNotMixTheirBeans() async throws {
        let mods = [module(":billing", deps: [":services"]), module(":shop", deps: [":services"]), module(":services")]
        let billing = """
        package com.acme.billing;
        import org.springframework.boot.autoconfigure.SpringBootApplication;
        import org.springframework.stereotype.Service;
        @SpringBootApplication(scanBasePackages = {"com.acme.billing", "com.acme.services"}) public class BillingApp {}
        @Service class Invoicer { Invoicer(com.acme.services.Notifier n) {} }
        """
        let shop = """
        package com.acme.shop;
        import org.springframework.boot.autoconfigure.SpringBootApplication;
        import org.springframework.stereotype.Service;
        @SpringBootApplication public class ShopApp {}
        @Service class Invoicer { Invoicer(com.acme.services.Notifier n) {} }
        """
        let notifier = "package com.acme.services; import org.springframework.stereotype.Service; @Service public class Notifier {}"
        let s = await store([(":billing", "BillingApp", billing), (":shop", "ShopApp", shop), (":services", "Notifier", notifier)], modules: mods)
        let contexts = await s.contexts()
        XCTAssertEqual(contexts.map(\.name).sorted(), ["BillingApp", "ShopApp"])
        let b = try XCTUnwrap(contexts.first { $0.name == "BillingApp" }), sh = try XCTUnwrap(contexts.first { $0.name == "ShopApp" })
        XCTAssertTrue(b.model.beans.contains { $0.name == "notifier" })
        XCTAssertFalse(sh.model.beans.contains { $0.name == "notifier" }, "ShopApp does not scan com.acme.services")
        XCTAssertEqual(b.model.beans.filter { $0.name == "invoicer" }.count, 1, "same bean name in two applications is not a duplicate")
        XCTAssertFalse(b.model.diagnostics.contains { $0.code == "spring.duplicate-bean-name" })
        XCTAssertFalse(sh.model.diagnostics.contains { $0.code == "spring.duplicate-bean-name" })

        // The shared file belongs to both contexts; the entry module's own context answers a request about it.
        let shared = url(":services", "Notifier")
        let containing = await s.contexts(containing: shared)
        XCTAssertEqual(Set(containing.map(\.name)), ["BillingApp", "ShopApp"])
        let invoicerShop = url(":shop", "ShopApp")
        let diagnostics = await SpringDiagnosticProvider.diagnostics(in: s, url: invoicerShop)
        XCTAssertTrue(diagnostics.contains { $0.code == "spring.no-candidate" && $0.severity == .error },
                      "Notifier is a project type nobody registers in ShopApp: an error in the only context that contains the file")
    }

    func testAProblemOnlySomeApplicationsHaveIsReportedAsContextSpecific() async throws {
        let mods = [module(":a", deps: [":lib"]), module(":b", deps: [":lib"]), module(":lib")]
        let lib = """
        package com.acme.lib;
        import org.springframework.stereotype.Service;
        public interface Port {}
        @Service class User { User(Port p) {} }
        """
        let impl = "package com.acme.a; import org.springframework.stereotype.Service; @Service class Adapter implements com.acme.lib.Port {}"
        let appA = "package com.acme.a; import org.springframework.boot.autoconfigure.SpringBootApplication; @SpringBootApplication(scanBasePackages = {\"com.acme.a\", \"com.acme.lib\"}) public class AppA {}"
        let appB = "package com.acme.b; import org.springframework.boot.autoconfigure.SpringBootApplication; @SpringBootApplication(scanBasePackages = {\"com.acme.b\", \"com.acme.lib\"}) public class AppB {}"
        let s = await store([(":a", "AppA", appA), (":a", "Adapter", impl), (":b", "AppB", appB), (":lib", "Lib", lib)], modules: mods)
        let diagnostics = await SpringDiagnosticProvider.diagnostics(in: s, url: url(":lib", "Lib"))
        let missing = try XCTUnwrap(diagnostics.first { $0.code == "spring.no-candidate" })
        XCTAssertEqual(missing.severity, .warning, "AppA provides the Port; only AppB lacks it")
        XCTAssertTrue(missing.message.hasSuffix("(in AppB only)"), missing.message)
    }

    func testModulesOutsideTheDependencyClosureAreInvisible() async throws {
        let mods = chain() + [module(":unrelated")]
        let stray = "package com.acme.app; import org.springframework.stereotype.Service; @Service public class Stray {}"
        let s = await store([(":application", "Application", application("@SpringBootApplication")),
                             (":unrelated", "Stray", stray)], modules: mods)
        let ctx = try await firstContext(s)
        XCTAssertFalse(ctx.model.beans.contains { $0.name == "stray" }, "same package name, but the module is not a dependency")
        XCTAssertFalse(ctx.fileURLs.contains(url(":unrelated", "Stray")))
        let model = await s.model(for: url(":unrelated", "Stray"))
        XCTAssertTrue(model.beans.isEmpty, "a file no application reaches gets no bean intelligence")
    }

    func testEditingASharedModuleInvalidatesOnlyTheContextsThatSeeIt() async throws {
        let mods = [module(":a", deps: [":lib"]), module(":b"), module(":lib")]
        let a = "package com.acme.a; import org.springframework.boot.autoconfigure.SpringBootApplication; @SpringBootApplication(scanBasePackages = {\"com.acme\"}) public class AppA {}"
        let b = "package com.acme.b; import org.springframework.boot.autoconfigure.SpringBootApplication; @SpringBootApplication public class AppB {}"
        let lib = "package com.acme.lib; import org.springframework.stereotype.Service; @Service public class Svc { void m() { int y = 0; } }"
        let s = await store([(":a", "AppA", a), (":b", "AppB", b), (":lib", "Svc", lib)], modules: mods)
        var contexts = await s.contexts()
        XCTAssertEqual(contexts.first { $0.name == "AppA" }?.model.beans.map(\.name).sorted(), ["appA", "svc"])
        XCTAssertEqual(contexts.first { $0.name == "AppB" }?.model.beans.map(\.name), ["appB"])

        await s.update(url: url(":lib", "Svc"), source: "package com.acme.lib; import org.springframework.stereotype.Service; @Service(\"renamed\") public class Svc { void m() { int y = 0; } }")
        contexts = await s.contexts()
        XCTAssertEqual(contexts.first { $0.name == "AppA" }?.model.beans.map(\.name).sorted(), ["appA", "renamed"])
        XCTAssertEqual(contexts.first { $0.name == "AppB" }?.model.beans.map(\.name), ["appB"], "AppB cannot see the lib module")

        // A body-only edit does not rebuild anything.
        let before = await s.revision
        await s.update(url: url(":lib", "Svc"), source: "package com.acme.lib; import org.springframework.stereotype.Service; @Service(\"renamed\") public class Svc { void m() { int y = 1; int z = 2; } }")
        let after = await s.revision
        XCTAssertEqual(before, after)
    }

    func testNoApplicationClassKeepsTheWholeProjectAsOneDefaultContext() async throws {
        let s = await store([(":services", "PaymentService", service), (":persistence", "PaymentRepository", repository)], modules: chain())
        let contexts = await s.contexts()
        XCTAssertEqual(contexts.map(\.id), ["default"])
        XCTAssertEqual(Set(contexts[0].model.beans.map(\.name)), ["paymentService", "paymentRepository"])
    }

    func testDetectorIncludesPlainDependencyModulesAndTheirProjectGraph() throws {
        func jar(_ g: String, _ a: String) -> URL { URL(fileURLWithPath: "/h/.gradle/caches/modules-2/files-2.1/\(g)/\(a)/6.1.0/x/\(a)-6.1.0.jar") }
        let root = URL(fileURLWithPath: "/ws")
        func sub(_ path: String, deps: [String], jars: [URL]) -> JavaGradleProjectModel.Subproject {
            .init(path: path, directory: root.appendingPathComponent(String(path.dropFirst())),
                  sourceSets: [.init(name: "main", sourceDirs: [root.appendingPathComponent("\(path.dropFirst())/src/main/java")],
                                     compileClasspathJars: jars, projectDependencies: deps.map { .init(projectPath: $0, sourceSetName: "main") },
                                     runtimeProjectDependencies: deps.map { .init(projectPath: $0, sourceSetName: "main") })])
        }
        let model = JavaGradleProjectModel(formatVersion: 9, gradleVersion: "8", subprojects: [
            sub(":app", deps: [":domain"], jars: [jar("org.springframework", "spring-context")]),
            sub(":domain", deps: [":util"], jars: []),
            sub(":util", deps: [], jars: []),
            sub(":other", deps: [], jars: []),
        ])
        let found = SpringProjectDetector.detect(in: model)
        XCTAssertEqual(found.map(\.projectPath), [":app", ":domain", ":util"], ":other is not reachable from a Spring module")
        XCTAssertEqual(found.map(\.isSpring), [true, false, false])
        XCTAssertEqual(found[0].dependencyPaths, [":domain", ":util"], "transitive")
    }
}
