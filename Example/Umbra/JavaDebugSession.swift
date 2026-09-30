import Foundation
import JavaIntelligence

struct JavaDebugStackFrame: Identifiable, Equatable, Sendable {
    let index: Int
    let name: String
    let className: String
    let filePath: String
    let line: Int
    /// A JDK frame (`java.*`, `jdk.*`, …), drawn dimmed and hidden by "Hide library frames".
    var isLibrary = false
    var id: Int { index }
}

/// One thread of the program, as the Frames pane's thread picker lists it.
struct JavaDebugThread: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let group: String
    let status: String
    let isSuspended: Bool
    let isCurrent: Bool
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

/// Why the program stopped, beyond the file and line.
struct JavaDebugStopInfo: Equatable, Sendable {
    /// `breakpoint`, `step`, `pause`, `exception`, `method`, `watchpoint`, `runToCursor`,
    /// `dropFrame` or `conditionError`.
    let reason: String
    /// An exception's type and message, or why a condition could not be evaluated.
    let message: String?
    let breakpointID: UUID?
    let threadID: Int
    let threadName: String
    /// Whether every thread is held, or only this one (a Suspend: Thread breakpoint).
    let suspendsAll: Bool
}

/// A class and how many instances of it the heap holds (the Memory tab).
struct JavaDebugClassCount: Identifiable, Equatable, Sendable {
    let className: String
    let count: Int
    var id: String { className }
}

/// What the debugger spent on each breakpoint (the Overhead tab).
struct JavaDebugOverhead: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let breakpointID: UUID
        let hits: Int
        let milliseconds: Double
    }

    let breakpoints: [Entry]
    let steppingMilliseconds: Double
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
    private(set) var stopInfo: JavaDebugStopInfo?
    private(set) var stackFrames: [JavaDebugStackFrame] = []
    /// The selected frame's `this` and locals.
    private(set) var variables: [JavaDebugValue] = []
    private(set) var threads: [JavaDebugThread] = []
    private(set) var selectedFrameIndex = 0
    /// Expressions evaluated in this session, newest first.
    private(set) var evaluations: [JavaDebugEvaluation] = []
    /// The watches' values at the current stop, by expression.
    private(set) var watchResults: [String: JavaDebugEvaluation.Outcome] = [:]
    /// Whether the adapter placed each breakpoint in a loaded class; absent until it did.
    private(set) var breakpointVerification: [UUID: Bool] = [:]
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
    /// The breakpoints the adapter holds, as last sent.
    private var sentBreakpoints: [UUID: JavaBreakpoint] = [:]
    private var sentMuted = false
    /// Expressions re-evaluated at every stop; set by the host from the window's watches.
    var watches: [String] = [] {
        didSet {
            if watches != oldValue, case .stopped = state { Task { await refreshWatches() } }
        }
    }
    /// Called when the program stops at a source file the adapter could locate on disk, so the
    /// host can show the line. Not called for a stop in code with no source file.
    var onStopped: ((_ file: URL, _ line: Int) -> Void)?
    /// The adapter placed a breakpoint, or the session ended and none are placed any more.
    var onBreakpointVerificationChanged: (() -> Void)?
    /// The selected frame's variables changed: a new stop, another frame, or the program ran on.
    var onVariablesChanged: (() -> Void)?
    /// A remove-once-hit breakpoint stopped and the adapter dropped it.
    var onBreakpointRemovedByHit: ((UUID) -> Void)?
    /// The source file's imports, for conditions and evaluations that need compiling.
    var importsProvider: (_ filePath: String) -> [String] = JavaDebugSession.imports(ofFile:)

    var isActive: Bool {
        switch state {
        case .idle, .terminated, .failed(_): return false
        default: return true
        }
    }

    var isStopped: Bool {
        if case .stopped = state { return true }
        return false
    }

    /// - Parameter sourceRoots: directories holding the program's sources, so the adapter can turn a
    ///   class's `com/acme/Foo.java` into a file when it stops in code that has no breakpoint.
    func start(launch: JavaManagedLaunch, breakpoints: [JavaBreakpoint], muted: Bool = false, sourceRoots: [URL] = []) async {
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
            await sync(breakpoints, muted: muted)
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
    /// - Parameter classpath: the program's runtime classpath, for evaluations that need compiling.
    func attachForGradle(
        port: Int = JavaLaunchCommand.gradleDebugJdwpPort,
        suspendOnStart: Bool,
        breakpoints: [JavaBreakpoint],
        muted: Bool = false,
        sourceRoots: [URL] = [],
        classpath: [URL] = []
    ) async {
        do {
            try await attachWithRetry(port: port, maxAttempts: 60, sourceRoots: sourceRoots, classpath: classpath)
            await sync(breakpoints, muted: muted)
            if !suspendOnStart {
                // The JVM held at startup for the debugger; there is no stop to show.
                _ = try? await send(["command": "resume"])
            }
            state = .running
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Breakpoints

    /// Brings the adapter's breakpoints in line with `breakpoints`: sends what is new or changed,
    /// clears what was removed or disabled. Does nothing without a connected adapter.
    func sync(_ breakpoints: [JavaBreakpoint], muted: Bool) async {
        guard inputHandle != nil else { return }
        let wanted = Dictionary(breakpoints.filter(\.isEnabled).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in sentBreakpoints.keys where wanted[id] == nil {
            sentBreakpoints[id] = nil
            breakpointVerification[id] = nil
            _ = try? await send(["command": "clearBreakpoint", "breakpointId": id.uuidString])
        }
        for breakpoint in wanted.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) where sentBreakpoints[breakpoint.id] != breakpoint {
            let changedLine = sentBreakpoints[breakpoint.id].map { $0.line != breakpoint.line || $0.kind != breakpoint.kind } ?? true
            sentBreakpoints[breakpoint.id] = breakpoint
            if changedLine { breakpointVerification[breakpoint.id] = nil }
            let imports = breakpoint.isLineBreakpoint ? importsProvider(breakpoint.filePath) : []
            do {
                _ = try await send(breakpoint.adapterRequest(imports: imports))
            } catch {
                console.appendNote("Breakpoint \(breakpoint.title): \(Self.message(for: error))")
            }
        }
        if muted != sentMuted {
            sentMuted = muted
            _ = try? await send(["command": "muteBreakpoints", "muted": muted])
        }
    }

    // MARK: - Running and stepping

    func resume() {
        run("resume")
    }

    func stepOver() {
        run("stepOver")
    }

    func stepInto() {
        run("stepInto")
    }

    /// Steps into the next call even when it is in the JDK.
    func forceStepInto() {
        run("forceStepInto")
    }

    func stepOut() {
        run("stepOut")
    }

    /// Steps into the call to `methodName` on the current line, past the calls before it.
    func smartStepInto(methodName: String) {
        run("smartStepInto", ["methodName": methodName])
    }

    /// Runs to `line` of `file`. Other breakpoints still stop on the way unless `force`.
    func runToCursor(file: String, line: Int, force: Bool) {
        run("runToCursor", ["file": file, "line": line, "force": force])
    }

    /// Pops the selected frame and the ones above it, so its call runs again.
    func dropFrame() {
        guard isStopped else { return }
        let index = selectedFrameIndex
        Task {
            do {
                _ = try await send(["command": "dropFrame", "frameIndex": index])
            } catch {
                console.appendNote("Drop Frame: \(Self.message(for: error))")
            }
        }
    }

    /// Returns from the current method at once, with `expression`'s value when it returns one.
    func forceReturn(expression: String) async -> String? {
        guard isStopped else { return "The program is not paused." }
        do {
            _ = try await send(["command": "forceReturn", "expression": expression, "imports": stopImports()])
            clearStopState()
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    /// Suspends a running program where it is; the adapter answers with a `stopped` event.
    func pause() {
        guard case .running = state else { return }
        Task { _ = try? await send(["command": "pause"]) }
    }

    /// Lets the program run again for `command`. Only from a stop: a stale double press would
    /// otherwise send a step to a program that is already moving.
    private func run(_ command: String, _ parameters: [String: Any] = [:]) {
        guard isStopped else { return }
        clearStopState()
        var body = parameters
        body["command"] = command
        Task {
            do {
                _ = try await send(body)
            } catch {
                console.appendNote("\(command): \(Self.message(for: error))")
            }
        }
    }

    private func clearStopState() {
        state = .running
        stopInfo = nil
        stackFrames = []
        variables = []
        watchResults = [:]
        onVariablesChanged?()
    }

    // MARK: - Inspecting a stop

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
                return JavaDebugStackFrame(index: index, name: name, className: className, filePath: file, line: line,
                                           isLibrary: frame["library"] as? Bool ?? false)
            }
            await refreshVariables()
            await refreshWatches()
        }
    }

    func refreshThreads() async {
        guard let response = try? await send(["command": "threads"]),
              let list = response["threads"] as? [[String: Any]] else { return }
        threads = list.compactMap { entry in
            guard let id = entry["id"] as? Int, let name = entry["name"] as? String else { return nil }
            return JavaDebugThread(
                id: id,
                name: name,
                group: entry["group"] as? String ?? "",
                status: entry["status"] as? String ?? "",
                isSuspended: entry["suspended"] as? Bool ?? false,
                isCurrent: entry["current"] as? Bool ?? false
            )
        }
    }

    /// Shows another suspended thread's frames and variables.
    func selectThread(_ id: Int) {
        guard isStopped else { return }
        Task {
            do {
                _ = try await send(["command": "selectThread", "threadId": id])
                selectedFrameIndex = 0
                await refreshThreads()
                refreshStack()
            } catch {
                console.appendNote("Switch thread: \(Self.message(for: error))")
            }
        }
    }

    func selectFrame(_ index: Int) {
        selectedFrameIndex = index
        Task {
            await refreshVariables()
            await refreshWatches()
        }
    }

    func refreshVariables() async {
        guard let response = try? await send(["command": "localVariables", "frameIndex": selectedFrameIndex]),
              let variables = response["variables"] as? [[String: Any]] else { return }
        self.variables = variables.compactMap(JavaDebugValue.init(json:))
        onVariablesChanged?()
    }

    func refreshWatches() async {
        guard isStopped else {
            watchResults = [:]
            return
        }
        var results: [String: JavaDebugEvaluation.Outcome] = [:]
        for watch in watches {
            results[watch] = await evaluate(watch, record: false)
        }
        watchResults = results
    }

    /// Evaluates `expression` in the selected stack frame. Works only while the program is paused;
    /// otherwise the outcome is a failure that says so. Recorded in ``evaluations`` when `record`.
    @discardableResult
    func evaluate(_ expression: String, record: Bool = true) async -> JavaDebugEvaluation.Outcome {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = await valueOutcome(["command": "evaluate", "expression": trimmed])
        if record {
            evaluations.insert(JavaDebugEvaluation(expression: trimmed, outcome: outcome), at: 0)
            if evaluations.count > Self.maximumEvaluations { evaluations.removeLast(evaluations.count - Self.maximumEvaluations) }
        }
        return outcome
    }

    /// Set Value: assigns `value` (an expression) to `target` (a local, field or element).
    func setValue(target: String, value: String) async -> JavaDebugEvaluation.Outcome {
        let outcome = await valueOutcome(["command": "setValue", "target": target, "value": value])
        if case .value = outcome {
            await refreshVariables()
            await refreshWatches()
        }
        return outcome
    }

    private func valueOutcome(_ request: [String: Any]) async -> JavaDebugEvaluation.Outcome {
        guard isStopped else { return .failure("The program is not paused.") }
        var body = request
        body["frameIndex"] = selectedFrameIndex
        let imports = stopImports()
        if !imports.isEmpty { body["imports"] = imports }
        do {
            let response = try await send(body)
            if let node = (response["result"] as? [String: Any]).flatMap(JavaDebugValue.init(json:)) {
                return .value(node)
            }
            return .failure("The debugger sent no result.")
        } catch {
            return .failure(Self.message(for: error))
        }
    }

    /// The imports of the selected frame's file.
    private func stopImports() -> [String] {
        let path = stackFrames.first { $0.index == selectedFrameIndex }?.filePath
            ?? { if case .stopped(let file, _, _) = state { return file.path } else { return nil } }()
        guard let path, path.hasPrefix("/") else { return [] }
        return importsProvider(path)
    }

    func clearEvaluations() {
        evaluations = []
    }

    /// Fills the Evaluate field and asks the panel to focus it.
    func requestEvaluationInput(prefilledWith text: String?) {
        if let text, !text.isEmpty { evaluationDraft = text }
        evaluationFocusRequest += 1
    }

    // MARK: - Memory, overhead, streams

    func instanceCounts() async -> Result<[JavaDebugClassCount], JavaDebugProcessError> {
        do {
            let response = try await send(["command": "instanceCounts"])
            let list = response["classes"] as? [[String: Any]] ?? []
            return .success(list.compactMap { entry in
                guard let name = entry["className"] as? String, let count = entry["count"] as? Int else { return nil }
                return JavaDebugClassCount(className: name, count: count)
            })
        } catch {
            return .failure(error as? JavaDebugProcessError ?? .launchFailed(error.localizedDescription))
        }
    }

    /// Up to `limit` instances of `className`, each opened by evaluating its `#id` expression.
    func instances(of className: String, limit: Int = 1000) async -> Result<[JavaDebugValue], JavaDebugProcessError> {
        do {
            let response = try await send(["command": "instances", "className": className, "limit": limit])
            return .success((response["instances"] as? [[String: Any]] ?? []).compactMap(JavaDebugValue.init(json:)))
        } catch {
            return .failure(error as? JavaDebugProcessError ?? .launchFailed(error.localizedDescription))
        }
    }

    func overhead() async -> JavaDebugOverhead? {
        guard let response = try? await send(["command": "overhead"]) else { return nil }
        let entries = (response["breakpoints"] as? [[String: Any]] ?? []).compactMap { entry -> JavaDebugOverhead.Entry? in
            guard let id = (entry["id"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
            return JavaDebugOverhead.Entry(
                breakpointID: id,
                hits: entry["hits"] as? Int ?? 0,
                milliseconds: (entry["millis"] as? NSNumber)?.doubleValue ?? 0
            )
        }
        return JavaDebugOverhead(breakpoints: entries, steppingMilliseconds: (response["steppingMillis"] as? NSNumber)?.doubleValue ?? 0)
    }

    /// Runs a stream chain rewritten by ``JavaStreamChain/tracedExpression(for:)`` and returns
    /// what each stage saw, and the terminal result.
    func traceStream(expression: String) async -> Result<(stages: [[JavaStreamTraceElement]], result: JavaDebugValue?), JavaDebugProcessError> {
        guard isStopped else { return .failure(.launchFailed("The program is not paused.")) }
        var body: [String: Any] = ["command": "traceStream", "expression": expression, "frameIndex": selectedFrameIndex]
        let imports = stopImports()
        if !imports.isEmpty { body["imports"] = imports }
        do {
            let response = try await send(body)
            let stages = (response["stages"] as? [[String: Any]] ?? []).map { stage in
                (stage["values"] as? [[String: Any]] ?? []).map { entry in
                    JavaStreamTraceElement(
                        time: (entry["time"] as? NSNumber)?.int64Value ?? 0,
                        value: entry["value"] as? String ?? "",
                        identity: entry["identity"] as? String ?? ""
                    )
                }
            }
            let result = (response["result"] as? [String: Any]).flatMap(JavaDebugValue.init(json:))
            return .success((stages, result))
        } catch {
            return .failure(error as? JavaDebugProcessError ?? .launchFailed(error.localizedDescription))
        }
    }

    static func message(for error: Error) -> String {
        switch error as? JavaDebugProcessError {
        case .launchFailed(let message): return message
        case .disconnected: return "The debugger is no longer connected."
        case .adapterNotFound: return "The debug adapter was not found."
        case nil: return error.localizedDescription
        }
    }

    // MARK: - Session

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
        onVariablesChanged?()
        threads = []
        stopInfo = nil
        watchResults = [:]
        selectedFrameIndex = 0
        evaluations = []
        sentBreakpoints = [:]
        sentMuted = false
        let hadVerification = !breakpointVerification.isEmpty
        breakpointVerification = [:]
        if hadVerification { onBreakpointVerificationChanged?() }
        isGradleAttachSession = false
        if case .failed = state { return }
        state = .terminated
    }

    private func attachWithRetry(port: Int, maxAttempts: Int, sourceRoots: [URL], classpath: [URL]) async throws {
        var lastError: Error = JavaDebugProcessError.launchFailed("could not attach")
        for _ in 0..<maxAttempts {
            do {
                _ = try await send([
                    "command": "attach",
                    "port": port,
                    "sourceRoots": sourceRoots.map(\.path),
                    "classpath": classpath.map(\.path).joined(separator: ":")
                ])
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
                stopInfo = JavaDebugStopInfo(
                    reason: reason,
                    message: json["message"] as? String,
                    breakpointID: (json["breakpointId"] as? String).flatMap(UUID.init(uuidString:)),
                    threadID: json["threadId"] as? Int ?? 0,
                    threadName: json["threadName"] as? String ?? "",
                    suspendsAll: json["suspendsAll"] as? Bool ?? true
                )
                if let message = json["message"] as? String {
                    console.appendNote(reason == "conditionError" ? message : "Stopped on \(message)")
                }
                // A new stop starts at the innermost frame, whichever one was selected before.
                selectedFrameIndex = 0
                refreshStack()
                Task { await refreshThreads() }
                // A relative path means no source root held the file; there is nothing to open.
                if filePath.hasPrefix("/") {
                    onStopped?(file, line)
                }
            case "output":
                for entry in json["lines"] as? [[String: Any]] ?? [] {
                    let stream: IDEDebugConsoleLog.Stream = switch entry["stream"] as? String {
                    case "err": .err
                    case "log": .log
                    default: .out
                    }
                    console.append(stream: stream, text: entry["text"] as? String ?? "", partial: entry["partial"] as? Bool ?? false)
                }
            case "breakpointVerified":
                if let id = (json["id"] as? String).flatMap(UUID.init(uuidString:)) {
                    breakpointVerification[id] = json["verified"] as? Bool ?? true
                    onBreakpointVerificationChanged?()
                }
            case "breakpointRemoved":
                if let id = (json["id"] as? String).flatMap(UUID.init(uuidString:)) {
                    sentBreakpoints[id] = nil
                    breakpointVerification[id] = nil
                    onBreakpointRemovedByHit?(id)
                }
            case "terminated":
                if case .terminated = state {} else if let code = json["exitCode"] as? Int {
                    console.appendNote("Process finished with exit code \(code)")
                } else if isActive {
                    console.appendNote("The debugger disconnected.")
                }
                state = .terminated
                stopInfo = nil
                variables = []
                onVariablesChanged?()
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

    // MARK: - Imports

    /// The `import` declarations at the top of a Java file on disk, for the adapter's compiler.
    nonisolated static func imports(ofFile path: String) -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return imports(inSource: text)
    }

    /// Reads `import …;` lines until the first type declaration; stops early, it never parses the
    /// whole file.
    nonisolated static func imports(inSource text: String) -> [String] {
        var imports: [String] = []
        var scanned = 0
        text.enumerateLines { line, stop in
            scanned += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("import ") {
                imports.append(trimmed.hasSuffix(";") ? String(trimmed.dropLast()) : trimmed)
            } else if trimmed.contains("class ") || trimmed.contains("interface ") || trimmed.contains("enum ")
                        || trimmed.contains("record ") || scanned > 400 {
                stop = true
            }
        }
        return imports
    }
}

enum JavaDebugPortPicker {
    static func pickPort(preferred: Int?) -> Int {
        if let preferred, preferred > 1024, preferred < 65535 { return preferred }
        return 5005 + Int.random(in: 0..<1000)
    }
}
