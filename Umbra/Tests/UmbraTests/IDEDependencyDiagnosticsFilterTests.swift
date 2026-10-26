import EditorIntelligence
import XCTest
@testable import Umbra

final class IDEDependencyDiagnosticsFilterTests: XCTestCase {
    private struct AlwaysWarns: DiagnosticProvider {
        let name = "always"
        func diagnostics(for document: Document) async -> [Diagnostic] {
            [Diagnostic(
                severity: .warning, message: "m", range: document.selection.range, source: "always", code: "c"
            )]
        }
    }

    private func document(_ path: String) -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            url: URL(fileURLWithPath: path), displayName: "T.java",
            contentSnapshot: TextSnapshot(version: 0, text: "class T {}"),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
    }

    func testDependencySourcesGetNoDiagnosticsFromAnyProvider() async {
        let filter = IDEDependencyDiagnosticsFilter(base: AlwaysWarns())
        let library = document("/cache/JavaIndex/attached-sources/decompiled/ab/T.java")
        let project = document("/proj/src/T.java")
        let libraryRows = await filter.diagnostics(for: library)
        let libraryReport = await filter.diagnosticsWithFreshness(for: library)
        let projectRows = await filter.diagnostics(for: project)
        XCTAssertTrue(libraryRows.isEmpty)
        XCTAssertTrue(libraryReport.diagnostics.isEmpty)
        XCTAssertEqual(projectRows.count, 1)
    }
}
