import EditorIntelligence
import Foundation
import XCTest
@testable import JavaIntelligence

/// The merger's exit gate: one typo, one row. Skipped without a JDK.
final class JavaDiagnosticsMergerTests: XCTestCase {
    func testTypoShowsOneRow() async throws {
        let environment = try ParityTestSupport.requireEnvironment()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("java-merger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A JDK-backed index plus the file's own stubs, so the receiver type is known and
        // closed (the member rule reads the checked file's declarations from the index).
        let jdkShard = FileManager.default.temporaryDirectory.appendingPathComponent("merger-jdk-\(UUID().uuidString).idx")
        defer { try? FileManager.default.removeItem(at: jdkShard) }
        try JavaIndexShardWriter().write(
            try JDKCtSymRoot(installation: environment.jdk).readStubs(),
            stamp: JavaStamp(size: 0, modificationDate: 0), to: jdkShard)
        let projectShard = FileManager.default.temporaryDirectory.appendingPathComponent("merger-project-\(UUID().uuidString).idx")
        defer { try? FileManager.default.removeItem(at: projectShard) }
        let text = """
            import java.util.ArrayList;
            import java.util.List;

            class Typo {
                private List<String> items = new ArrayList<>();

                int count() {
                    return items.siz();
                }
            }
            """
        let url = root.appendingPathComponent("Typo.java")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try JavaIndexShardWriter().write(
            JavaSourceStubBuilder.build(source: text, url: url).classes,
            stamp: JavaStamp(size: 0, modificationDate: 0), to: projectShard)
        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 1, reader: try JavaIndexShardReader(url: projectShard)),
            .init(precedence: 3, reader: try JavaIndexShardReader(url: jdkShard)),
        ])

        let inspections = JavaInspectionService(
            index: index, enabledRules: [.unresolvedMember], idleDelay: .milliseconds(10))
        let compiler = JavaCompilerDiagnosticsService(idleDelay: .milliseconds(10))
        await compiler.configure(.init(
            kind: .plainFolder, jdk: environment.jdk, projectRoot: root,
            workDirectory: root.appendingPathComponent("work")
        ))
        let client = ParityTestSupport.makeClient(jarURL: environment.jarURL, jdk: environment.jdk)
        defer { Task { await client.shutdown() } }
        await compiler.setServerBackend(.init(client: client))

        let syntax = JavaSyntaxDiagnostics.provider(cache: inspections.documentParseCache)
        let composite = JavaSyntaxAwareDiagnostics(syntax: syntax, compiler: compiler, inspections: inspections)

        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let document = Document(
            id: DocumentID(), url: url, displayName: url.lastPathComponent,
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )

        // Prime both caches: the server error and the member finding each fire once …
        let compilerRows = await compiler.freshDiagnostics(for: document)
        XCTAssertEqual(compilerRows?.count, 1)
        await inspections.analyzeNow(document, force: true)
        let inspectionRows = await inspections.diagnostics(for: document)
        XCTAssertEqual(inspectionRows.map(\.code), ["unresolved-member"])
        // … and the composite shows one row, not two.
        let rows = await composite.diagnostics(for: document)
        XCTAssertEqual(rows.count, 1, "\(rows)")
        XCTAssertEqual(rows.first?.code, "javac:compiler.err.cant.resolve.location.args")
    }
}
