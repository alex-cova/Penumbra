import Foundation
import SubprocessKit

/// The result of a completed Gradle invocation. A non-zero `exitCode` is returned, not thrown --
/// callers (project-model extraction, a future `build`/`test` command) decide for themselves
/// whether a failing exit is fatal or just informative.
public struct GradleCommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// One line of live output from a running Gradle process, as it arrives -- distinct from
/// ``GradleCommandResult``, which only exists once the process has finished. Consumers (Umbra's
/// Gradle console tab) render these incrementally instead of waiting for the whole invocation.
public struct GradleOutputLine: Sendable {
    public enum Stream: Sendable, Equatable {
        case stdout
        case stderr
    }

    public let stream: Stream
    public let text: String

    public init(stream: Stream, text: String) {
        self.stream = stream
        self.text = text
    }
}

public typealias GradleOutputHandler = @Sendable (GradleOutputLine) -> Void

public enum GradleCommandError: Error, Sendable {
    /// `projectDirectory` isn't in the trust store; nothing was run.
    case untrusted(URL)
    /// Neither a project-local `gradlew` nor a `gradle` on `PATH` could be found.
    case executableNotFound
    /// The process didn't finish within the requested timeout and was killed. Carries whatever
    /// output had been captured before the kill.
    case timedOut(partial: GradleCommandResult)
    /// The calling `Task` was cancelled while the process was running; it was killed. Carries
    /// whatever output had been captured before the kill.
    case cancelled(partial: GradleCommandResult)
}

/// A fully-built Gradle invocation, separated out from ``GradleCommandRunner/run`` so tests can
/// assert on command construction (executable resolution, argument ordering, environment) against
/// a fake ``GradleProcessLaunching`` without spawning a real process.
public struct GradleCommand: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let currentDirectory: URL
    public let environment: [String: String]

    public init(executable: URL, arguments: [String], currentDirectory: URL, environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.currentDirectory = currentDirectory
        self.environment = environment
    }
}

/// Abstraction over actually spawning the Gradle process, so ``GradleCommandRunner`` is testable
/// without a real (slow, possibly daemon-starting) Gradle invocation. The real implementation is
/// ``SystemGradleProcessLauncher``.
public protocol GradleProcessLaunching: Sendable {
    func launch(_ command: GradleCommand, timeout: Duration, output: GradleOutputHandler?) async throws -> GradleCommandResult
}

extension GradleProcessLaunching {
    /// Convenience for callers that only care about the final result.
    public func launch(_ command: GradleCommand, timeout: Duration) async throws -> GradleCommandResult {
        try await launch(command, timeout: timeout, output: nil)
    }
}

/// Resolves which executable actually runs Gradle for a project: prefer the project's own
/// `./gradlew` (respects the version the project is pinned to -- what a human typing `./gradlew` at
/// a terminal would get), falling back to `gradle` resolved through a login shell the same way
/// `JDKLocator` resolves `/usr/libexec/java_home` (GUI apps get a minimal `PATH`, so a bare
/// `Process` lookup for "gradle" would miss anything installed via sdkman/Homebrew/etc.).
public struct GradleExecutableResolver: Sendable {
    private var fileManager: FileManager { .default }
    private let processRunner: ProcessRunning

    public init(processRunner: ProcessRunning = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    /// `nil` if no Gradle executable could be found at all.
    public func resolve(projectDirectory: URL) -> (executable: URL, leadingArguments: [String])? {
        let wrapper = projectDirectory.appendingPathComponent("gradlew")
        if fileManager.fileExists(atPath: wrapper.path) {
            if fileManager.isExecutableFile(atPath: wrapper.path) {
                return (wrapper, [])
            }
            // Present but not marked executable (common right after a zip/tar checkout, or a git
            // checkout that dropped the exec bit) -- run it through the shell rather than failing.
            return (URL(fileURLWithPath: "/bin/sh"), [wrapper.path])
        }
        if let gradlePath = resolveGradleOnPath() {
            return (URL(fileURLWithPath: gradlePath), [])
        }
        return nil
    }

    private func resolveGradleOnPath() -> String? {
        guard let output = try? processRunner.run(executable: "/bin/zsh", arguments: ["-lc", "command -v gradle"]) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Runs an arbitrary Gradle invocation for a trusted project and captures its output reliably.
/// This is the one reusable execution primitive -- everything else (subproject/dependency model
/// extraction now, `build`/`test`/custom tasks later) is a call through it.
public actor GradleCommandRunner {
    private let trustStore: GradleTrustStore
    private let launcher: GradleProcessLaunching
    private let resolver: GradleExecutableResolver

    public init(
        trustStore: GradleTrustStore,
        launcher: GradleProcessLaunching = SystemGradleProcessLauncher(),
        resolver: GradleExecutableResolver = GradleExecutableResolver()
    ) {
        self.trustStore = trustStore
        self.launcher = launcher
        self.resolver = resolver
    }

    public func run(
        projectDirectory: URL,
        tasks: [String],
        arguments: [String] = [],
        javaHome: URL?,
        timeout: Duration = .seconds(120),
        output: GradleOutputHandler? = nil
    ) async throws -> GradleCommandResult {
        guard trustStore.isTrusted(projectDirectory) else {
            throw GradleCommandError.untrusted(projectDirectory)
        }
        guard let (executable, leadingArguments) = resolver.resolve(projectDirectory: projectDirectory) else {
            throw GradleCommandError.executableNotFound
        }

        var environment = ProcessInfo.processInfo.environment
        if let javaHome {
            environment["JAVA_HOME"] = javaHome.path
        }

        // Tasks before the arguments: task options (`--tests`, `--debug-jvm`, `--args`) apply to
        // the task named just before them, and Gradle rejects them ahead of every task name.
        let command = GradleCommand(
            executable: executable,
            arguments: leadingArguments + ["--console=plain"] + tasks + arguments,
            currentDirectory: projectDirectory,
            environment: environment
        )
        return try await launcher.launch(command, timeout: timeout, output: output)
    }
}

// MARK: - Real process launcher

/// Runs a ``GradleCommand`` through SubprocessKit with a genuine timeout (kills the process on
/// expiry) and `Task` cancellation support -- unlike `ProcessRunning`/`SystemProcessRunner`
/// (`Discovery/JDKLocator.swift`), which blocks synchronously with no way to bound or cancel a
/// hung invocation. Wrong for a sub-second `java_home -X`; exactly what's needed for a Gradle
/// invocation that can hang on a first-run dependency download with no network.
///
/// A timeout or cancellation signals the Gradle client only (SIGTERM, SIGKILL five seconds later),
/// not a process group: the client may have started a daemon that other builds share, and ending
/// it would make the next sync start cold.
public struct SystemGradleProcessLauncher: GradleProcessLaunching {
    public init() {}

    public func launch(_ command: GradleCommand, timeout: Duration, output: GradleOutputHandler?) async throws -> GradleCommandResult {
        // Stdin is closed (SubprocessKit's default). Without that, the child inherits Umbra's own
        // stdin. If that's a live terminal (e.g. `swift run Umbra` from a shell), Gradle's client
        // detects an interactive session and starts a background thread listening on stdin for
        // keypress-based build cancellation -- even under `--console=plain`. That thread blocks on
        // read() forever since nothing is ever typed into it, so the JVM never exits on its own even
        // though the build itself already finished (the process just sits there until something --
        // our own timeout -- kills it). Closed stdin means Gradle sees EOF immediately and never
        // starts that listener.
        var request = SubprocessRequest(executable: command.executable.path, arguments: command.arguments)
        request.workingDirectory = command.currentDirectory
        request.environment = command.environment
        request.timeout = timeout
        request.terminationGrace = .seconds(5)

        let splitter = GradleOutputLineSplitter(handler: output)
        let result: SubprocessResult
        do {
            // Gradle's output can easily exceed a pipe's kernel buffer; SubprocessKit drains both
            // pipes continuously, and hands each chunk to the line splitter as it arrives.
            result = try await SubprocessRunner.run(request) { data, source in
                splitter.append(data, stream: source == .stdout ? .stdout : .stderr)
            }
        } catch {
            throw GradleCommandError.executableNotFound
        }
        splitter.flush()

        let partial = GradleCommandResult(
            exitCode: result.exit.status,
            stdout: String(data: result.stdout.data, encoding: .utf8) ?? "",
            stderr: String(data: result.stderr.data, encoding: .utf8) ?? "")
        if result.timedOut { throw GradleCommandError.timedOut(partial: partial) }
        if result.cancelled { throw GradleCommandError.cancelled(partial: partial) }
        return partial
    }
}

/// Splits raw stdout/stderr bytes from a running process into complete lines and reports each one
/// through `handler` as it completes -- unlike `GradleCommandResult`, which only exists once the
/// process has finished. Byte-level (not `String`-level) buffering, so a UTF-8
/// character split across two pipe reads still decodes correctly once the rest arrives; a
/// trailing `\r` (CRLF from some Gradle/JVM output) is stripped. Each stream is buffered
/// independently so an interleaved stdout/stderr read doesn't corrupt either one's line boundaries.
final class GradleOutputLineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private let handler: GradleOutputHandler?

    init(handler: GradleOutputHandler?) {
        self.handler = handler
    }

    func append(_ data: Data, stream: GradleOutputLine.Stream) {
        guard let handler else { return }
        let lines: [String] = {
            lock.lock()
            defer { lock.unlock() }
            switch stream {
            case .stdout:
                stdoutBuffer.append(data)
                return Self.extractLines(from: &stdoutBuffer)
            case .stderr:
                stderrBuffer.append(data)
                return Self.extractLines(from: &stderrBuffer)
            }
        }()
        for line in lines {
            handler(GradleOutputLine(stream: stream, text: line))
        }
    }

    /// Emits whatever partial line remains in either buffer (a process that exits without a final
    /// newline still gets its last line reported). Call once, after the process has finished.
    func flush() {
        guard let handler else { return }
        let (stdoutRemainder, stderrRemainder): (String?, String?) = {
            lock.lock()
            defer { lock.unlock() }
            let out = Self.finalRemainder(from: &stdoutBuffer)
            let err = Self.finalRemainder(from: &stderrBuffer)
            return (out, err)
        }()
        if let stdoutRemainder { handler(GradleOutputLine(stream: .stdout, text: stdoutRemainder)) }
        if let stderrRemainder { handler(GradleOutputLine(stream: .stderr, text: stderrRemainder)) }
    }

    /// Pulls every complete (`\n`-terminated) line out of `buffer`, leaving any trailing partial
    /// line in place for the next call. Must be called with `lock` held.
    private static func extractLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<newlineIndex]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        return lines
    }

    /// Must be called with `lock` held.
    private static func finalRemainder(from buffer: inout Data) -> String? {
        guard !buffer.isEmpty else { return nil }
        var lineData = buffer[buffer.startIndex...]
        if lineData.last == 0x0D { lineData = lineData.dropLast() }
        buffer.removeAll()
        guard !lineData.isEmpty else { return nil }
        return String(decoding: lineData, as: UTF8.self)
    }
}
