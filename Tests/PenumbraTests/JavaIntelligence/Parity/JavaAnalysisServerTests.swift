import Foundation
import XCTest
@testable import JavaIntelligence

/// PR1 exit gate: the analysis server's `check` matches CLI `javac` output on mutated sources,
/// plus the lifecycle the editor needs (configure/check/shutdown, overlays, idle shutdown and
/// relaunch, cancel). Skipped on machines without a JDK.
///
/// The full mutation corpus and its `baseline.json` ratchet arrive with PR2
/// (`docs/JAVA_COVERAGE_PROFILING_PLAN.md` is not this plan; see the java-intelligence-parity
/// plan §0.3); these hand-written mutations pin the protocol first.
final class JavaAnalysisServerTests: XCTestCase {
    private struct Fixture {
        let name: String
        /// Extra files on disk (and, unless shadowed, visible to the check).
        let files: [String: String]
        let checkFile: String
        let checkText: String
        /// Overlays sent with the check.
        let overlays: [String: String]
        /// Expected `javac` keys for the checked file (prefix match: the oracle owns key names).
        let expectedKeyPrefixes: [String]
    }

    private static let typoType = Fixture(
        name: "typoType",
        files: [:],
        checkFile: "Foo.java",
        checkText: """
            public class Foo {
                private Strin name;
            }
            """,
        overlays: [:],
        expectedKeyPrefixes: ["compiler.err.cant.resolve.location"]
    )

    private static let badArgs = Fixture(
        name: "badArgs",
        files: [:],
        checkFile: "Foo.java",
        checkText: """
            public class Foo {
                void take(String s) {}
                void test() { take(1, 2); }
            }
            """,
        overlays: [:],
        expectedKeyPrefixes: ["compiler.err.cant.apply.symbol"]
    )

    private static let missingReturn = Fixture(
        name: "missingReturn",
        files: [:],
        checkFile: "Foo.java",
        checkText: """
            public class Foo {
                int get() {
                    int x = 1;
                }
            }
            """,
        overlays: [:],
        expectedKeyPrefixes: ["compiler.err.missing.ret.stmt"]
    )

    private static let unreportedException = Fixture(
        name: "unreportedException",
        files: [:],
        checkFile: "Foo.java",
        checkText: """
            public class Foo {
                void run() {
                    throw new java.io.IOException("x");
                }
            }
            """,
        overlays: [:],
        expectedKeyPrefixes: ["compiler.err.unreported.exception"]
    )

    private static let valid = Fixture(
        name: "valid",
        files: ["Bar.java": "public class Bar {\n    public static String greet() { return \"hi\"; }\n}\n"],
        checkFile: "Foo.java",
        checkText: "public class Foo {\n    String test() { return Bar.greet(); }\n}\n",
        overlays: [:],
        expectedKeyPrefixes: []
    )

    private static let brokenOverlay = Fixture(
        name: "brokenOverlay",
        files: ["Bar.java": "public class Bar {\n    public static String greet() { return \"hi\"; }\n}\n"],
        checkFile: "Foo.java",
        checkText: "public class Foo {\n    String test() { return Bar.greet(); }\n}\n",
        overlays: ["Bar.java": "public class Bar {\n}\n"],
        expectedKeyPrefixes: ["compiler.err.cant.resolve"]
    )

    private var root: URL!
    private var clients: [JavaAnalysisServerClient] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("java-analysis-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for client in clients { await client.shutdown() }
        clients.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Environment

    private func makeClient(idleTimeout: Duration = .seconds(600)) throws -> JavaAnalysisServerClient {
        let environment = try ParityTestSupport.requireEnvironment()
        let client = ParityTestSupport.makeClient(jarURL: environment.jarURL, jdk: environment.jdk, idleTimeout: idleTimeout)
        clients.append(client)
        return client
    }

    private func write(_ fixture: Fixture) throws -> URL {
        for (name, text) in fixture.files {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let file = root.appendingPathComponent(fixture.checkFile)
        try fixture.checkText.write(to: file, atomically: true, encoding: .utf8)
        // /tmp sits behind a symlink (/var -> /private/var); resolve it so the server's echo of
        // the file path compares equal to what the test passes.
        return file.resolvingSymlinksInPath()
    }

    // MARK: - Protocol

    func testValidFileIsClean() async throws {
        let client = try makeClient()
        let file = try write(Self.valid)
        try await client.configure(JavaAnalysisServerModule(moduleId: "m", sourcepath: [root]))
        let diagnostics = try await client.check(moduleId: "m", file: file, text: Self.valid.checkText)
        XCTAssertTrue(diagnostics.isEmpty, "expected no diagnostics, got \(diagnostics)")
    }

    func testExpectedKeys() async throws {
        let client = try makeClient()
        for fixture in [Self.typoType, Self.badArgs, Self.missingReturn, Self.unreportedException] {
            let file = try write(fixture)
            try await client.configure(JavaAnalysisServerModule(moduleId: fixture.name, sourcepath: [root]))
            let diagnostics = try await client.check(moduleId: fixture.name, file: file, text: fixture.checkText)
                .filter { $0.file == file.path }
            XCTAssertEqual(diagnostics.count, fixture.expectedKeyPrefixes.count, "\(fixture.name): \(diagnostics)")
            for (diagnostic, prefix) in zip(diagnostics, fixture.expectedKeyPrefixes) {
                XCTAssertTrue(diagnostic.key.hasPrefix(prefix), "\(fixture.name): key \(diagnostic.key) has prefix \(prefix)")
                XCTAssertEqual(diagnostic.severity, .error)
                XCTAssertNotNil(diagnostic.start, "\(fixture.name): expected a position")
                XCTAssertNotNil(diagnostic.end)
            }
        }
    }

    func testTypoRangeCoversTheName() async throws {
        let client = try makeClient()
        let file = try write(Self.typoType)
        try await client.configure(JavaAnalysisServerModule(moduleId: "m", sourcepath: [root]))
        let diagnostics = try await client.check(moduleId: "m", file: file, text: Self.typoType.checkText)
        let diagnostic = try XCTUnwrap(diagnostics.first)
        let start = try XCTUnwrap(diagnostic.start)
        let end = try XCTUnwrap(diagnostic.end)
        let utf16 = Array(Self.typoType.checkText.utf16)
        XCTAssertEqual(String(decoding: utf16[start..<end], as: UTF16.self), "Strin")
        let mapped = try XCTUnwrap(diagnostic.diagnostic(in: Self.typoType.checkText))
        XCTAssertEqual(mapped.code, "javac:\(diagnostic.key)")
    }

    func testOverlaysShadowTheDisk() async throws {
        let client = try makeClient()
        // Without the overlay, Bar comes from disk and the file is clean …
        let cleanFile = try write(Self.valid)
        try await client.configure(JavaAnalysisServerModule(moduleId: "m", sourcepath: [root]))
        let clean = try await client.check(moduleId: "m", file: cleanFile, text: Self.valid.checkText)
        XCTAssertTrue(clean.isEmpty, "expected no diagnostics, got \(clean)")
        // … with the broken overlay, the call no longer resolves.
        let fixture = Self.brokenOverlay
        let file = try write(fixture)
        let overlays = fixture.overlays.map { JavaAnalysisServerOverlay(file: root.appendingPathComponent($0.key).resolvingSymlinksInPath(), text: $0.value) }
        let diagnostics = try await client.check(moduleId: "m", file: file, text: fixture.checkText, overlays: overlays)
            .filter { $0.file == file.path }
        XCTAssertEqual(diagnostics.count, 1, "\(diagnostics)")
        XCTAssertTrue(diagnostics.first?.key.hasPrefix("compiler.err.cant.resolve") == true)
    }

    func testShutdownThenCheckRelaunches() async throws {
        let client = try makeClient()
        let file = try write(Self.typoType)
        try await client.configure(JavaAnalysisServerModule(moduleId: "m", sourcepath: [root]))
        let before = try await client.check(moduleId: "m", file: file, text: Self.typoType.checkText)
        XCTAssertFalse(before.isEmpty)
        await client.shutdown()
        let after = try await client.check(moduleId: "m", file: file, text: Self.typoType.checkText)
        XCTAssertEqual(after.map(\.key), before.map(\.key))
    }

    func testIdleShutdownThenCheckRelaunches() async throws {
        let client = try makeClient(idleTimeout: .milliseconds(300))
        let file = try write(Self.typoType)
        try await client.configure(JavaAnalysisServerModule(moduleId: "m", sourcepath: [root]))
        let first = try await client.check(moduleId: "m", file: file, text: Self.typoType.checkText)
        XCTAssertFalse(first.isEmpty)
        // The server exits on idle; the next check must transparently relaunch it.
        try await Task.sleep(for: .seconds(2))
        let after = try await client.check(moduleId: "m", file: file, text: Self.typoType.checkText)
        XCTAssertEqual(after.count, 1)
    }

    func testCancelCompletedCheckReportsCancelled() async throws {
        let client = try makeClient()
        let file = try write(Self.typoType)
        try await client.configure(JavaAnalysisServerModule(moduleId: "m", sourcepath: [root]))
        let handle = try await client.beginCheck(moduleId: "m", file: file, text: Self.typoType.checkText)
        let count = try await client.result(for: handle).count
        XCTAssertEqual(count, 1)
        await client.cancel(handle)
        do {
            _ = try await client.result(for: handle)
            XCTFail("expected cancelled")
        } catch let error as JavaAnalysisServerError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    // MARK: - PR1 exit gate: check matches CLI javac

    func testCheckMatchesCliJavac() async throws {
        let jdk = try ParityTestSupport.requireJDK()
        let javac = try XCTUnwrap(jdk.javac)
        let client = try makeClient()
        let fixtures = [Self.typoType, Self.badArgs, Self.missingReturn, Self.unreportedException, Self.valid]
        for fixture in fixtures {
            let file = try write(fixture)
            try await client.configure(JavaAnalysisServerModule(moduleId: fixture.name, sourcepath: [root]))
            let server = try await client.check(moduleId: fixture.name, file: file, text: fixture.checkText)
                .filter { $0.file == file.path }
            let cli = try runCliJavac(javac, file: file)
            XCTAssertEqual(
                serverPlaces(server, text: fixture.checkText), cliPlaces(cli),
                "\(fixture.name): server \(server) vs CLI \(cli)"
            )
            XCTAssertEqual(server.count, fixture.expectedKeyPrefixes.count, "\(fixture.name): key count")
            for (diagnostic, prefix) in zip(server, fixture.expectedKeyPrefixes) {
                XCTAssertTrue(diagnostic.key.hasPrefix(prefix), "\(fixture.name): key \(diagnostic.key)")
            }
        }
    }

    /// Where an error is, not how it is worded: the CLI prints diagnostics through its
    /// simplifying console printer (`IOException`) while `Diagnostic.getMessage()` returns the
    /// raw form (`java.io.IOException`). The scorecard measures recall per key at the same
    /// range, so places (line, severity) must match exactly while messages never compare. Keys
    /// have no CLI counterpart; each fixture pins its own expected key prefixes instead.
    private struct Place: Equatable, CustomStringConvertible {
        let line: Int
        let severity: String
        var description: String { "\(line) \(severity)" }
    }

    private func serverPlaces(_ diagnostics: [JavaAnalysisServerDiagnostic], text: String) -> [Place] {
        // The compared line is the diagnostic's preferred position (what the CLI prints), not
        // the line its start offset sits on: the two differ for keys like missing.ret.stmt.
        let lines = LineTable(text)
        return diagnostics.map { diagnostic in
            let line = diagnostic.line
                ?? diagnostic.start.map { lines.position(atOffset: $0).line + 1 }
                ?? 0
            return Place(
                line: line,
                severity: diagnostic.severity == .error ? "error" : "warning"
            )
        }.sorted { ($0.line, $0.severity) < ($1.line, $1.severity) }
    }

    private func cliPlaces(_ messages: [JavacMessage]) -> [Place] {
        messages.map { message in
            Place(
                line: message.file == nil ? 0 : message.line,
                severity: message.severity == .error ? "error" : "warning"
            )
        }.sorted { ($0.line, $0.severity) < ($1.line, $1.severity) }
    }

    private func runCliJavac(_ javac: URL, file: URL) throws -> [JavacMessage] {
        let classes = root.appendingPathComponent("classes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: classes, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = javac
        process.arguments = [
            "-J-Duser.language=en", "-J-Duser.country=US",
            "-encoding", "UTF-8",
            "-Xmaxerrs", "200", "-Xmaxwarns", "200",
            "-proc:none",
            "-sourcepath", root.path,
            "-d", classes.path,
            file.path,
        ]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        let output = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return JavacOutputParser.parse(output)
    }
}
