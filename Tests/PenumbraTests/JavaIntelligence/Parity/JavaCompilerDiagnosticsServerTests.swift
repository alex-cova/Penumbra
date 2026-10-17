import EditorIntelligence
import Foundation
import XCTest
@testable import JavaIntelligence

/// The warm path of `JavaCompilerDiagnosticsService`: a server backend behind the same API,
/// overlays from open buffers, exact ranges with `javac:<key>` codes, and the cold CLI as the
/// fallback. Needs a real JDK; skipped without one.
final class JavaCompilerDiagnosticsServerTests: XCTestCase {
    private var root: URL!
    private var clients: [JavaAnalysisServerClient] = []
    private var directories: [URL] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("javac-svc-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directories.append(root)
    }

    override func tearDown() async throws {
        for client in clients { await client.shutdown() }
        clients.removeAll()
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(URL, [Diagnostic])] = []
        func append(_ url: URL, _ diagnostics: [Diagnostic]) { lock.lock(); stored.append((url, diagnostics)); lock.unlock() }
        var results: [(URL, [Diagnostic])] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private func makeClient() throws -> JavaAnalysisServerClient {
        let environment = try ParityTestSupport.requireEnvironment()
        let client = ParityTestSupport.makeClient(jarURL: environment.jarURL, jdk: environment.jdk)
        clients.append(client)
        return client
    }

    private func makeConfiguration() throws -> JavaCompilerDiagnosticsService.Configuration {
        let environment = try ParityTestSupport.requireEnvironment()
        return .init(
            kind: .plainFolder, jdk: environment.jdk, projectRoot: root,
            workDirectory: root.appendingPathComponent("work")
        )
    }

    private func makeService(client: JavaAnalysisServerClient?) async throws -> (JavaCompilerDiagnosticsService, ResultBox) {
        let service = JavaCompilerDiagnosticsService(idleDelay: .milliseconds(10))
        let box = ResultBox()
        await service.setResultHandler { box.append($0, $1) }
        await service.configure(try makeConfiguration())
        if let client {
            await service.setServerBackend(.init(client: client))
        }
        return (service, box)
    }

    private func makeDocument(text: String, url: URL) -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            id: DocumentID(), url: url, displayName: url.lastPathComponent,
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
    }

    private func waitUntil(timeout: TimeInterval = 30, _ condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }

    func testServerBackendReportsKeyAndExactRange() async throws {
        let (service, box) = try await makeService(client: makeClient())
        let text = "class Foo {\n    Strin x;\n}\n"
        let url = root.appendingPathComponent("Foo.java")
        try text.write(to: url, atomically: true, encoding: .utf8)
        await service.compileNow(makeDocument(text: text, url: url))
        try await waitUntil { !box.results.isEmpty }

        let diagnostics = try XCTUnwrap(box.results.first?.1)
        XCTAssertEqual(diagnostics.count, 1)
        let diagnostic = diagnostics[0]
        XCTAssertEqual(diagnostic.code, "javac:compiler.err.cant.resolve.location")
        XCTAssertEqual(diagnostic.source, "javac")
        let range = NSRange(location: diagnostic.range.start.utf16Offset, length: diagnostic.range.end.utf16Offset - diagnostic.range.start.utf16Offset)
        XCTAssertEqual((text as NSString).substring(with: range), "Strin")
    }

    func testServerOverlaysShadowOpenBuffers() async throws {
        let (service, box) = try await makeService(client: makeClient())
        let barURL = root.appendingPathComponent("Bar.java")
        try "public class Bar {\n    public static String greet() { return \"hi\"; }\n}\n".write(to: barURL, atomically: true, encoding: .utf8)
        let fooText = "public class Foo {\n    String test() { return Bar.greet(); }\n}\n"
        let fooURL = root.appendingPathComponent("Foo.java")
        try fooText.write(to: fooURL, atomically: true, encoding: .utf8)

        // Without overlays the on-disk Bar resolves and the file is clean …
        await service.compileNow(makeDocument(text: fooText, url: fooURL))
        try await waitUntil { !box.results.isEmpty }
        XCTAssertTrue(box.results.last?.1.isEmpty == true, "\(box.results)")

        // … with the broken open buffer shadowing it, the call no longer resolves.
        let brokenBar = "public class Bar {\n}\n"
        await service.setOpenBufferProvider { [barURL] in [barURL: brokenBar] }
        await service.compileNow(makeDocument(text: fooText, url: fooURL), force: true)
        try await waitUntil { (box.results.last?.1.count ?? 0) > 0 }
        let diagnostics = try XCTUnwrap(box.results.last?.1)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.code, "javac:compiler.err.cant.resolve.location.args")
    }

    func testFallsBackToCliWhenServerIsUnusable() async throws {
        // A client pointed at a missing jar can never start its server: every compile must
        // still answer through the cold CLI path, with CLI-style (codeless) diagnostics.
        let environment = try ParityTestSupport.requireEnvironment()
        let dead = JavaAnalysisServerClient(configuration: JavaAnalysisServerConfiguration(
            jarURL: URL(fileURLWithPath: "/nonexistent/java-analysis-server.jar"),
            javaExecutable: environment.jdk.home.appendingPathComponent("bin/java")
        ))
        clients.append(dead)
        let (service, box) = try await makeService(client: dead)
        let text = "class Foo {\n    Strin x;\n}\n"
        let url = root.appendingPathComponent("Foo.java")
        try text.write(to: url, atomically: true, encoding: .utf8)
        await service.compileNow(makeDocument(text: text, url: url))
        try await waitUntil(timeout: 60) { !box.results.isEmpty }

        let diagnostics = try XCTUnwrap(box.results.first?.1)
        XCTAssertEqual(diagnostics.count, 1)
        // The CLI fallback has no javac keys, only message categories (or none).
        XCTAssertFalse(diagnostics[0].code?.hasPrefix("javac:compiler.") == true, "\(diagnostics)")
        let range = NSRange(location: diagnostics[0].range.start.utf16Offset, length: diagnostics[0].range.end.utf16Offset - diagnostics[0].range.start.utf16Offset)
        XCTAssertEqual((text as NSString).substring(with: range), "Strin")
    }
}
