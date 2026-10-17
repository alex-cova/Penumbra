import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// `JavaBuildDiagnosticsService`: last-build rows served back for the text they were mapped
/// against, stale once the file moves on, and cleared per source, per file, or all at once.
final class JavaBuildDiagnosticsServiceTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/proj/Foo.java")
    private let text = "class Foo {\n    void m() {\n        runs.forach(x);\n    }\n}\n"

    private func makeDocument(text: String? = nil, url: URL? = nil, language: String = "java") -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            id: DocumentID(), url: url ?? self.url, displayName: "Foo.java",
            contentSnapshot: TextSnapshot(version: 0, text: text ?? self.text),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: language
        )
    }

    private func makeNoURLDocument() -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            displayName: "Untitled", contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position), viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
    }

    private func makeDiagnostic(message: String = "cannot find symbol", source: String = "gradle") -> Diagnostic {
        let position = TextPosition(line: 2, column: 8, utf16Offset: 30)
        return Diagnostic(
            severity: .error, message: message,
            range: TextRange(start: position, end: TextPosition(line: 2, column: 14, utf16Offset: 36)),
            source: source
        )
    }

    func testServesPublishedRowsForUnchangedText() async {
        let service = JavaBuildDiagnosticsService()
        await service.publish(texts: [url: text], diagnostics: [url: [makeDiagnostic()]], source: "gradle")

        let found = await service.diagnostics(for: makeDocument())
        XCTAssertEqual(found.map(\.message), ["cannot find symbol"])
        XCTAssertEqual(found.first?.source, "gradle")
        let freshness = await service.diagnosticsWithFreshness(for: makeDocument())
        XCTAssertEqual(freshness.diagnostics.count, 1)
        XCTAssertTrue(freshness.staleSources.isEmpty)
    }

    func testEditedTextReportsRowsAsStale() async {
        let service = JavaBuildDiagnosticsService()
        await service.publish(texts: [url: text], diagnostics: [url: [makeDiagnostic()]], source: "gradle")

        let edited = text + "// touched\n"
        let freshness = await service.diagnosticsWithFreshness(for: makeDocument(text: edited))
        // The previous text's rows still come back (the editor keeps their shifted markers),
        // but flagged so the panel shows them as pending instead of current.
        XCTAssertEqual(freshness.diagnostics.count, 1)
        XCTAssertEqual(freshness.staleSources, ["gradle"])
    }

    func testCleanBuildClearsTheFile() async {
        let service = JavaBuildDiagnosticsService()
        await service.publish(texts: [url: text], diagnostics: [url: [makeDiagnostic()]], source: "gradle")
        await service.publish(texts: [url: text], diagnostics: [url: []], source: "gradle")

        let found = await service.diagnostics(for: makeDocument())
        XCTAssertTrue(found.isEmpty)
    }

    func testRepublishReplacesOnlyItsOwnSource() async {
        let service = JavaBuildDiagnosticsService()
        let mavenFile = URL(fileURLWithPath: "/proj/Bar.java")
        let newGradleFile = URL(fileURLWithPath: "/proj/Baz.java")
        await service.publish(texts: [url: text], diagnostics: [url: [makeDiagnostic(source: "gradle")]], source: "gradle")
        await service.publish(texts: [mavenFile: text], diagnostics: [mavenFile: [makeDiagnostic(source: "maven")]], source: "maven")
        // A new gradle run drops its old rows but leaves maven's alone.
        await service.publish(texts: [newGradleFile: text], diagnostics: [newGradleFile: [makeDiagnostic(source: "gradle")]], source: "gradle")

        let fooRows = await service.diagnostics(for: makeDocument())
        XCTAssertTrue(fooRows.isEmpty)
        let mavenRows = await service.diagnostics(for: makeDocument(url: mavenFile))
        XCTAssertEqual(mavenRows.map(\.source), ["maven"])
        let gradleRows = await service.diagnostics(for: makeDocument(url: newGradleFile))
        XCTAssertEqual(gradleRows.map(\.source), ["gradle"])
    }

    func testClearVariants() async {
        let service = JavaBuildDiagnosticsService()
        let other = URL(fileURLWithPath: "/proj/Bar.java")
        await service.publish(texts: [url: text, other: text], diagnostics: [url: [makeDiagnostic()], other: [makeDiagnostic()]], source: "gradle")

        await service.clear(url: url)
        let fooRows = await service.diagnostics(for: makeDocument())
        XCTAssertTrue(fooRows.isEmpty)
        let otherRows = await service.diagnostics(for: makeDocument(url: other))
        XCTAssertEqual(otherRows.count, 1)

        await service.clearAll()
        let clearedRows = await service.diagnostics(for: makeDocument(url: other))
        XCTAssertTrue(clearedRows.isEmpty)
    }

    func testClearSourceKeepsOtherSources() async {
        let service = JavaBuildDiagnosticsService()
        let other = URL(fileURLWithPath: "/proj/Bar.java")
        await service.publish(texts: [url: text], diagnostics: [url: [makeDiagnostic(source: "gradle")]], source: "gradle")
        await service.publish(texts: [other: text], diagnostics: [other: [makeDiagnostic(source: "maven")]], source: "maven")

        await service.clear(source: "gradle")
        let fooRows = await service.diagnostics(for: makeDocument())
        XCTAssertTrue(fooRows.isEmpty)
        let otherRows = await service.diagnostics(for: makeDocument(url: other))
        XCTAssertEqual(otherRows.count, 1)
    }

    func testIgnoresNonJavaDocumentsAndMissingURLs() async {
        let service = JavaBuildDiagnosticsService()
        await service.publish(texts: [url: text], diagnostics: [url: [makeDiagnostic()]], source: "gradle")

        let kotlinRows = await service.diagnostics(for: makeDocument(language: "kotlin"))
        XCTAssertTrue(kotlinRows.isEmpty)
        let noURLRows = await service.diagnostics(for: makeNoURLDocument())
        XCTAssertTrue(noURLRows.isEmpty)
    }

    func testMissingMappingTextIsAlwaysStale() async {
        let service = JavaBuildDiagnosticsService()
        await service.publish(texts: [:], diagnostics: [url: [makeDiagnostic()]], source: "gradle")

        let freshness = await service.diagnosticsWithFreshness(for: makeDocument())
        XCTAssertEqual(freshness.diagnostics.count, 1)
        XCTAssertEqual(freshness.staleSources, ["gradle"])
    }

    func testEngineDeduplicatesBuildRowsRestatedLive() async {
        let build = JavaBuildDiagnosticsService()
        let live = JavaBuildDiagnosticsService()
        await build.publish(texts: [url: text], diagnostics: [url: [makeDiagnostic(source: "gradle")]], source: "gradle")
        await live.publish(texts: [url: text], diagnostics: [url: [makeDiagnostic(source: "javac")]], source: "javac")

        // Same severity, message and range from two sources: one row, so the editor paints one
        // squiggle and Problems lists one row.
        let engine = DiagnosticEngine(providers: [build, live])
        let report = await engine.diagnostics(for: makeDocument())
        XCTAssertEqual(report.diagnostics.count, 1)
        XCTAssertTrue(report.staleSources.isEmpty)
    }

    func testEngineUnionsBuildRowsWithLiveOnes() async {
        let service = JavaBuildDiagnosticsService()
        await service.publish(texts: [url: text], diagnostics: [url: [makeDiagnostic()]], source: "gradle")

        let engine = DiagnosticEngine(providers: [service])
        let report = await engine.diagnostics(for: makeDocument())
        XCTAssertEqual(report.diagnostics.map(\.message), ["cannot find symbol"])
        XCTAssertTrue(report.staleSources.isEmpty)

        let editedReport = await engine.diagnostics(for: makeDocument(text: text + "// touched\n"))
        XCTAssertEqual(editedReport.diagnostics.count, 1)
        XCTAssertEqual(editedReport.staleSources, ["gradle"])
    }
}
