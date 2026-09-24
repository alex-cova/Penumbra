import EditorIntelligence
import Foundation

/// One problem parsed from Gradle console output that is not a `javac` caret diagnostic.
public struct GradleProblem: Sendable, Equatable {
    public enum Severity: Sendable, Equatable {
        case error
        case warning
    }

    public let file: String?
    public let line: Int
    public let message: String
    public let severity: Severity
    public let taskPath: String?

    public init(file: String? = nil, line: Int = 0, message: String, severity: Severity = .error, taskPath: String? = nil) {
        self.file = file
        self.line = line
        self.message = message
        self.severity = severity
        self.taskPath = taskPath
    }
}

/// Parses Gradle task failures, build exceptions, and plain test failures from console output.
public enum GradleProblemMatcher {
    public static func parse(_ output: String, baseDirectory: URL, model: JavaGradleProjectModel? = nil) -> [GradleProblem] {
        let lines = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var problems: [GradleProblem] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let task = parseFailedTask(line) {
                problems.append(GradleProblem(message: "Task \(task) failed", taskPath: task))
                index += 1
                continue
            }
            if line.hasPrefix("Execution failed for task '"), let task = parseQuotedTask(line) {
                problems.append(GradleProblem(message: line, taskPath: task))
                index += 1
                continue
            }
            if line == "FAILURE: Build failed with an exception." {
                let block = collectFailureBlock(from: index, lines: lines)
                if let summary = block.summary {
                    problems.append(GradleProblem(message: summary, taskPath: block.taskPath))
                }
                index = block.endIndex
                continue
            }
            if let testFailure = parseTestFailure(line, model: model) {
                problems.append(testFailure)
            }
            index += 1
        }
        return dedupe(problems)
    }

    public static func diagnostics(
        from problems: [GradleProblem],
        baseDirectory: URL,
        sourceLookup: (URL) -> String? = { _ in nil }
    ) -> [URL: [Diagnostic]] {
        var byFile: [URL: [Diagnostic]] = [:]
        var fileless: [Diagnostic] = []
        for problem in problems {
            let severity: DiagnosticSeverity = problem.severity == .warning ? .warning : .error
            let message = problem.taskPath.map { "[\($0)] \(problem.message)" } ?? problem.message
            if let file = problem.file {
                let url = resolve(file, baseDirectory: baseDirectory)
                let range = TextRange(
                    start: TextPosition(line: max(0, problem.line - 1), column: 0, utf16Offset: 0),
                    end: TextPosition(line: max(0, problem.line - 1), column: 0, utf16Offset: 0)
                )
                let diagnostic = Diagnostic(
                    severity: severity,
                    message: message,
                    range: range,
                    source: "gradle"
                )
                byFile[url, default: []].append(diagnostic)
            } else {
                fileless.append(Diagnostic(
                    severity: severity,
                    message: message,
                    range: TextRange(
                        start: TextPosition(line: 0, column: 0, utf16Offset: 0),
                        end: TextPosition(line: 0, column: 0, utf16Offset: 0)
                    ),
                    source: "gradle"
                ))
            }
        }
        if !fileless.isEmpty {
            let key = baseDirectory.appendingPathComponent(".gradle-build")
            byFile[key] = fileless
        }
        return byFile
    }

    private static func parseFailedTask(_ line: String) -> String? {
        guard let match = line.firstMatch(of: /^> Task (:\S+) FAILED$/) else { return nil }
        return String(match.1)
    }

    private static func parseQuotedTask(_ line: String) -> String? {
        guard let start = line.firstIndex(of: "'"),
              let end = line[line.index(after: start)...].firstIndex(of: "'") else { return nil }
        return String(line[line.index(after: start)..<end])
    }

    private struct FailureBlock {
        let summary: String?
        let taskPath: String?
        let endIndex: Int
    }

    private static func collectFailureBlock(from start: Int, lines: [String]) -> FailureBlock {
        var summary: String?
        var taskPath: String?
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("* What went wrong:") {
                summary = line.replacingOccurrences(of: "* What went wrong:", with: "").trimmingCharacters(in: .whitespaces)
                if summary?.isEmpty == true, index + 1 < lines.count {
                    summary = lines[index + 1].trimmingCharacters(in: .whitespaces)
                }
            }
            if line.hasPrefix("Execution failed for task '"), let task = parseQuotedTask(line) {
                taskPath = task
            }
            if line.hasPrefix("* Try:") || line.hasPrefix("BUILD FAILED") {
                break
            }
            index += 1
        }
        return FailureBlock(summary: summary, taskPath: taskPath, endIndex: index + 1)
    }

    private static func parseTestFailure(_ line: String, model: JavaGradleProjectModel?) -> GradleProblem? {
        if let match = line.firstMatch(of: /^(\S+)\s+>\s+(.+?) FAILED$/) {
            let className = String(match.1)
            let method = String(match.2)
            return GradleProblem(
                message: "Test \(className).\(method) failed",
                taskPath: nil
            )
        }
        if line.contains("AssertionError") || line.contains("org.opentest4j.AssertionFailedError") {
            return GradleProblem(message: line.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func resolve(_ path: String, baseDirectory: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return baseDirectory.appendingPathComponent(path).standardizedFileURL
    }

    private static func dedupe(_ problems: [GradleProblem]) -> [GradleProblem] {
        var seen = Set<String>()
        return problems.filter { problem in
            let key = "\(problem.taskPath ?? "")|\(problem.file ?? "")|\(problem.message)"
            return seen.insert(key).inserted
        }
    }
}
