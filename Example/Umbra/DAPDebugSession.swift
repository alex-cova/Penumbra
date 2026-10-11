import Foundation
import Observation
import SubprocessKit

/// One expression evaluated in the current Swift frame.
struct DAPDebugEvaluation: Identifiable, Equatable, Sendable {
    var id = UUID()
    var expression: String
    var result: String
}

/// A Swift debug session spoken to `lldb-dap` through ``DAPClient``.
///
/// The sequence is the one the spike proved: `initialize`, `launch` with `stopOnEntry`,
/// `initialized`, `setBreakpoints`, `configurationDone`, continue past the entry `SIGSTOP`,
/// then the breakpoint stop. Later stops, steps and output arrive on the event pump.
@MainActor
@Observable
final class DAPDebugSession: IDEDebugSession {
    private(set) var state: IDEDebugSessionState = .idle
    private(set) var threads: [IDEDebugThread] = []
    private(set) var frames: [IDEDebugFrame] = []
    private(set) var variables: [IDEDebugVariable] = []
    private(set) var selectedThreadID: Int?
    private(set) var selectedFrameID: Int?
    private(set) var evaluations: [DAPDebugEvaluation] = []
    var evaluationDraft = ""
    let console = IDEDebugConsoleLog()

    /// The stopped file, so the editor can show the line.
    var onStopped: ((_ file: URL, _ line: Int) -> Void)?

    @ObservationIgnored private var client: DAPClient?
    @ObservationIgnored private var parentClient: DAPClient?
    @ObservationIgnored private var server: SubprocessHandle?
    @ObservationIgnored private var parentTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var breakpointPaths: Set<String> = []
    @ObservationIgnored private var preferredSourcePath: String?

    var isActive: Bool {
        switch state {
        case .idle, .terminated, .failed: return false
        default: return true
        }
    }

    /// The Debug tool window keeps showing this session after it ends, until a Java session replaces it.
    var presentsDebugger: Bool {
        if case .idle = state { return false }
        return true
    }

    var isStopped: Bool {
        if case .stopped = state { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// Shown while SwiftPM builds, before `lldb-dap` starts.
    func beginLaunch(of name: String) {
        cancelAdapter()
        clearStack()
        evaluations = []
        state = .launching
        console.reset()
        console.appendNote("Building \(name)…")
    }

    func noteFailure(_ message: String) {
        state = .failed(message)
        console.appendNote(message)
    }

    /// Starts `lldb-dap`, sets the line breakpoints, and continues past the entry stop.
    func launch(adapterPath: String, program: URL, workingDirectory: URL, lineBreakpoints: [String: [Int]]) async {
        cancelAdapter()
        clearStack()
        if case .launching = state {
            console.appendNote("Launching \(program.lastPathComponent)")
        } else {
            evaluations = []
            state = .launching
            console.reset()
            console.appendNote("Launching \(program.lastPathComponent)")
        }
        do {
            let client = try DAPClient.make(adapterPath: adapterPath, workingDirectory: workingDirectory)
            self.client = client
            try await client.initialize()
            let launchSeq = client.send(command: "launch", arguments: [
                "program": program.path,
                "cwd": workingDirectory.path,
                "stopOnEntry": true,
                "args": [String]()
            ])
            _ = try await client.event("initialized", seconds: 15)
            breakpointPaths = Set(lineBreakpoints.keys)
            for (path, lines) in lineBreakpoints {
                _ = try await client.request("setBreakpoints", [
                    "source": ["path": path],
                    "breakpoints": lines.map { ["line": $0] }
                ], seconds: 10)
            }
            let doneSeq = client.send(command: "configurationDone", arguments: [:])
            let entry = try await client.event("stopped", seconds: 20)
            _ = try await client.finish(doneSeq, command: "configurationDone", seconds: 10)
            _ = try await client.finish(launchSeq, command: "launch", seconds: 5)
            guard let threadID = entry.body?.int("threadId") else {
                throw LLDBDAPSpikeError.failed("entry stop had no thread id")
            }
            selectedThreadID = threadID
            state = .running
            startEventPump()
            _ = try await client.request("continue", ["threadId": threadID], seconds: 15)
        } catch {
            noteFailure(String(describing: error))
            cancelAdapter()
        }
    }

    /// Starts js-debug, then the child connection it asks for, and stops on the file's breakpoints.
    ///
    /// The server listens on a port. The first connection launches the program and receives
    /// `startDebugging`. The second connection, carrying `__pendingTargetId`, is the one that stops.
    func launchJavaScript(
        node: String, serverScript: URL, program: URL, workingDirectory: URL, lineBreakpoints: [String: [Int]]
    ) async {
        cancelAdapter()
        clearStack()
        preferredSourcePath = program.path
        if case .launching = state {
            console.appendNote("Launching \(program.lastPathComponent)")
        } else {
            evaluations = []
            state = .launching
            console.reset()
            console.appendNote("Launching \(program.lastPathComponent)")
        }
        do {
            let endpoint = try await startJavaScriptServer(node: node, serverScript: serverScript)
            let parent = try DAPClient.connect(host: endpoint.host, port: endpoint.port)
            parentClient = parent
            try await prepare(parent, adapterID: "pwa-node")
            try await sendLineBreakpoints(parent, linesByPath: lineBreakpoints)
            _ = try await parent.request("configurationDone", [:], seconds: 10)
            _ = try await parent.request("launch", [
                "type": "pwa-node",
                "request": "launch",
                "name": program.lastPathComponent,
                "program": program.path,
                "cwd": workingDirectory.path,
                "stopOnEntry": false
            ], seconds: 20)
            let start = try await parent.reverseRequest("startDebugging", seconds: 15)
            guard let command = start.string("command"), let requestSeq = start.int("seq"),
                  let configuration = start.object("arguments")?.object("configuration")?.jsonObject() as? [String: Any]
            else { throw LLDBDAPSpikeError.failed("startDebugging had no target") }
            parent.respond(requestSeq: requestSeq, command: command)
            startParentPump(parent)
            let child = try DAPClient.connect(host: endpoint.host, port: endpoint.port)
            client = child
            try await prepare(child, adapterID: "pwa-node")
            breakpointPaths = Set(lineBreakpoints.keys)
            try await sendLineBreakpoints(child, linesByPath: lineBreakpoints)
            _ = try await child.request("configurationDone", [:], seconds: 10)
            _ = try await child.request("launch", configuration, seconds: 20)
            state = .running
            startEventPump()
        } catch {
            noteFailure(String(describing: error))
            cancelAdapter()
        }
    }

    func resume() { sendStepping("continue") }
    func pause() { sendStepping("pause", running: false) }
    func stepOver() { sendStepping("next") }
    func stepInto() { sendStepping("stepIn") }
    func stepOut() { sendStepping("stepOut") }

    func stop() {
        let active = client != nil || isActive
        cancelAdapter()
        clearStack()
        if active { state = .terminated }
    }

    /// Hides this session so the Java debugger owns the tool window.
    func retire() {
        cancelAdapter()
        clearStack()
        evaluations = []
        state = .idle
    }

    func selectThread(_ id: Int) {
        selectedThreadID = id
        Task { await reloadFrames(threadID: id) }
    }

    func selectFrame(_ id: Int) {
        selectedFrameID = id
        Task { await reloadVariables(frameID: id) }
    }

    func evaluate(_ expression: String) async -> String? {
        guard let client, let frameID = selectedFrameID else { return nil }
        do {
            let response = try await client.request("evaluate", [
                "expression": expression,
                "frameId": frameID,
                "context": "repl"
            ], seconds: 20)
            return response.body?.string("result")
        } catch {
            return String(describing: error)
        }
    }

    func submitEvaluation() async {
        let expression = evaluationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else { return }
        let result = await evaluate(expression) ?? ""
        evaluations.insert(DAPDebugEvaluation(expression: expression, result: result), at: 0)
        if evaluations.count > 30 { evaluations.removeLast(evaluations.count - 30) }
    }

    func clearEvaluations() { evaluations = [] }

    func setLineBreakpoints(_ linesByPath: [String: [Int]]) async {
        guard let client else { return }
        let paths = breakpointPaths.union(linesByPath.keys)
        breakpointPaths = Set(linesByPath.keys)
        for path in paths {
            _ = try? await client.request("setBreakpoints", [
                "source": ["path": path],
                "breakpoints": (linesByPath[path] ?? []).map { ["line": $0] }
            ], seconds: 10)
        }
    }

    private func sendStepping(_ command: String, running: Bool = true) {
        guard let client, let threadID = selectedThreadID else { return }
        if running {
            state = .running
            variables = []
        }
        Task {
            _ = try? await client.request(command, ["threadId": threadID], seconds: 30)
        }
    }

    private func startEventPump() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let client = self.client else { return }
                do {
                    let event = try await client.nextEvent(seconds: 30)
                    await self.handle(event)
                } catch LLDBDAPSpikeError.timeout {
                    if client.adapterIsFinished {
                        if case .failed = self.state { return }
                        self.state = .terminated
                        self.console.appendNote("lldb-dap exited")
                        return
                    }
                } catch {
                    if !Task.isCancelled, self.isActive, !self.isFailed {
                        self.noteFailure(String(describing: error))
                    }
                    return
                }
            }
        }
    }

    private func handle(_ event: DAPValue) async {
        switch event.string("event") {
        case "stopped":
            await applyStop(event)
        case "output":
            let text = event.body?.string("output") ?? ""
            guard !text.isEmpty else { return }
            let stream: IDEDebugConsoleLog.Stream = event.body?.string("category") == "stderr" ? .err : .out
            console.append(stream: stream, text: text, partial: !text.hasSuffix("\n"))
        case "terminated":
            state = .terminated
            console.appendNote("Debug session ended")
        case "exited":
            let code = event.body?.int("exitCode")
            console.appendNote("Process exited\(code.map { " with code \($0)" } ?? "")")
            state = .terminated
        default:
            break
        }
    }

    private func applyStop(_ event: DAPValue) async {
        let reason = event.body?.string("reason") ?? "stopped"
        guard let threadID = event.body?.int("threadId") else { return }
        selectedThreadID = threadID
        do {
            let listed = try await client?.request("threads", [:], seconds: 10)
            threads = (listed?.body?.array("threads") ?? []).compactMap { thread in
                guard let id = thread.int("id") else { return nil }
                return IDEDebugThread(id: id, name: thread.string("name") ?? "Thread \(id)")
            }
            await reloadFrames(threadID: threadID)
            if isFailed { return }
            let frame = frames.first { $0.file?.path == preferredSourcePath } ?? frames.first { $0.file != nil }
            let file = frame?.file
            let line = frame?.line ?? frames.first?.line ?? 0
            state = .stopped(file: file, line: line, reason: reason)
            if let file { onStopped?(file, line) }
        } catch {
            noteFailure(String(describing: error))
        }
    }

    private func reloadFrames(threadID: Int) async {
        guard let client else { return }
        do {
            let response = try await client.request("stackTrace", [
                "threadId": threadID,
                "startFrame": 0,
                "levels": 40
            ], seconds: 15)
            frames = (response.body?.array("stackFrames") ?? []).compactMap { frame in
                guard let id = frame.int("id") else { return nil }
                let path = frame.object("source")?.string("path")
                return IDEDebugFrame(
                    id: id,
                    name: frame.string("name") ?? "",
                    file: path.map { URL(fileURLWithPath: $0) },
                    line: frame.int("line") ?? 0
                )
            }
            let selected = frames.first { $0.file?.path == preferredSourcePath }
                ?? frames.first { $0.file != nil }
                ?? frames.first
            selectedFrameID = selected?.id
            if let id = selected?.id { await reloadVariables(frameID: id) }
        } catch {
            noteFailure(String(describing: error))
        }
    }

    private func reloadVariables(frameID: Int) async {
        guard let client else { return }
        do {
            try await loadVariables(frameID: frameID, client: client)
        } catch {
            noteFailure(String(describing: error))
        }
    }

    private func loadVariables(frameID: Int, client: DAPClient) async throws {
        let scopes = try await client.request("scopes", ["frameId": frameID], seconds: 15)
        var collected: [IDEDebugVariable] = []
        for scope in scopes.body?.array("scopes") ?? [] {
            let scopeName = scope.string("name") ?? ""
            if scopeName == "Registers" { continue }
            guard let reference = scope.int("variablesReference"), reference > 0 else { continue }
            let listed = try await client.request("variables", ["variablesReference": reference], seconds: 15)
            for variable in listed.body?.array("variables") ?? [] {
                let name = variable.string("name") ?? ""
                guard !name.isEmpty else { continue }
                collected.append(IDEDebugVariable(
                    name: name,
                    type: variable.string("type") ?? "",
                    value: variable.string("value") ?? "",
                    variablesReference: variable.int("variablesReference") ?? 0
                ))
            }
        }
        variables = collected
    }

    private func clearStack() {
        threads = []
        frames = []
        variables = []
        selectedThreadID = nil
        selectedFrameID = nil
        breakpointPaths = []
        preferredSourcePath = nil
    }

    private func prepare(_ client: DAPClient, adapterID: String) async throws {
        _ = try await client.request("initialize", [
            "clientID": "umbra",
            "clientName": "Umbra",
            "adapterID": adapterID,
            "pathFormat": "path",
            "linesStartAt1": true,
            "columnsStartAt1": true,
            "supportsVariableType": true
        ], seconds: 15)
        _ = try await client.event("initialized", seconds: 10)
    }

    private func sendLineBreakpoints(_ client: DAPClient, linesByPath: [String: [Int]]) async throws {
        for (path, lines) in linesByPath where !lines.isEmpty {
            _ = try await client.request("setBreakpoints", [
                "source": ["path": path],
                "breakpoints": lines.map { ["line": $0] }
            ], seconds: 10)
        }
    }

    private func startJavaScriptServer(node: String, serverScript: URL) async throws -> (host: String, port: UInt16) {
        let box = JSDebugListenBox()
        var request = SubprocessRequest(executable: node, arguments: [serverScript.path, "0"])
        request.workingDirectory = serverScript.deletingLastPathComponent().deletingLastPathComponent()
        request.standardInput = .closed
        request.stdoutCapture = .discard
        request.stderrCapture = .bounded(head: 8_000, tail: 4_000)
        request.processGroup = true
        request.killGroupOnExit = true
        request.terminationGrace = .seconds(2)
        let handle = try SubprocessRunner.start(request) { data, source in
            guard source == .stdout else { return }
            box.append(data)
        }
        server = handle
        return try await box.endpoint(timeout: 15)
    }

    private func startParentPump(_ parent: DAPClient) {
        parentTask?.cancel()
        parentTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await parent.nextMessage(seconds: 30)
                    if message.string("type") == "request",
                       let command = message.string("command"),
                       let seq = message.int("seq") {
                        parent.respond(requestSeq: seq, command: command)
                    }
                } catch LLDBDAPSpikeError.timeout {
                    if parent.adapterIsFinished { return }
                } catch {
                    return
                }
            }
            _ = self
        }
    }

    private func cancelAdapter() {
        eventTask?.cancel()
        eventTask = nil
        parentTask?.cancel()
        parentTask = nil
        client?.stop()
        parentClient?.stop()
        server?.terminate()
        client = nil
        parentClient = nil
        server = nil
    }
}

/// Collects js-debug's "Debug server listening at host:port" line.
private final class JSDebugListenBox: @unchecked Sendable {
    private final class Waiter {
        let continuation: CheckedContinuation<(String, UInt16), Error>
        private let lock = NSLock()
        private var resumed = false
        init(_ continuation: CheckedContinuation<(String, UInt16), Error>) { self.continuation = continuation }
        var isResumed: Bool { lock.withLock { resumed } }
        func resume(returning value: (String, UInt16)) {
            let go: Bool = lock.withLock {
                if resumed { return false }
                resumed = true
                return true
            }
            if go { continuation.resume(returning: value) }
        }
        func resume(throwing error: Error) {
            let go: Bool = lock.withLock {
                if resumed { return false }
                resumed = true
                return true
            }
            if go { continuation.resume(throwing: error) }
        }
    }

    private let lock = NSLock()
    private var buffer = Data()
    private var waiters: [Waiter] = []
    private var endpoint: (String, UInt16)?

    func append(_ data: Data) {
        let ready: (String, UInt16)? = lock.withLock {
            buffer.append(data)
            guard endpoint == nil, let text = String(data: buffer, encoding: .utf8) else { return nil }
            for line in text.split(whereSeparator: \.isNewline) {
                if let found = Self.endpoint(in: String(line)) {
                    endpoint = found
                    return found
                }
            }
            return nil
        }
        guard let ready else { return }
        let pending: [Waiter] = lock.withLock {
            let pending = waiters
            waiters = []
            return pending
        }
        pending.forEach { $0.resume(returning: ready) }
    }

    func endpoint(timeout: Double) async throws -> (String, UInt16) {
        if let endpoint = lock.withLock({ endpoint }) { return endpoint }
        return try await withCheckedThrowingContinuation { continuation in
            let waiter = Waiter(continuation)
            let already: (String, UInt16)? = lock.withLock {
                if let endpoint { return endpoint }
                waiters.append(waiter)
                return nil
            }
            if let already {
                waiter.resume(returning: already)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                let giveUp: Bool = self.lock.withLock {
                    guard self.endpoint == nil, !waiter.isResumed else { return false }
                    self.waiters.removeAll { $0 === waiter }
                    return true
                }
                if giveUp { waiter.resume(throwing: LLDBDAPSpikeError.timeout("js-debug to listen")) }
            }
        }
    }

    static func endpoint(in line: String) -> (String, UInt16)? {
        guard let marker = line.range(of: "listening at ") else { return nil }
        let rest = line[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = rest.lastIndex(of: ":") else { return nil }
        let host = String(rest[..<colon])
        guard let port = UInt16(rest[rest.index(after: colon)...]), !host.isEmpty else { return nil }
        return (host, port)
    }
}
