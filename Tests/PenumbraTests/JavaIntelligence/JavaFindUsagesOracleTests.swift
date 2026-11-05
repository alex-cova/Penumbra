import Foundation
import XCTest
@testable import JavaIntelligence

/// F-17: the Find Usages oracle. A seeded fixture is scored two ways — Umbra's
/// `JavaFindUsagesProvider` and the analysis server's `usages` request (pure `javac` Trees
/// attribution over the same bytes) — and the site sets are compared per blind-spot class.
///
/// Fixture sources are ASCII on purpose: byte offsets and UTF-16 offsets coincide, so both
/// sides compare as `File.java:offset`.
final class JavaFindUsagesOracleTests: XCTestCase {
    private struct Fixture {
        let refs: JavaReferenceFixture
        let client: JavaAnalysisServerClient
        let moduleId = "oracle"

        var root: URL { refs.root }
    }

    private func makeFixture() async throws -> (JavaReferenceFixture, JavaFindUsagesProvider) {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Api.java", """
        public class Api {
            public static String €greet() { return "hi"; }
            public int count;
            public int add(int x) { return x; }
            public String add(String x) { return x; }
        }
        """)
        try fixture.add("App.java", """
        class App {
            String test() {
                String g = Api.greet();
                Api api = new Api();
                api.count = 1;
                int total = api.count + api.add(1) + api.add("x").length();
                return g;
            }
        }
        """)
        let environment = try await fixture.build(gradleModel: nil, indexPaths: nil)
        let provider = JavaFindUsagesProvider(
            index: environment.index,
            indexPaths: JavaIndexPaths(root: fixture.root.appendingPathComponent("cache"))
        )
        await provider.setProjectRoots([fixture.root])
        return (fixture, provider)
    }

    private func makeOracle(_ fixture: JavaReferenceFixture) async throws -> JavaAnalysisServerClient {
        let environment = try ParityTestSupport.requireEnvironment()
        let client = ParityTestSupport.makeClient(jarURL: environment.jarURL, jdk: environment.jdk)
        try await client.configure(JavaAnalysisServerModule(moduleId: "oracle", sourcepath: [fixture.root]))
        return client
    }

    /// `(file, line)` sites from the provider at the fixture caret. Lines, not offsets:
    /// the oracle reports selector spans (`Api.greet`) while the provider reports the name
    /// (`greet`); both identify the same line. Fixture sources keep one use per line.
    private func providerSites(
        _ provider: JavaFindUsagesProvider, _ fixture: JavaReferenceFixture
    ) async throws -> Set<String> {
        let caret = try XCTUnwrap(fixture.caretLocation)
        let usages = await provider.findUsages(
            source: try XCTUnwrap(fixture.sources[caret.file]), url: fixture.url(caret.file),
            utf16Offset: caret.utf16Offset
        )
        return Set(usages.map { "\($0.url.lastPathComponent):\($0.line + 1)" })
    }

    /// `(file, line)` sites from the oracle at the same caret, minus the declaration trees
    /// covering the caret itself (the provider drops declarations).
    private func oracleSites(
        _ client: JavaAnalysisServerClient, _ fixture: JavaReferenceFixture
    ) async throws -> Set<String> {
        let caret = try XCTUnwrap(fixture.caretLocation)
        let source = try XCTUnwrap(fixture.sources[caret.file])
        let usages = try await client.usages(
            moduleId: "oracle", file: fixture.url(caret.file), text: source, position: caret.utf16Offset
        )
        return Set(usages.compactMap { usage -> String? in
            let name = URL(fileURLWithPath: usage.file).lastPathComponent
            if name == caret.file,
               usage.offset <= caret.utf16Offset, caret.utf16Offset < usage.offset + usage.length {
                return nil
            }
            return "\(name):\(usage.line)"
        })
    }

    func testOracleAndProviderAgreeOnCrossFileCall() async throws {
        let (fixture, provider) = try await makeFixture()
        let client = try await makeOracle(fixture)
        let expected = try await oracleSites(client, fixture)
        XCTAssertFalse(expected.isEmpty, "the oracle must see the call")
        let provided = try await providerSites(provider, fixture)
        XCTAssertEqual(provided, expected)
    }

    func testOracleDistinguishesOverloads() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Api.java", """
        public class Api {
            public int €add(int x) { return x; }
            public String add(String x) { return x; }
        }
        """)
        try fixture.add("App.java", """
        class App {
            int intCall(Api api) { return api.add(1); }
            int stringCall(Api api) { return api.add("x").length(); }
        }
        """)
        let environment = try await fixture.build(gradleModel: nil, indexPaths: nil)
        let provider = JavaFindUsagesProvider(
            index: environment.index,
            indexPaths: JavaIndexPaths(root: fixture.root.appendingPathComponent("cache"))
        )
        await provider.setProjectRoots([fixture.root])
        let client = try await makeOracle(fixture)
        let expected = try await oracleSites(client, fixture)
        // The int call only: the String sibling and both declarations are not uses.
        XCTAssertEqual(expected.count, 1)
        XCTAssertTrue(expected.first?.hasPrefix("App.java") == true, "\(expected)")
        let providedOverloads = try await providerSites(provider, fixture)
        XCTAssertEqual(providedOverloads, expected)
    }

    func testOracleAndProviderAgreeOnConstructorDelegation() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Api.java", """
        public class Api {
            public €Api(int x) {}
        }
        """)
        try fixture.add("Use.java", """
        class Use extends Api {
            Use() { super(0); }
        }
        """)
        let environment = try await fixture.build(gradleModel: nil, indexPaths: nil)
        let provider = JavaFindUsagesProvider(
            index: environment.index,
            indexPaths: JavaIndexPaths(root: fixture.root.appendingPathComponent("cache"))
        )
        await provider.setProjectRoots([fixture.root])
        let client = try await makeOracle(fixture)
        let expected = try await oracleSites(client, fixture)
        // The `super(0)` delegation resolves to the `(int)` constructor, not its sibling.
        XCTAssertEqual(expected.count, 1)
        XCTAssertTrue(expected.first?.hasPrefix("Use.java") == true, "\(expected)")
        // The delegating file names the target (`extends Api`), so the name-gated search
        // visits it; the hypothesized blind spot does not reproduce on this shape.
        let provided = try await providerSites(provider, fixture)
        XCTAssertEqual(provided, expected)
    }
}
