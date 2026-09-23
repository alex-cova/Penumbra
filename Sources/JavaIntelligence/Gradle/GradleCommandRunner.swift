import Foundation

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

        let command = GradleCommand(
            executable: executable,
            arguments: leadingArguments + ["--console=plain"] + arguments + tasks,
            currentDirectory: projectDirectory,
            environment: environment
        )
        return try await launcher.launch(command, timeout: timeout, output: output)
    }
}

// MARK: - Real process launcher

/// Spawns a real `Process` for a ``GradleCommand`` with a genuine timeout (kills the process on
/// expiry) and `Task` cancellation support -- unlike `ProcessRunning`/`SystemProcessRunner`
/// (`Discovery/JDKLocator.swift`), which blocks synchronously with no way to bound or cancel a
/// hung invocation. Wrong for a sub-second `java_home -X`; exactly what's needed for a Gradle
/// invocation that can hang on a first-run dependency download with no network.
public struct SystemGradleProcessLauncher: GradleProcessLaunching {
    public init() {}

    public func launch(_ command: GradleCommand, timeout: Duration, output: GradleOutputHandler?) async throws -> GradleCommandResult {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectory
        process.environment = command.environment

        // Without this, the child inherits Umbra's own stdin. If that's a live terminal (e.g. `swift
        // run Umbra` from a shell), Gradle's client detects an interactive session and starts a
        // background thread listening on stdin for keypress-based build cancellation -- even under
        // `--console=plain`. That thread blocks on read() forever since nothing is ever typed into
        // it, so the JVM never exits on its own even though the build itself already finished (the
        // process just sits there until something -- our own timeout -- kills it). Closed stdin
        // means Gradle sees EOF immediately and never starts that listener.
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let buffer = OutputBuffer()
        let splitter = GradleOutputLineSplitter(handler: output)
        // Gradle's output can easily exceed a pipe's kernel buffer; reading only after the process
        // exits (as `SystemProcessRunner` does) would deadlock once the child blocks writing to a
        // full pipe. Drain continuously instead.
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                buffer.appendStdout(data)
                splitter.append(data, stream: .stdout)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                buffer.appendStderr(data)
                splitter.append(data, stream: .stderr)
            }
        }
        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            splitter.flush()
        }

        do {
            try process.run()
        } catch {
            throw GradleCommandError.executableNotFound
        }

        let exitCode = try await Self.waitWithTimeout(process: process, timeout: timeout, buffer: buffer)
        return buffer.result(exitCode: exitCode)
    }

    private static func waitWithTimeout(process: Process, timeout: Duration, buffer: OutputBuffer) async throws -> Int32 {
        let coordinator = TerminationCoordinator(buffer: buffer)
        process.terminationHandler = { proc in
            coordinator.terminated(status: proc.terminationStatus)
        }
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            coordinator.force(.timedOut, process: process)
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                coordinator.attach(continuation)
            }
        } onCancel: {
            coordinator.force(.cancelled, process: process)
        }
    }
}

/// Resolves the single race between "the process exited on its own", "the timeout fired", and "the
/// calling `Task` was cancelled" into exactly one continuation resume. `Process.terminationHandler`
/// and `Task`'s cancellation handler both run on arbitrary, possibly-concurrent contexts, so all
/// state here is protected by a lock rather than relying on actor isolation.
private final class TerminationCoordinator: @unchecked Sendable {
    enum ForcedOutcome {
        case timedOut
        case cancelled
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Error>?
    private var forcedOutcome: ForcedOutcome?
    private let buffer: OutputBuffer

    init(buffer: OutputBuffer) {
        self.buffer = buffer
    }

    /// Called once, right after the continuation is created. If a forced outcome already arrived
    /// (cancellation racing ahead of the continuation being attached), resolves immediately.
    func attach(_ continuation: CheckedContinuation<Int32, Error>) {
        lock.lock()
        if let outcome = forcedOutcome {
            lock.unlock()
            resume(continuation, with: outcome, status: nil)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// The process exited on its own (whether or not a forced outcome was also requested -- if
    /// `force` already consumed the continuation, this is a no-op).
    func terminated(status: Int32) {
        lock.lock()
        let outcome = forcedOutcome
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        lock.unlock()
        resume(continuation, with: outcome, status: status)
    }

    /// Timeout or cancellation: kill the process and resolve the continuation, unless the process
    /// already terminated on its own and consumed it first.
    func force(_ outcome: ForcedOutcome, process: Process) {
        lock.lock()
        if forcedOutcome == nil { forcedOutcome = outcome }
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        Self.terminateForcefully(process)
        guard let continuation else { return }
        resume(continuation, with: outcome, status: nil)
    }

    private func resume(_ continuation: CheckedContinuation<Int32, Error>, with outcome: ForcedOutcome?, status: Int32?) {
        switch outcome {
        case .timedOut:
            continuation.resume(throwing: GradleCommandError.timedOut(partial: buffer.result(exitCode: status ?? -1)))
        case .cancelled:
            continuation.resume(throwing: GradleCommandError.cancelled(partial: buffer.result(exitCode: status ?? -1)))
        case nil:
            continuation.resume(returning: status ?? -1)
        }
    }

    private static func terminateForcefully(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }
}

/// Splits raw stdout/stderr bytes from a running process into complete lines and reports each one
/// through `handler` as it completes -- unlike `OutputBuffer`, which only exposes the accumulated
/// text once the process has finished. Byte-level (not `String`-level) buffering, so a UTF-8
/// character split across two `Pipe` reads still decodes correctly once the rest arrives; a
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

/// Thread-safe accumulator for a running process's stdout/stderr, fed by `Pipe` readability
/// handlers that fire on an arbitrary dispatch queue.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()

    func appendStdout(_ data: Data) {
        lock.lock()
        stdoutData.append(data)
        lock.unlock()
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        stderrData.append(data)
        lock.unlock()
    }

    func result(exitCode: Int32) -> GradleCommandResult {
        lock.lock()
        let out = String(data: stdoutData, encoding: .utf8) ?? ""
        let err = String(data: stderrData, encoding: .utf8) ?? ""
        lock.unlock()
        return GradleCommandResult(exitCode: exitCode, stdout: out, stderr: err)
    }
}
