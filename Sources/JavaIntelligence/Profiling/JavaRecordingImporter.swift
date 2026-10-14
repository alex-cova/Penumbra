import Foundation
import SubprocessKit

/// Why a recording could not be read.
public enum JavaRecordingImportError: Error, Equatable, LocalizedError, Sendable {
    /// No JDK with a `jfr` tool is known.
    case noJFRTool
    /// `jfr` printed an error, which is shown as it came (a corrupt or truncated file).
    case toolFailed(message: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noJFRTool:
            return "Reading a recording needs the `jfr` tool of a JDK (Java 11 or newer). No installed JDK has one."
        case .toolFailed(let message):
            return message
        case .cancelled:
            return "Reading the recording was cancelled."
        }
    }
}

/// Reads recordings with the JDK's own `jfr print`, as a stream.
public enum JavaRecordingImporter {
    /// What a first, cheap `jfr summary` says: how big the import will be.
    public static func summary(jfr: URL, recording: URL, timeout: Duration = .seconds(60)) async throws -> JFRSummary {
        var request = SubprocessRequest(
            executable: jfr.path, arguments: JavaFlightRecorder.summaryInvocation(jfr: jfr, recording: recording).arguments
        )
        request.timeout = timeout
        let result = try await run(request)
        guard result.exit.succeeded else { throw JavaRecordingImportError.toolFailed(message: firstError(result)) }
        return JFRSummary.parse(result.stdout.text)
    }

    /// Reads the stacks of `recordings` (a Gradle run can write one per JVM) into one profile.
    ///
    /// `progress` gets the number of lines read so far, at most every 20 000 lines, from a
    /// background queue. Cancelling the calling task stops the child process.
    public static func importProfile(
        jfr: URL,
        recordings: [URL],
        events: [String] = JavaFlightRecorder.EventType.profiled,
        stackDepth: Int = 128,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> JavaProfile {
        let state = ImportState(wanted: Set(events))
        for recording in recordings {
            try Task.checkCancellation()
            let call = JavaFlightRecorder.printInvocation(jfr: jfr, recording: recording, events: events, stackDepth: stackDepth)
            var request = SubprocessRequest(executable: call.executable.path, arguments: call.arguments)
            request.stdoutCapture = .discard
            request.stderrCapture = .bounded(head: 2_000, tail: 2_000)
            let result = try await run(request) { data in
                state.feed(data, progress: progress)
            }
            state.finishRecording()
            guard result.exit.succeeded else { throw JavaRecordingImportError.toolFailed(message: firstError(result)) }
        }
        return state.profile
    }

    private static func run(_ request: SubprocessRequest, onChunk: (@Sendable (Data) -> Void)? = nil) async throws -> SubprocessResult {
        do {
            let result = try await SubprocessRunner.run(request, onOutput: onChunk.map { handler in
                { @Sendable data, source in if source == .stdout { handler(data) } }
            })
            if result.cancelled { throw JavaRecordingImportError.cancelled }
            if result.timedOut { throw JavaRecordingImportError.toolFailed(message: "Reading the recording took too long.") }
            return result
        } catch let error as JavaRecordingImportError {
            throw error
        } catch is CancellationError {
            throw JavaRecordingImportError.cancelled
        } catch {
            throw JavaRecordingImportError.toolFailed(message: error.localizedDescription)
        }
    }

    private static func firstError(_ result: SubprocessResult) -> String {
        let text = result.stderr.text + "\n" + result.stdout.text
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "jfr exited with status \(result.exit.status)."
    }

    /// The parser and the profile behind one lock: output arrives on the runner's queue.
    private final class ImportState: @unchecked Sendable {
        private let lock = NSLock()
        private var parser: JFRTextParser
        private var profile_: JavaProfile
        private var lastReported = 0

        init(wanted: Set<String>) {
            let symbols = JavaProfileSymbols()
            parser = JFRTextParser(symbols: symbols, wantedEvents: wanted)
            profile_ = JavaProfile(symbols: symbols)
        }

        var profile: JavaProfile { lock.withLock { profile_ } }

        func feed(_ data: Data, progress: (@Sendable (Int) -> Void)?) {
            let lines: Int? = lock.withLock {
                parser.feed(data) { [self] event in profile_.ingest(event) }
                guard parser.linesRead - lastReported >= 20_000 else { return nil }
                lastReported = parser.linesRead
                return parser.linesRead
            }
            if let lines { progress?(lines) }
        }

        func finishRecording() {
            lock.withLock {
                parser.finish { [self] event in profile_.ingest(event) }
            }
        }
    }
}
