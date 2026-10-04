import Foundation
import JavaIntelligence

/// What the model is told after a Gradle run: the verdict, compiler errors, failed tests with the
/// start of each failure, and, only when nothing structured was found, the end of the log. Never
/// the whole log: it is noisy and the full output stays in the Gradle console.
nonisolated enum IDEGradleSummary {
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

    static let maxErrors = 15
    static let maxFailedTests = 10
    static let tailLines = 40

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
            lines += compileErrors.prefix(maxErrors).map { "  " + $0 }
            if compileErrors.count > maxErrors { lines.append("  [\(compileErrors.count - maxErrors) more not shown]") }
        }

        var foundFailedTests = false
        if let tests = input.tests, !tests.cases.isEmpty {
            lines.append("Tests: \(tests.cases.count) run, \(tests.failedCount) failed, \(tests.skippedCount) skipped.")
            let failed = tests.cases.filter { $0.status == .failed || $0.status == .aborted }
            foundFailedTests = !failed.isEmpty
            for test in failed.prefix(maxFailedTests) { lines += describe(test) }
            if failed.count > maxFailedTests { lines.append("  [\(failed.count - maxFailedTests) more failures not shown]") }
        } else if let tests = input.tests, tests.failedCount > 0 {
            lines.append("Tests: \(tests.passedCount + tests.failedCount) run, \(tests.failedCount) failed (no per-test detail was available).")
            foundFailedTests = true
        }

        let failure = whatWentWrong(in: combined)
        if let failure, compileErrors.isEmpty, !foundFailedTests {
            lines.append("Gradle reports: \(failure)")
        }

        let failed = (input.exitCode ?? 1) != 0
        if failed, compileErrors.isEmpty, !foundFailedTests, failure == nil {
            let tail = combined.split(separator: "\n", omittingEmptySubsequences: true).suffix(tailLines)
            if !tail.isEmpty { lines.append("Last lines of output:"); lines += tail.map { "  " + $0 } }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Pieces

    static func compilerErrors(in output: String, root: URL) -> [String] {
        // Gradle prints a compile error twice: raw, and indented under "What went wrong". The
        // parser keeps both, the second with leading spaces in its path, so key on location and
        // the first line of the message and keep the first.
        var seen = Set<String>()
        var result: [String] = []
        for message in JavacOutputParser.parse(output) where message.severity == .error {
            let file = message.file?.trimmingCharacters(in: .whitespaces)
            let location = file.map { "\(relative($0, to: root)):\(message.line)" } ?? "javac"
            let parts = message.message.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = parts.first, seen.insert("\(location)|\(first)").inserted else { continue }
            result.append("\(location): \(parts.joined(separator: " | "))")
        }
        return result
    }

    private static func describe(_ test: JavaTestCaseResult) -> [String] {
        var lines = ["  FAILED \(test.className) > \(test.name)"]
        if let message = test.message?.split(separator: "\n").first.map(String.init), !message.isEmpty {
            lines.append("    " + String(message.prefix(300)))
        }
        // The first frames that are in the project's code say where it happened.
        if let trace = test.stackTrace {
            let frames = trace.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { frame in
                    guard frame.hasPrefix("at ") else { return false }
                    // Test runners, build tools and the JDK are not where the bug is.
                    let noise = ["org.junit.", "junit.framework.", "org.gradle.", "worker.org.gradle.", "java.base/", "jdk.internal.", "jdk.proxy", "sun.reflect."]
                    return !noise.contains { frame.contains($0) }
                }
            lines += frames.prefix(3).map { "    " + $0 }
        }
        return lines
    }

    /// The text of Gradle's "What went wrong" block, which names a failed task or a configuration
    /// problem when the build failed for a reason other than a compile error or a test.
    static func whatWentWrong(in output: String) -> String? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("* What went wrong:") }) else { return nil }
        var block: [String] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("* Try:") || line.hasPrefix("* Get more help") { break }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { block.append(line.trimmingCharacters(in: .whitespaces)) }
        }
        let joined = block.prefix(6).joined(separator: " ")
        return joined.isEmpty ? nil : String(joined.prefix(500))
    }

    private static func relative(_ path: String, to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
        for prefix in [rootPath, URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().path, "/private" + rootPath] {
            if resolved.hasPrefix(prefix + "/") { return String(resolved.dropFirst(prefix.count + 1)) }
        }
        return path
    }

    // MARK: - Test reports

    /// Result directories Gradle wrote during this run (`build/test-results/<task>`), so a report
    /// left by an earlier run, or by a module the run didn't touch, is never read as this run's.
    static func freshTestReportDirectories(under root: URL, since started: Date) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var directories: [URL] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if ["node_modules", "src", ".gradle"].contains(name) { walker.skipDescendants(); continue }
            guard url.deletingLastPathComponent().lastPathComponent == "test-results",
                  url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "build",
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { continue }
            let reports = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let fresh = reports.contains { file in
                file.pathExtension == "xml"
                    && ((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                        >= started.addingTimeInterval(-2)
            }
            if fresh { directories.append(url) }
        }
        return directories
    }
}
