import Foundation
import JavaIntelligence
import SubprocessKit

/// One run of a configuration in the Run tool window: its console, its state, and the child process
/// behind it. A session is started by `IDEWorkspace` (see `IDEWorkspace+Run.swift`), which also
/// decides what rerunning it means.
@MainActor
@Observable
final class IDERunSession: Identifiable {
    enum State: Equatable {
        /// Waiting for the build, or for a before-launch step, that comes first.
        case preparing
        case running
        case exited(Int32)
        /// Killed by a signal that was not Stop's.
        case signaled(Int32)
        /// Ended by Stop.
        case stopped(Int32?)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .preparing, .running: return true
            default: return false
            }
        }
    }

    let id = UUID()
    let configurationID: UUID
    private(set) var configuration: JavaRunConfiguration
    private(set) var state: State = .preparing
    private(set) var log = IDERunConsoleLog()
    private(set) var startedAt = Date()
    private(set) var finishedAt: Date?
    /// The launch as a shell would write it, once there is one.
    private(set) var commandLine: String?
    /// Whether standard input is still open, so the console's input field has somewhere to send to.
    private(set) var acceptsInput = false

    /// Runs when the session ends, whatever the reason.
    @ObservationIgnored var onFinished: ((IDERunSession) -> Void)?

    @ObservationIgnored private var handle: SubprocessHandle?
    @ObservationIgnored private var launch: JavaProcessLaunch?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private let buffer = IDERunOutputBuffer()

    init(configuration: JavaRunConfiguration) {
        self.configuration = configuration
        configurationID = configuration.id
        buffer.onFlush = { [weak self] chunks in
            MainActor.assumeIsolated {
                for (text, stream) in chunks { self?.log.append(text, stream: stream) }
            }
        }
    }

    var title: String { configuration.displayName }
    var isActive: Bool { state.isActive }
    var isRunning: Bool { state == .running }

    /// "Process finished with exit code 0", or what else ended it.
    var statusText: String {
        switch state {
        case .preparing: return "Preparing…"
        case .running: return "Running"
        case .exited(let code): return "Exited with code \(code)"
        case .signaled(let signal): return "Killed by signal \(signal)"
        case .stopped: return "Stopped"
        case .failed(let message): return message
        }
    }

    func appendNote(_ text: String) {
        log.append(text.hasSuffix("\n") ? text : text + "\n", stream: .note)
    }

    func clearConsole() {
        log.clear()
    }

    /// Takes the settings a rerun was started with, so the title follows an edit.
    func update(configuration: JavaRunConfiguration) {
        self.configuration = configuration
    }

    /// Starts the JVM. `launch` was built by `JavaLaunchCommand.makeProcessLaunch`.
    func start(_ launch: JavaProcessLaunch) {
        guard state == .preparing else { return }
        self.launch = launch
        commandLine = launch.displayCommand
        var request = SubprocessRequest(executable: launch.executable.path, arguments: launch.arguments)
        request.workingDirectory = launch.workingDirectory
        request.environment = launch.environment
        request.standardInput = .interactive
        // The console shows output as it arrives; keeping a copy as well would double the memory.
        request.stdoutCapture = .discard
        request.stderrCapture = .discard
        // Its own group, so Stop also reaches what the program started; SIGTERM first so shutdown hooks run.
        request.processGroup = true
        request.terminationGrace = .seconds(2)

        let buffer = buffer
        let decoders = IDERunStreamDecoders()
        do {
            let handle = try SubprocessRunner.start(request) { data, source in
                let stream: IDERunConsoleLog.Stream = source == .stdout ? .stdout : .stderr
                let text = decoders.decode(data, source: source)
                if !text.isEmpty { buffer.append(text, stream: stream) }
            }
            self.handle = handle
            state = .running
            startedAt = Date()
            acceptsInput = true
            if let input = launch.redirectInput {
                if let data = try? Data(contentsOf: input) {
                    handle.write(data)
                    handle.closeInput()
                    acceptsInput = false
                } else {
                    appendNote("Could not read \(input.path); the program gets no input from it.")
                }
            }
            Task { [weak self] in
                let result = await handle.result
                self?.finish(result)
            }
        } catch {
            fail("Could not start java: \(error.localizedDescription)")
        }
    }

    /// The launch could not even be started (no JDK, a failed build).
    func fail(_ message: String) {
        guard state.isActive else { return }
        appendNote(message)
        state = .failed(message)
        end()
    }

    /// Sends a line to the program's standard input and echoes it in the console.
    func sendInput(_ line: String) {
        guard acceptsInput, let handle else { return }
        buffer.flushNow()
        log.append(line + "\n", stream: .input)
        handle.write(Data((line + "\n").utf8))
    }

    /// Closes standard input, as ⌃D does in a terminal.
    func closeInput() {
        guard acceptsInput, let handle else { return }
        handle.closeInput()
        acceptsInput = false
        appendNote("Input closed.")
    }

    /// Stops the program: SIGTERM, and SIGKILL after two seconds if it ignores that.
    func stop() {
        guard state.isActive else { return }
        stopRequested = true
        if let handle {
            handle.terminate()
        } else {
            // Still preparing: nothing to signal; the pipeline checks this before it spawns.
            appendNote("Stopped before it started.")
            state = .stopped(nil)
            end()
        }
    }

    /// True once Stop was pressed, for the pipeline that may still be building.
    var wasStopped: Bool { stopRequested }

    /// Returns when the session has ended (at once if it already has).
    func waitUntilFinished() async {
        while isActive { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private func finish(_ result: SubprocessResult) {
        buffer.flushNow()
        if stopRequested || result.cancelled {
            state = .stopped(result.exit.exitCode)
        } else if let signal = result.exit.signal {
            state = .signaled(signal)
        } else {
            state = .exited(result.exit.exitCode ?? -1)
        }
        let seconds = String(format: "%.1f", result.duration)
        switch state {
        case .stopped(let code):
            appendNote("\nProcess stopped" + (code.map { " (exit code \($0))" } ?? "") + " after \(seconds) s")
        case .signaled(let signal):
            appendNote("\nProcess killed by signal \(signal) after \(seconds) s")
        case .exited(let code):
            appendNote("\nProcess finished with exit code \(code) after \(seconds) s")
        default: break
        }
        end()
    }

    private func end() {
        acceptsInput = false
        finishedAt = Date()
        handle = nil
        for file in launch?.temporaryFiles ?? [] { try? FileManager.default.removeItem(at: file) }
        onFinished?(self)
        onFinished = nil
    }
}

/// Decodes each stream's bytes to text without splitting a multi-byte character across reads. Used
/// from SubprocessKit's private output queue only.
private final class IDERunStreamDecoders: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = UTF8ChunkDecoder()
    private var stderr = UTF8ChunkDecoder()

    func decode(_ data: Data, source: SubprocessOutputSource) -> String {
        lock.withLock {
            switch source {
            case .stdout: return stdout.feed(data)
            case .stderr: return stderr.feed(data)
            }
        }
    }
}

/// Collects output from the process's queue and hands it to the main actor a few times a second, so
/// a program that prints constantly does not post a main-thread update per write.
final class IDERunOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [(String, IDERunConsoleLog.Stream)] = []
    private var flushScheduled = false
    /// Called on the main thread.
    var onFlush: (([(String, IDERunConsoleLog.Stream)]) -> Void)?

    func append(_ text: String, stream: IDERunConsoleLog.Stream) {
        let schedule: Bool = lock.withLock {
            // A run of output on one stream is one chunk.
            if let last = chunks.last, last.1 == stream {
                chunks[chunks.count - 1].0 += text
            } else {
                chunks.append((text, stream))
            }
            guard !flushScheduled else { return false }
            flushScheduled = true
            return true
        }
        if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [self] in flushNow() }
        }
    }

    /// Delivers what is waiting. Main thread only.
    func flushNow() {
        let ready: [(String, IDERunConsoleLog.Stream)] = lock.withLock {
            flushScheduled = false
            defer { chunks = [] }
            return chunks
        }
        if !ready.isEmpty { onFlush?(ready) }
    }
}
