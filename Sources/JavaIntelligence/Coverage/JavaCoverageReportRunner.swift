import Foundation
import SubprocessKit

/// Why a coverage report could not be made.
public enum JavaCoverageReportError: Error, Equatable, LocalizedError, Sendable {
    /// The JVM that ran the code wrote no `.exec` (it was killed, or the agent never loaded).
    case noExecutionData
    /// None of the class directories exist: the program was never compiled.
    case noClassFiles
    /// `jacococli` ended with an error; `message` is its first meaningful line.
    case toolFailed(message: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noExecutionData:
            return "The run wrote no coverage data. It may have been stopped with SIGKILL or crashed before exiting."
        case .noClassFiles:
            return "There are no compiled classes to report on. Build the project first."
        case .toolFailed(let message):
            return "The coverage report failed: \(message)"
        case .cancelled:
            return "The coverage report was cancelled."
        }
    }
}

/// Runs the JaCoCo CLI over a run's `.exec` files and reads the report it writes.
public enum JavaCoverageReportRunner {
    /// - Parameters:
    ///   - java: the JDK's `bin/java` the CLI runs on (the project's, which reads its class files).
    ///   - executionFiles: candidates; missing and empty ones are dropped, because the CLI throws
    ///     on a missing file.
    ///   - classDirectories: main outputs of every module; ones that do not exist are dropped.
    ///   - xmlOutput: where the report goes (in the run's directory).
    ///   - sourceLookup: maps `pkg/Name.java` to the file in the project.
    public static func report(
        java: URL,
        toolchain: JavaCoverageToolchain,
        executionFiles: [URL],
        classDirectories: [URL],
        xmlOutput: URL,
        name: String? = nil,
        timeout: Duration = .seconds(300),
        sourceLookup: @Sendable (String) -> URL? = { _ in nil }
    ) async throws -> JavaCoverageReport {
        let fileManager = FileManager.default
        let usable = executionFiles.filter { url in
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            // A JaCoCo file of only its header (no session) is 8 bytes or so and holds nothing.
            return size > 16
        }
        guard !usable.isEmpty else { throw JavaCoverageReportError.noExecutionData }
        var isDirectory: ObjCBool = false
        let classes = classDirectories.filter {
            fileManager.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        guard !classes.isEmpty else { throw JavaCoverageReportError.noClassFiles }

        let call = JavaCoverageCommand.reportInvocation(
            java: java, cliJar: toolchain.cliJar, executionFiles: usable, classDirectories: classes,
            xmlOutput: xmlOutput, name: name
        )
        var request = SubprocessRequest(executable: call.executable.path, arguments: call.arguments)
        request.timeout = timeout
        request.stdoutCapture = .bounded(head: 4_000, tail: 4_000)
        request.stderrCapture = .bounded(head: 4_000, tail: 8_000)
        try? fileManager.removeItem(at: xmlOutput)

        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(request)
        } catch {
            throw JavaCoverageReportError.toolFailed(message: error.localizedDescription)
        }
        if result.cancelled { throw JavaCoverageReportError.cancelled }
        guard result.exit.succeeded, !result.timedOut else {
            throw JavaCoverageReportError.toolFailed(message: failureMessage(result))
        }
        do {
            return try JaCoCoXMLReportParser.parse(contentsOf: xmlOutput, sourceLookup: sourceLookup)
        } catch {
            throw JavaCoverageReportError.toolFailed(message: error.localizedDescription)
        }
    }

    /// The line of the CLI's error output worth showing: the exception's message, not the trace.
    static func failureMessage(_ result: SubprocessResult) -> String {
        if result.timedOut { return "it took too long." }
        let text = result.stderr.text + "\n" + result.stdout.text
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if let line = lines.first(where: { $0.contains("Unsupported class file major version") || $0.contains("IllegalClassFormatException") }) {
            return line + " (the coverage tool does not support this Java version yet)"
        }
        if let line = lines.first(where: { $0.hasPrefix("Exception in thread") || $0.contains("Exception:") || $0.hasPrefix("Error:") }) {
            return line
        }
        return lines.first(where: { !$0.isEmpty && !$0.hasPrefix("[INFO]") && !$0.hasPrefix("at ") }) ?? "exit \(result.exit.status)."
    }
}
