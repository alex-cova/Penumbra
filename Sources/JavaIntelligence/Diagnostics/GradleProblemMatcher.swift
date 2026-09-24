import EditorIntelligence
import Foundation

/// A build message that is not (only) a diagnostic in a source file: a failed task, a dependency
/// that could not be resolved, a build-script error, a test summary.
public struct GradleProblem: Sendable, Equatable, Identifiable {
    public enum Severity: Sendable, Equatable {
        case error
        case warning
        case info
    }

    public enum Kind: Sendable, Equatable {
        case general
        /// "N tests failed": hosts offer to show the test results.
        case testFailures
    }

    public let id: UUID
    public let message: String
    /// The Gradle task the message was attributed to (`:app:compileJava`), if known.
    public let task: String?
    public let severity: Severity
    public let kind: Kind
    /// The file the message points at (a build script), when Gradle said so.
    public let file: URL?
    /// 1-based line in `file`.
    public let line: Int?

    public init(
        id: UUID = UUID(),
        message: String,
        task: String? = nil,
        severity: Severity = .error,
        kind: Kind = .general,
        file: URL? = nil,
        line: Int? = nil
    ) {
        self.id = id
        self.message = message
        self.task = task
        self.severity = severity
        self.kind = kind
        self.file = file
        self.line = line
    }
}

/// Everything the matcher found in one Gradle run.
public struct GradleProblemMatches: Sendable {
    /// Diagnostics bound to a source file (javac and Kotlin), source `"gradle"` by default.
    public var diagnostics: [URL: [Diagnostic]]
    /// Messages without a place in a source file.
    public var problems: [GradleProblem]
}

/// Recognises problems in the text of a finished Gradle run: javac and Kotlin compiler lines,
/// build-script errors, `* What went wrong:` blocks, failed tasks, unresolved dependencies and the
/// test summary. stdout and stderr are separate buffers, so each is scanned on its own (a compiler
/// message and its caret line are never split by the other stream) and the results merged.
public enum GradleProblemMatcher {
    public static func match(
        _ result: GradleCommandResult,
        source: String = "gradle",
        baseDirectory: URL? = nil,
        textFor: (URL) -> String? = { _ in nil }
    ) -> GradleProblemMatches {
        match(stdout: result.stdout, stderr: result.stderr, source: source, baseDirectory: baseDirectory, textFor: textFor)
    }

    public static func match(
        stdout: String,
        stderr: String,
        source: String = "gradle",
        baseDirectory: URL? = nil,
        textFor: (URL) -> String? = { _ in nil }
    ) -> GradleProblemMatches {
        var scan = Scan()
        scan.run(over: stdout)
        scan.run(over: stderr)

        let messages = JavacOutputParser.parse(stderr) + JavacOutputParser.parse(stdout) + scan.kotlinMessages
        let diagnostics = JavacDiagnosticsMapper.diagnostics(
            from: messages, source: source, baseDirectory: baseDirectory, textFor: textFor
        )

        var problems = scan.problems
        if !scan.sawWhatWentWrong {
            for task in scan.failedTasks {
                problems.append(GradleProblem(message: "Task \(task) failed", task: task))
            }
        }
        if let summary = scan.testSummary {
            problems.append(GradleProblem(
                message: summary.failed == 1 ? "1 test failed" : "\(summary.failed) tests failed",
                task: summary.task, kind: .testFailures
            ))
        } else if scan.sawFailingTestsBlock {
            problems.append(GradleProblem(message: "There were failing tests", task: scan.failingTestsTask, kind: .testFailures))
        }
        return GradleProblemMatches(diagnostics: diagnostics, problems: problems)
    }

    /// `N tests completed, M failed` anywhere in the output.
    public static func testFailureSummary(in result: GradleCommandResult) -> (completed: Int, failed: Int)? {
        testFailureSummary(in: result.stdout + "\n" + result.stderr)
    }

    public static func testFailureSummary(in text: String) -> (completed: Int, failed: Int)? {
        for line in text.split(whereSeparator: \.isNewline) {
            if let parsed = parseTestSummary(String(line)) { return parsed }
        }
        return nil
    }

    // MARK: Scanning

    private static let taskHeader = try! NSRegularExpression(pattern: #"^> Task (:\S*)(?: (FAILED))?"#)
    private static let kotlinURL = try! NSRegularExpression(pattern: #"^([ew]): file://(.+?):(\d+):(\d+):? (.*)$"#)
    private static let kotlinOld = try! NSRegularExpression(pattern: #"^([ew]): (/.+?): \((\d+), (\d+)\): (.*)$"#)
    private static let kotlinPlain = try! NSRegularExpression(pattern: #"^([ew]): (.+)$"#)
    private static let buildFile = try! NSRegularExpression(pattern: #"^(?:Build|Settings|Initialization) file '(.+)' line: (\d+)"#)
    private static let scriptLine = try! NSRegularExpression(pattern: #"^\s+Line (\d+): (.*)$"#)
    private static let executionFailed = try! NSRegularExpression(pattern: #"Execution failed for task '(:[^']*)'"#)
    private static let testSummaryPattern = try! NSRegularExpression(pattern: #"(\d+) tests? completed, (\d+) failed"#)
    private static let blockEnd = ["* Try:", "* Exception is:", "* Get more help", "BUILD FAILED", "Deprecated Gradle features"]

    private static func parseTestSummary(_ line: String) -> (completed: Int, failed: Int)? {
        guard let match = testSummaryPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let completed = Int(capture(line, match, 1)), let failed = Int(capture(line, match, 2))
        else { return nil }
        return (completed, failed)
    }

    private static func capture(_ line: String, _ match: NSTextCheckingResult, _ index: Int) -> String {
        Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
    }

    private struct Scan {
        var currentTask: String?
        var failedTasks: [String] = []
        var problems: [GradleProblem] = []
        var kotlinMessages: [JavacMessage] = []
        var sawWhatWentWrong = false
        var sawFailingTestsBlock = false
        var failingTestsTask: String?
        var testSummary: (task: String?, completed: Int, failed: Int)?
        /// The location a `* Where:` block named, for the `* What went wrong:` block after it.
        var pendingWhere: (file: URL, line: Int)?

        mutating func run(over text: String) {
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var index = 0
            while index < lines.count {
                let line = lines[index]
                if line.hasPrefix("* What went wrong:") {
                    var end = index + 1
                    while end < lines.count, !GradleProblemMatcher.blockEnd.contains(where: { lines[end].hasPrefix($0) }) {
                        end += 1
                    }
                    whatWentWrong(Array(lines[(index + 1)..<end]))
                    index = end
                    continue
                }
                if line.hasPrefix("* Where:") {
                    if index + 1 < lines.count { pendingWhere = whereLocation(lines[index + 1]) }
                    index += 1
                    continue
                }
                lineMatch(line)
                index += 1
            }
        }

        private func whereLocation(_ line: String) -> (file: URL, line: Int)? {
            guard let match = GradleProblemMatcher.buildFile.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let number = Int(GradleProblemMatcher.capture(line, match, 2))
            else { return nil }
            return (URL(fileURLWithPath: GradleProblemMatcher.capture(line, match, 1)).standardizedFileURL, number)
        }

        private mutating func lineMatch(_ line: String) {
            let range = NSRange(line.startIndex..., in: line)
            if let match = GradleProblemMatcher.taskHeader.firstMatch(in: line, range: range) {
                let task = GradleProblemMatcher.capture(line, match, 1)
                currentTask = task
                if match.range(at: 2).location != NSNotFound, !failedTasks.contains(task) { failedTasks.append(task) }
                return
            }
            if let summary = GradleProblemMatcher.parseTestSummary(line) {
                if testSummary == nil { testSummary = (currentTask, summary.completed, summary.failed) }
                return
            }
            if let match = GradleProblemMatcher.kotlinURL.firstMatch(in: line, range: range) {
                let raw = GradleProblemMatcher.capture(line, match, 2)
                addKotlin(match, line, path: raw.removingPercentEncoding ?? raw)
                return
            }
            if let match = GradleProblemMatcher.kotlinOld.firstMatch(in: line, range: range) {
                addKotlin(match, line, path: GradleProblemMatcher.capture(line, match, 2))
                return
            }
            if let match = GradleProblemMatcher.kotlinPlain.firstMatch(in: line, range: range) {
                problems.append(GradleProblem(
                    message: GradleProblemMatcher.capture(line, match, 2), task: currentTask,
                    severity: GradleProblemMatcher.capture(line, match, 1) == "e" ? .error : .warning
                ))
                return
            }
            if line.hasPrefix("Could not resolve ") {
                problems.append(GradleProblem(message: line.trimmingCharacters(in: .whitespaces), task: currentTask))
            }
        }

        private mutating func addKotlin(_ match: NSTextCheckingResult, _ line: String, path: String) {
            let severity: JavacMessage.Severity = GradleProblemMatcher.capture(line, match, 1) == "e" ? .error : .warning
            let number = Int(GradleProblemMatcher.capture(line, match, 3)) ?? 1
            let column = Int(GradleProblemMatcher.capture(line, match, 4)) ?? 1
            kotlinMessages.append(JavacMessage(
                file: path, line: number, column: max(0, column - 1), severity: severity,
                message: GradleProblemMatcher.capture(line, match, 5)
            ))
        }

        private mutating func whatWentWrong(_ raw: [String]) {
            sawWhatWentWrong = true
            let location = pendingWhere
            pendingWhere = nil
            var lines = raw
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            guard let first = lines.first else { return }
            let text = lines.joined(separator: "\n")
            var task = currentTask
            if let match = GradleProblemMatcher.executionFailed.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                task = GradleProblemMatcher.capture(text, match, 1)
            }

            if text.contains("There were failing tests") {
                sawFailingTestsBlock = true
                failingTestsTask = task
                return
            }
            // The compiler's own messages are listed as diagnostics; the wrapper adds nothing.
            if text.contains("Compilation failed; see the compiler error output") || text.contains("Compilation error. See log for more details") {
                return
            }
            if first.hasPrefix("Script compilation error") {
                let entries = scriptErrors(lines)
                if !entries.isEmpty {
                    for entry in entries {
                        problems.append(GradleProblem(message: entry.message, task: task, file: location?.file, line: entry.line))
                    }
                    return
                }
            }
            var message = first.trimmingCharacters(in: .whitespaces)
            if let resolve = lines.first(where: {
                $0.contains("Could not resolve ") && !$0.contains("all files") && !$0.contains("all dependencies")
            }) {
                message = resolve.trimmingCharacters(in: CharacterSet(charactersIn: " >"))
            }
            problems.append(GradleProblem(message: message, task: task, file: location?.file, line: location?.line))
        }

        /// `  Line 3: foo bar` followed by a caret line whose text after `^` is the message.
        private func scriptErrors(_ lines: [String]) -> [(line: Int, message: String)] {
            var result: [(line: Int, message: String)] = []
            for (index, line) in lines.enumerated() {
                guard let match = GradleProblemMatcher.scriptLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let number = Int(GradleProblemMatcher.capture(line, match, 1))
                else { continue }
                var message = GradleProblemMatcher.capture(line, match, 2)
                if index + 1 < lines.count, let caret = lines[index + 1].firstIndex(of: "^") {
                    let tail = lines[index + 1][lines[index + 1].index(after: caret)...].trimmingCharacters(in: .whitespaces)
                    if !tail.isEmpty { message = tail }
                }
                result.append((number, message))
            }
            return result
        }
    }
}
