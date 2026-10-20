import EditorIntelligence
import JavaIntelligence
import XCTest
@testable import Umbra

final class IDEProblemsMarkdownTests: XCTestCase {
    private func row(_ path: String, _ severity: DiagnosticSeverity, _ message: String, line: Int, column: Int, source: String = "javac") -> ProblemRow {
        let position = TextPosition(line: line, column: column, utf16Offset: 0)
        return ProblemRow(
            url: URL(fileURLWithPath: path),
            diagnostic: Diagnostic(severity: severity, message: message, range: TextRange(start: position, end: position), source: source)
        )
    }

    private func files(_ url: URL, _ rows: [ProblemRow]) -> [ProblemFile] {
        DiagnosticGrouping.files(from: [[url: rows.map(\.diagnostic)]])
    }

    private func render(_ files: [ProblemFile], _ messages: [GradleProblem] = []) -> String {
        IDEProblemsMarkdown.render(files: files, messages: messages) { $0.path.replacingOccurrences(of: "/work/", with: "") }
    }

    func testEmptyListSaysSo() {
        XCTAssertEqual(render([]), "# Problems\n\nNo problems\n")
    }

    func testFileSectionUsesRelativePathAndOneBasedPositions() {
        let url = URL(fileURLWithPath: "/work/app/Bar.java")
        let output = render(files(url, [
            row(url.path, .error, "cannot find symbol", line: 11, column: 4),
            row(url.path, .warning, "unused", line: 39, column: 0),
        ]))
        XCTAssertTrue(output.contains("1 error, 1 warning"))
        XCTAssertTrue(output.contains("## app/Bar.java"))
        XCTAssertTrue(output.contains("- **Error** 12:5: cannot find symbol (javac)"))
        XCTAssertTrue(output.contains("- **Warning** 40:1: unused (javac)"))
    }

    func testBuildMessagesComeFirstAndMultilineMessagesCollapse() {
        let url = URL(fileURLWithPath: "/work/A.java")
        let message = GradleProblem(message: "Compilation failed", task: ":app:compileJava")
        let output = render(files(url, [row(url.path, .error, "first\n  second", line: 0, column: 0)]), [message])
        XCTAssertTrue(output.contains("- **Error** `:app:compileJava`: Compilation failed"))
        XCTAssertTrue(output.contains("first second"))
        let build = output.range(of: "## Build")
        let section = output.range(of: "## A.java")
        XCTAssertNotNil(build)
        XCTAssertLessThan(build!.lowerBound, section!.lowerBound)
        XCTAssertTrue(output.contains("2 errors, 0 warnings"))
    }
}
