import EditorIntelligence
import Foundation

/// Recognises Maven compiler lines and Surefire's `Tests run:` summary. Compiler columns in the
/// log are 1-based; the mapped diagnostics use the same 0-based column as javac.
public enum MavenProblemMatcher {
    private static let filePattern = try! NSRegularExpression(
        pattern: #"^\[(ERROR|WARNING)\]\s+(.+?):\[(\d+),(\d+)\]\s*(.*)$"#
    )
    private static let testsPattern = try! NSRegularExpression(
        pattern: #"Tests run:\s*(\d+),\s*Failures:\s*(\d+),\s*Errors:\s*(\d+)"#
    )

    public static func match(
        _ result: GradleCommandResult,
        source: String = "maven",
        baseDirectory: URL? = nil,
        textFor: (URL) -> String? = { _ in nil }
    ) -> GradleProblemMatches {
        match(stdout: result.stdout, stderr: result.stderr, source: source, baseDirectory: baseDirectory, textFor: textFor)
    }

    public static func match(
        stdout: String,
        stderr: String,
        source: String = "maven",
        baseDirectory: URL? = nil,
        textFor: (URL) -> String? = { _ in nil }
    ) -> GradleProblemMatches {
        let text = stdout + "\n" + stderr
        var messages: [JavacMessage] = []
        var problems: [GradleProblem] = []
        var failedTests = 0
        var sawTestSummary = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if let message = fileMessage(line) {
                messages.append(message)
                continue
            }
            if let summary = testSummary(line) {
                sawTestSummary = true
                failedTests += summary.failures + summary.errors
                continue
            }
            if line.contains("Failed to execute goal") {
                let message = line.replacingOccurrences(of: "[ERROR]", with: "").trimmingCharacters(in: .whitespaces)
                problems.append(GradleProblem(message: message))
            }
        }
        if sawTestSummary, failedTests > 0 {
            problems.append(GradleProblem(
                message: failedTests == 1 ? "1 test failed" : "\(failedTests) tests failed",
                kind: .testFailures
            ))
        }
        let diagnostics = JavacDiagnosticsMapper.diagnostics(
            from: messages, source: source, baseDirectory: baseDirectory, textFor: textFor
        )
        return GradleProblemMatches(diagnostics: diagnostics, problems: problems)
    }

    private static func fileMessage(_ line: String) -> JavacMessage? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = filePattern.firstMatch(in: line, range: range) else { return nil }
        let severity: JavacMessage.Severity = capture(line, match, 1) == "WARNING" ? .warning : .error
        let file = capture(line, match, 2).trimmingCharacters(in: .whitespaces)
        let lineNumber = Int(capture(line, match, 3)) ?? 1
        let column = Int(capture(line, match, 4)) ?? 1
        return JavacMessage(
            file: file, line: lineNumber, column: max(0, column - 1), severity: severity,
            message: capture(line, match, 5)
        )
    }

    private static func testSummary(_ line: String) -> (failures: Int, errors: Int)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = testsPattern.firstMatch(in: line, range: range),
              let failures = Int(capture(line, match, 2)),
              let errors = Int(capture(line, match, 3))
        else { return nil }
        return (failures, errors)
    }

    private static func capture(_ line: String, _ match: NSTextCheckingResult, _ index: Int) -> String {
        Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
    }
}
