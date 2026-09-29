import Foundation
import JavaIntelligence

struct JavaDebugStackFrame: Identifiable, Equatable, Sendable {
    let index: Int
    let name: String
    let className: String
    let filePath: String
    let line: Int
    var id: Int { index }
}

struct JavaDebugVariable: Identifiable, Equatable, Sendable {
    let name: String
    let type: String
    let value: String
    var id: String { name }
}

/// One node of an evaluated value: a result, or a field or array element of one. Children arrive
/// one level at a time; ``hasChildren`` says whether evaluating ``expression`` again would list some.
struct JavaDebugValue: Identifiable, Equatable, Sendable {
    let name: String?
    let type: String
    let value: String
    /// Reaches this value again from the frame, so opening a node is another evaluation.
    let expression: String
    let hasChildren: Bool
    let children: [JavaDebugValue]?

    var id: String { "\(name ?? "")|\(expression)" }

    init(name: String? = nil, type: String, value: String, expression: String, hasChildren: Bool = false, children: [JavaDebugValue]? = nil) {
        self.name = name
        self.type = type
        self.value = value
        self.expression = expression
        self.hasChildren = hasChildren
        self.children = children
    }

    init?(json: [String: Any]) {
        guard let type = json["type"] as? String, let value = json["value"] as? String else { return nil }
        self.init(
            name: json["name"] as? String,
            type: type,
            value: value,
            expression: json["expression"] as? String ?? "",
            hasChildren: json["hasChildren"] as? Bool ?? false,
            children: (json["children"] as? [[String: Any]])?.compactMap(JavaDebugValue.init(json:))
        )
    }
}

/// An expression the user evaluated, with what came back.
struct JavaDebugEvaluation: Identifiable, Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case value(JavaDebugValue)
        case failure(String)
    }

    let id = UUID()
    let expression: String
    let outcome: Outcome
}

enum JavaDebugSessionState: Equatable, Sendable {
    case idle
    case launching
    case running
    case stopped(file: URL, line: Int, reason: String)
    case terminated
    case failed(String)
}

/// Talks to the JDI adapter over stdin/stdout JSON lines.
@MainActor
@Observable
final class JavaDebugSession {
    private(set) var state: JavaDebugSessionState = .idle
    private(set) var stackFrames: [JavaDebugStackFrame] = []
    private(set) var variables: [JavaDebugVariable] = []
    private(set) var selectedFrameIndex = 0
    /// Expressions evaluated in this session, newest first.
    private(set) var evaluations: [JavaDebugEvaluation] = []
    /// The Evaluate field's text. Quick Evaluate and ⌥F8 fill it from the editor.
    var evaluationDraft = ""
    /// Bumped to ask the panel to focus its Evaluate field.
    private(set) var evaluationFocusRequest = 0
    static let maximumEvaluations = 30
    /// The program's stdout and stderr and the session's own notes. Cleared when a session starts,
    /// not when it stops, so the last run's output stays readable.
    let console = IDEDebugConsoleLog()

    private var process: Process?
    private var inputHandle: FileHandle?
    private var readTask: Task<Void, Never>?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private let launcher = JavaDebugProcessLauncher()
    private(set) var isGradleAttachSession = false
    /// Called when the program stops at a source file the adapter could locate on disk, so the
    /// host can show the line. Not called for a stop in code with no source file.
    var onStopped: ((_ file: URL, _ line: Int) -> Void)?

    var isActive: Bool {
        switch state {
        case .idle, .terminated, .failed(_): return false
        default: return true
        }
    }

    /// - Parameter sourceRoots: directories holding the program's sources, so the adapter can turn a
    ///   class's `com/acme/Foo.java` into a file when it stops in code that has no breakpoint.
    func start(launch: JavaManagedLaunch, breakpoints: [JavaBreakpoint], sourceRoots: [URL] = []) async {
        stop()
        console.reset()
        console.appendNote("Launching \(launch.mainClass)…")
        state = .launching
        do {
            let javaHome = launch.javaExecutable.deletingLastPathComponent().deletingLastPathComponent()
            let process = try launcher.startAdapter(javaHome: javaHome)
            self.process = process
            inputHandle = (process.standardInput as? Pipe)?.fileHandleForWriting
            startReading(process)
            let classpath = launch.classpath.map(\.path).joined(separator: ":")
            var request: [String: Any] = [
                "command": "launch",
                "java": launch.javaExecutable.path,
                "classpath": classpath,
                "mainClass": launch.mainClass,
                "programArgs": launch.programArguments.joined(separator: " "),
                "vmArgs": launch.vmArguments.filter { !$0.contains("jdwp") }.joined(separator: " "),
                "port": launch.jdwpPort,
                "suspend": launch.suspendOnStart,
                "sourceRoots": sourceRoots.map(\.path)
            ]
            if !launch.environment.isEmpty {
                request["environment"] = launch.environment
            }
            _ = try await send(request)
            for breakpoint in breakpoints where breakpoint.isEnabled {
                _ = try await send([
                    "command": "setBreakpoint",
                    "file": breakpoint.filePath,
                    "line": breakpoint.line
                ])
            }
            state = .running
            // A JVM started to wait for its debugger holds at the first instruction; breakpoints
            // are in, so let it go.
            if launch.suspendOnStart {
                _ = try await send(["command": "resume"])
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Starts the JDI adapter for a Gradle `--debug-jvm` attach session.
    func prepareAdapter(javaHome: URL) async throws {
        stop()
        console.reset()
        console.appendNote("The program's output is in the Gradle tab.")
        isGradleAttachSession = true
        state = .launching
        let process = try launcher.startAdapter(javaHome: javaHome)
        self.process = process
        inputHandle = (process.standardInput as? Pipe)?.fileHandleForWriting
        startReading(process)
    }

    /// Attaches to the Gradle-spawned JVM, applies breakpoints, and optionally resumes.
    func attachForGradle(
        port: Int = JavaLaunchCommand.gradleDebugJdwpPort,
        suspendOnStart: Bool,
        breakpoints: [JavaBreakpoint],
        sourceRoots: [URL] = []
    ) async {
        do {
            try await attachWithRetry(port: port, maxAttempts: 60, sourceRoots: sourceRoots)
            for breakpoint in breakpoints where breakpoint.isEnabled {
                _ = try await send([
                    "command": "setBreakpoint",
                    "file": breakpoint.filePath,
                    "line": breakpoint.line
                ])
            }
            if !suspendOnStart {
                resume()
            }
            state = .running
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func resume() {
        run("resume")
    }

    func stepOver() {
        run("stepOver")
    }

    func stepInto() {
        run("stepInto")
    }

    func stepOut() {
        run("stepOut")
    }

    /// Suspends a running program where it is; the adapter answers with a `stopped` event.
    func pause() {
        guard case .running = state else { return }
        Task { _ = try? await send(["command": "pause"]) }
    }

    /// Lets the program run again for `command`. Only from a stop: a stale double press would
    /// otherwise send a step to a program that is already moving.
    private func run(_ command: String) {
        guard case .stopped = state else { return }
        state = .running
        stackFrames = []
        variables = []
        Task { _ = try? await send(["command": command]) }
    }

    func refreshStack() {
        Task {
            guard let response = try? await send(["command": "stackFrames"]),
                  let frames = response["frames"] as? [[String: Any]] else { return }
            stackFrames = frames.compactMap { frame in
                guard let index = frame["index"] as? Int,
                      let name = frame["name"] as? String,
                      let className = frame["className"] as? String,
                      let file = frame["file"] as? String,
                      let line = frame["line"] as? Int else { return nil }
                return JavaDebugStackFrame(index: index, name: name, className: className, filePath: file, line: line)
            }
            await refreshVariables()
        }
    }

    func selectFrame(_ index: Int) {
        selectedFrameIndex = index
        Task { await refreshVariables() }
    }

    func refreshVariables() async {
        guard let response = try? await send(["command": "localVariables", "frameIndex": selectedFrameIndex]),
              let variables = response["variables"] as? [[String: Any]] else { return }
        self.variables = variables.compactMap { entry in
            guard let name = entry["name"] as? String,
                  let type = entry["type"] as? String,
                  let value = entry["value"] as? String else { return nil }
            return JavaDebugVariable(name: name, type: type, value: value)
        }
    }

    /// Evaluates `expression` in the selected stack frame. Works only while the program is paused;
    /// otherwise the outcome is a failure that says so. Recorded in ``evaluations`` when `record`.
    @discardableResult
    func evaluate(_ expression: String, record: Bool = true) async -> JavaDebugEvaluation.Outcome {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome: JavaDebugEvaluation.Outcome
        if case .stopped = state {
            do {
                let response = try await send(["command": "evaluate", "expression": trimmed, "frameIndex": selectedFrameIndex])
                if let node = (response["result"] as? [String: Any]).flatMap(JavaDebugValue.init(json:)) {
                    outcome = .value(node)
                } else {
                    outcome = .failure("The debugger sent no result.")
                }
            } catch {
                outcome = .failure(Self.message(for: error))
            }
        } else {
            outcome = .failure("The program is not paused.")
        }
        if record {
            evaluations.insert(JavaDebugEvaluation(expression: trimmed, outcome: outcome), at: 0)
            if evaluations.count > Self.maximumEvaluations { evaluations.removeLast(evaluations.count - Self.maximumEvaluations) }
        }
        return outcome
    }

    func clearEvaluations() {
        evaluations = []
    }

    /// Fills the Evaluate field and asks the panel to focus it.
    func requestEvaluationInput(prefilledWith text: String?) {
        if let text, !text.isEmpty { evaluationDraft = text }
        evaluationFocusRequest += 1
    }

    private static func message(for error: Error) -> String {
        switch error as? JavaDebugProcessError {
        case .launchFailed(let message): return message
        case .disconnected: return "The debugger is no longer connected."
        case .adapterNotFound: return "The debug adapter was not found."
        case nil: return error.localizedDescription
        }
    }

    func stop() {
        if process != nil, isActive { console.appendNote("Debug session stopped.") }
        readTask?.cancel()
        readTask = nil
        if let process {
            _ = try? sendSync(["command": "disconnect"])
            if process.isRunning { process.terminate() }
        }
        process = nil
        inputHandle = nil
        pending.values.forEach { $0.resume(throwing: JavaDebugProcessError.disconnected) }
        pending.removeAll()
        stackFrames = []
        variables = []
        selectedFrameIndex = 0
        evaluations = []
        isGradleAttachSession = false
        if case .failed = state { return }
        state = .terminated
    }

    private func attachWithRetry(port: Int, maxAttempts: Int, sourceRoots: [URL]) async throws {
        var lastError: Error = JavaDebugProcessError.launchFailed("could not attach")
        for _ in 0..<maxAttempts {
            do {
                _ = try await send(["command": "attach", "port": port, "sourceRoots": sourceRoots.map(\.path)])
                return
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw lastError
    }

    /// Reads the adapter's stdout line by line. The reads block, so they run off the main actor:
    /// on it, the first quiet moment would freeze the app and starve every reply the session
    /// is waiting for.
    private func startReading(_ process: Process) {
        guard let output = process.standardOutput as? Pipe else { return }
        let handle = output.fileHandleForReading
        let processID = ObjectIdentifier(process)
        readTask = Task.detached(priority: .userInitiated) { [weak self] in
            var buffer = Data()
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                var lines: [String] = []
                while let newline = buffer.firstIndex(of: 0x0A) {
                    lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                    buffer = Data(buffer[buffer.index(after: newline)...])
                }
                if !lines.isEmpty {
                    await self?.handle(lines: lines)
                }
            }
            await self?.adapterOutputEnded(processID: processID)
        }
    }

    private func handle(lines: [String]) {
        for line in lines {
            handleEventLine(line)
        }
    }

    /// The adapter closed its output: the program is over, unless this is an older session's
    /// adapter finishing after a new one started.
    private func adapterOutputEnded(processID: ObjectIdentifier) {
        guard let process, ObjectIdentifier(process) == processID, !process.isRunning else { return }
        if case .failed = state { return }
        state = .terminated
    }

    private func handleEventLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let event = json["event"] as? String {
            switch event {
            case "stopped":
                let filePath = json["file"] as? String ?? ""
                let line = json["line"] as? Int ?? 0
                let reason = json["reason"] as? String ?? "breakpoint"
                let file = URL(fileURLWithPath: filePath)
                state = .stopped(file: file, line: line, reason: reason)
                // A new stop starts at the innermost frame, whichever one was selected before.
                selectedFrameIndex = 0
                refreshStack()
                // A relative path means no source root held the file; there is nothing to open.
                if filePath.hasPrefix("/") {
                    onStopped?(file, line)
                }
            case "output":
                for entry in json["lines"] as? [[String: Any]] ?? [] {
                    console.append(
                        stream: entry["stream"] as? String == "err" ? .err : .out,
                        text: entry["text"] as? String ?? "",
                        partial: entry["partial"] as? Bool ?? false
                    )
                }
            case "terminated":
                if case .terminated = state {} else if let code = json["exitCode"] as? Int {
                    console.appendNote("Process finished with exit code \(code)")
                } else if isActive {
                    console.appendNote("The debugger disconnected.")
                }
                state = .terminated
            default:
                break
            }
            return
        }
        if let id = json["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if json["ok"] as? Bool == true {
                continuation.resume(returning: json)
            } else {
                continuation.resume(throwing: JavaDebugProcessError.launchFailed(json["error"] as? String ?? "unknown error"))
            }
        }
    }

    private func send(_ body: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            do {
                _ = try sendSync(body, continuation: continuation)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendSync(_ body: [String: Any], continuation: CheckedContinuation<[String: Any], Error>? = nil) throws -> [String: Any]? {
        guard let inputHandle else { throw JavaDebugProcessError.disconnected }
        var payload = body
        let id = nextRequestID
        nextRequestID += 1
        payload["id"] = id
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard var line = String(data: data, encoding: .utf8) else { throw JavaDebugProcessError.launchFailed("invalid request") }
        line.append("\n")
        inputHandle.write(line.data(using: .utf8)!)
        if let continuation {
            pending[id] = continuation
        }
        return nil
    }
}

enum JavaDebugPortPicker {
    static func pickPort(preferred: Int?) -> Int {
        if let preferred, preferred > 1024, preferred < 65535 { return preferred }
        return 5005 + Int.random(in: 0..<1000)
    }
}
