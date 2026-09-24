import XCTest
import EditorIntelligence
@testable import JavaIntelligence

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[Diagnostic]] = []
    func append(_ diagnostics: [Diagnostic]) { lock.lock(); stored.append(diagnostics); lock.unlock() }
    var results: [[Diagnostic]] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// Runs the real `javac` from an installed JDK; skipped on machines without one.
final class JavaCompilerDiagnosticsRealJDKTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("javac-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func requireJavacJDK() throws -> JDKInstallation {
        let found = try XCTUnwrap(TestJDK.discovered, "No JDK installed") as TestJDK.Found
        guard let jdk = ReleaseFileParser.parse(found.home), jdk.javac != nil else {
            throw XCTSkip("The discovered JDK has no javac")
        }
        return jdk
    }

    private func check(_ text: String, jdk: JDKInstallation) async throws -> [Diagnostic] {
        let file = root.appendingPathComponent("Foo.java")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let service = JavaCompilerDiagnosticsService()
        let box = ResultBox()
        await service.setResultHandler { _, diagnostics in box.append(diagnostics) }
        await service.configure(.init(kind: .plainFolder, jdk: jdk, projectRoot: root, workDirectory: root.appendingPathComponent(".work")))

        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let document = Document(
            url: file, displayName: "Foo.java", contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position), viewport: Viewport(x: 0, y: 0, width: 1, height: 1),
            languageIdentifier: "java"
        )
        await service.compileNow(document)
        let deadline = Date().addingTimeInterval(60)
        while box.results.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return try XCTUnwrap(box.results.first, "javac never reported")
    }

    func testUndefinedSymbolIsReportedAtItsPosition() async throws {
        let jdk = try requireJavacJDK()
        let text = "public class Foo {\n    void m() {\n        Strin x = null;\n    }\n}\n"
        let diagnostics = try await check(text, jdk: jdk)

        XCTAssertEqual(diagnostics.count, 1)
        let diagnostic = try XCTUnwrap(diagnostics.first)
        XCTAssertEqual(diagnostic.severity, .error)
        XCTAssertEqual(diagnostic.range.start.line, 2)
        XCTAssertEqual(diagnostic.range.start.column, 8)
        let range = NSRange(location: diagnostic.range.start.utf16Offset, length: diagnostic.range.end.utf16Offset - diagnostic.range.start.utf16Offset)
        XCTAssertEqual((text as NSString).substring(with: range), "Strin")
        XCTAssertTrue(diagnostic.message.contains("cannot find symbol"))
    }

    func testCleanFileHasNoDiagnostics() async throws {
        let jdk = try requireJavacJDK()
        let diagnostics = try await check("public class Foo {\n    int m() { return 1; }\n}\n", jdk: jdk)
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testFlowErrorIsStillReportedWithoutGeneratingClasses() async throws {
        let jdk = try requireJavacJDK()
        let diagnostics = try await check("public class Foo {\n    int m() { }\n}\n", jdk: jdk)
        XCTAssertEqual(diagnostics.map(\.message).first?.contains("missing return statement"), true)
    }
}
