import Foundation
import JavaIntelligence

/// What the model is told after a Maven run: the verdict, compiler errors, failed tests and the
/// goal Maven says failed. Never the whole log; it stays in the Maven console. Same shape as
/// `IDEGradleSummary`, whose failed-test rendering it shares.
nonisolated enum IDEMavenSummary {
    struct Input {
        var commandLine: String
        var projectRoot: URL
        var exitCode: Int32?
        var stdout: String
        var stderr: String
        var duration: TimeInterval
        var timedOut = false
        var cancelled = false
        var tests: JavaTestRunResult?
    }

    static func make(_ input: Input) -> String {
        var lines: [String] = []
        let seconds = String(format: "%.1f", input.duration)
        if input.timedOut {
            lines.append("`\(input.commandLine)` timed out after \(seconds) s and was stopped.")
        } else if input.cancelled {
            lines.append("`\(input.commandLine)` was cancelled after \(seconds) s.")
        } else if let code = input.exitCode {
            lines.append("`\(input.commandLine)` \(code == 0 ? "succeeded" : "failed (exit code \(code))") in \(seconds) s.")
        }

        let combined = input.stderr + "\n" + input.stdout
        let compileErrors = compilerErrors(in: combined, root: input.projectRoot)
        if !compileErrors.isEmpty {
            lines.append("Compiler errors (\(compileErrors.count)):")
            lines += compileErrors.prefix(IDEGradleSummary.maxErrors).map { "  " + $0 }
            if compileErrors.count > IDEGradleSummary.maxErrors {
                lines.append("  [\(compileErrors.count - IDEGradleSummary.maxErrors) more not shown]")
            }
        }

        var foundFailedTests = false
        if let tests = input.tests, !tests.cases.isEmpty {
            lines.append("Tests: \(tests.cases.count) run, \(tests.failedCount) failed, \(tests.skippedCount) skipped.")
            let failed = tests.cases.filter { $0.status == .failed || $0.status == .aborted }
            foundFailedTests = !failed.isEmpty
            for test in failed.prefix(IDEGradleSummary.maxFailedTests) { lines += IDEGradleSummary.describe(test) }
            if failed.count > IDEGradleSummary.maxFailedTests {
                lines.append("  [\(failed.count - IDEGradleSummary.maxFailedTests) more failures not shown]")
            }
        }
        if combined.contains("Tests are skipped.") {
            lines.append("Maven skipped the tests (-DskipTests is set, in the Maven panel or the project).")
        }

        let failure = failedGoal(in: combined)
        if let failure, compileErrors.isEmpty, !foundFailedTests {
            lines.append("Maven reports: \(failure)")
        }
        if (input.exitCode ?? 1) != 0, compileErrors.isEmpty, !foundFailedTests, failure == nil {
            let tail = combined.split(separator: "\n", omittingEmptySubsequences: true).suffix(IDEGradleSummary.tailLines)
            if !tail.isEmpty { lines.append("Last lines of output:"); lines += tail.map { "  " + $0 } }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Pieces

    /// `[ERROR] /abs/File.java:[12,5] message`, once per place and message. Maven repeats the
    /// compiler's errors in its closing "COMPILATION ERROR" block.
    static func compilerErrors(in output: String, root: URL) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard line.hasPrefix("[ERROR]"), let match = filePattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let path = capture(line, match, 1), let number = capture(line, match, 2),
                  let message = capture(line, match, 4)
            else { continue }
            let location = "\(IDEGradleSummary.relative(path.trimmingCharacters(in: .whitespaces), to: root)):\(number)"
            guard seen.insert("\(location)|\(message)").inserted else { continue }
            result.append("\(location): \(message)")
        }
        return result
    }

    private static let filePattern = try! NSRegularExpression(pattern: #"^\[ERROR\]\s+(.+?):\[(\d+),(\d+)\]\s*(.*)$"#)

    private static func capture(_ line: String, _ match: NSTextCheckingResult, _ index: Int) -> String? {
        guard let range = Range(match.range(at: index), in: line) else { return nil }
        return String(line[range])
    }

    /// Maven's `[ERROR] Failed to execute goal …` line: the plugin goal that failed, and why.
    static func failedGoal(in output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.contains("Failed to execute goal") })
        else { return nil }
        let text = line.replacingOccurrences(of: "[ERROR]", with: "").trimmingCharacters(in: .whitespaces)
        return String(text.prefix(500))
    }

    /// Report directories Maven wrote during this run (`target/surefire-reports`,
    /// `target/failsafe-reports`), so a report from an earlier run is never read as this run's.
    static func freshTestReportDirectories(under root: URL, since started: Date) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var directories: [URL] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if ["node_modules", "src", ".git"].contains(name) { walker.skipDescendants(); continue }
            guard ["surefire-reports", "failsafe-reports"].contains(name),
                  url.deletingLastPathComponent().lastPathComponent == "target",
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { continue }
            let reports = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let fresh = reports.contains { file in
                file.pathExtension == "xml"
                    && ((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                        >= started.addingTimeInterval(-2)
            }
            if fresh { directories.append(url) }
            walker.skipDescendants()
        }
        return directories
    }
}
