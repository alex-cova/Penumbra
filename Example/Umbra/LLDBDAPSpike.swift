import Foundation
import SubprocessKit

/// Proves `lldb-dap` before any debugger session type exists.
///
/// Discovery is a user path, then `xcrun --find lldb-dap`. The adapter is launched through
/// SubprocessKit. The probe compiles a tiny program, sets one breakpoint, continues to the stop,
/// reads a frame and a variable, steps, and evaluates an expression.
enum LLDBDAPSpike {
    struct Report: Sendable {
        var adapterPath: String
        var adapterVersion: String
        var launched = false
        var stopped = false
        var stopReason: String?
        var frameName: String?
        var variableName: String?
        var variableValue: String?
        var stepped = false
        var evaluated: String?
        var failure: String?

        var summary: String {
            [
                "adapter: \(adapterPath)",
                "version: \(adapterVersion)",
                "launched: \(launched)",
                "stopped: \(stopped) \(stopReason ?? "")",
                "frame: \(frameName ?? "")",
                "variable: \(variableName ?? "") = \(variableValue ?? "")",
                "stepped: \(stepped)",
                "evaluated: \(evaluated ?? "")",
                failure.map { "failure: \($0)" } ?? ""
            ].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    static func discover(userPath: String?) async -> String? {
        if let userPath, FileManager.default.isExecutableFile(atPath: userPath) { return userPath }
        return await xcrunFind("lldb-dap")
    }

    /// Runs the probe. A missing compiler or a protocol failure is recorded on the report.
    static func run(adapterPath: String) async -> Report {
        var report = Report(adapterPath: adapterPath, adapterVersion: await version(of: adapterPath))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-lldb-dap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let sourceURL = root.appendingPathComponent("main.swift")
            try Data(programSource.utf8).write(to: sourceURL)
            let binary = root.appendingPathComponent("spike")
            try await compile(source: sourceURL, binary: binary)
            let session = try DAPClient.make(adapterPath: adapterPath, workingDirectory: root)
            defer { session.stop() }
            try await session.initialize()
            let stopped = try await session.runUntilStop(
                program: binary, cwd: root, file: sourceURL, line: breakpointLine
            )
            report.launched = true
            report.stopped = true
            report.stopReason = stopped.reason
            guard let threadID = stopped.threadID else {
                report.failure = "stopped without a thread id"
                return report
            }
            let frame = try await session.topFrame(threadID: threadID)
            report.frameName = frame.name
            if let value = try await session.variable(named: "value", frameID: frame.id) {
                report.variableName = "value"
                report.variableValue = value
            } else {
                report.failure = "no variable named value in frame \(frame.id)"
                return report
            }
            try await session.stepOver(threadID: threadID)
            report.stepped = true
            let stepped = try await session.topFrame(threadID: threadID)
            report.evaluated = try await session.evaluate("answer", frameID: stepped.id)
            try await session.disconnect()
        } catch {
            report.failure = String(describing: error)
        }
        return report
    }

    /// Line 2 is `let answer`, so a stop there has already executed `let value = 21`.
    private static let breakpointLine = 2
    private static let programSource = """
    let value = 21
    let answer = value + 21
    print(answer)
    """

    private static func version(of path: String) async -> String {
        var request = SubprocessRequest(executable: path, arguments: ["--version"])
        request.stdoutCapture = .bounded(head: 4_096, tail: 0)
        request.stderrCapture = .bounded(head: 1_024, tail: 0)
        request.timeout = .seconds(10)
        guard let result = try? await SubprocessRunner.run(request) else { return "" }
        let text = result.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? result.stderr.text.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }

    private static func xcrunFind(_ tool: String) async -> String? {
        var request = SubprocessRequest(executable: "/usr/bin/xcrun", arguments: ["--find", tool])
        request.stdoutCapture = .bounded(head: 2_048, tail: 0)
        request.stderrCapture = .discard
        request.timeout = .seconds(15)
        guard let result = try? await SubprocessRunner.run(request), result.exit.succeeded else { return nil }
        let path = result.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// Compiles `source` with debug info. Tests use this so they do not link SubprocessKit themselves.
    static func compileExecutable(source: URL, binary: URL) async throws {
        try await compile(source: source, binary: binary)
    }

    /// `xcrun --sdk macosx` selects the SDK. A bare `swiftc` path misses it and cannot load the stdlib.
    private static func compile(source: URL, binary: URL) async throws {
        var request = SubprocessRequest(
            executable: "/usr/bin/xcrun",
            arguments: ["--sdk", "macosx", "swiftc", "-g", "-Onone", "-o", binary.path, source.path]
        )
        request.stdoutCapture = .bounded(head: 8_000, tail: 2_000)
        request.stderrCapture = .bounded(head: 8_000, tail: 4_000)
        request.timeout = .seconds(60)
        let result = try await SubprocessRunner.run(request)
        guard result.exit.succeeded else {
            throw LLDBDAPSpikeError.failed("swiftc failed: \(result.stderr.text)")
        }
    }
}

enum LLDBDAPSpikeError: Error, CustomStringConvertible, Sendable {
    case timeout(String)
    case failed(String)
    case disconnected

    var description: String {
        switch self {
        case .timeout(let label): "timed out waiting for \(label)"
        case .failed(let message): message
        case .disconnected: "lldb-dap closed the stream"
        }
    }
}

protocol DAPTransport: AnyObject, Sendable {
    func write(_ data: Data)
    func stop()
    var isFinished: Bool { get }
}

/// One Content-Length session. `lldb-dap` is a subprocess; js-debug is a TCP socket.
final class DAPClient: @unchecked Sendable {
    private let transport: any DAPTransport
    private let lock = NSLock()
    private var buffer = Data()
    private var nextSeq = 1
    private var inbox: [DAPValue] = []
    private var waiters: [Waiter] = []
    private var stderr = Data()
    private var trace: [String] = []

    static func make(adapterPath: String, workingDirectory: URL) throws -> DAPClient {
        let box = CallbackBox()
        var request = SubprocessRequest(executable: adapterPath)
        request.standardInput = .interactive
        request.workingDirectory = workingDirectory
        request.stdoutCapture = .discard
        request.stderrCapture = .bounded(head: 8_000, tail: 4_000)
        request.processGroup = true
        request.killGroupOnExit = true
        request.terminationGrace = .seconds(2)
        let handle = try SubprocessRunner.start(request) { data, source in
            box.accept(data, source: source)
        }
        let session = DAPClient(transport: ProcessDAPTransport(handle: handle))
        box.setHandler { [weak session] data, source in
            session?.accept(data, source: source)
        }
        return session
    }

    /// A session on a TCP socket. js-debug's `dapDebugServer.js` listens, it does not speak on stdio.
    static func connect(host: String, port: UInt16) throws -> DAPClient {
        let box = CallbackBox()
        let transport = try SocketDAPTransport.connect(host: host, port: port) { data in
            box.accept(data, source: .stdout)
        }
        let session = DAPClient(transport: transport)
        box.setHandler { [weak session] data, source in
            session?.accept(data, source: source)
        }
        return session
    }

    private init(transport: any DAPTransport) {
        self.transport = transport
    }

    func stop() {
        transport.stop()
    }

    func initialize() async throws {
        _ = try await request("initialize", [
            "clientID": "umbra",
            "clientName": "Umbra",
            "adapterID": "lldb",
            "pathFormat": "path",
            "linesStartAt1": true,
            "columnsStartAt1": true,
            "supportsVariableType": true,
            "supportsRunInTerminalRequest": false
        ], seconds: 20)
    }

    /// LLVM 21's lldb-dap answers `initialize` and sends `initialized` only after `launch`.
    /// `configurationDone` before `launch` fails. The process is stopped on entry (a `SIGSTOP`
    /// reported as `exception`) so the breakpoint is bound before `continue`; a three-line
    /// program otherwise runs to exit while Swift modules are still loading.
    fileprivate func runUntilStop(program: URL, cwd: URL, file: URL, line: Int) async throws -> Stop {
        let launchSeq = send(command: "launch", arguments: [
            "program": program.path,
            "cwd": cwd.path,
            "stopOnEntry": true,
            "args": [String]()
        ])
        _ = try await event("initialized", seconds: 10)
        let breakpoints = try await request("setBreakpoints", [
            "source": ["path": file.path],
            "breakpoints": [["line": line]]
        ], seconds: 10)
        let verified = (breakpoints.body?.array("breakpoints") ?? []).contains { $0.bool("verified") == true }
        guard verified else { throw LLDBDAPSpikeError.failed("the breakpoint on line \(line) was not verified") }
        let doneSeq = send(command: "configurationDone", arguments: [:])
        let entry = try await event("stopped", seconds: 15)
        _ = try await finish(doneSeq, command: "configurationDone", seconds: 10)
        _ = try await finish(launchSeq, command: "launch", seconds: 5)
        guard let threadID = entry.body?.int("threadId") else {
            throw LLDBDAPSpikeError.failed("entry stop had no thread id. \(debugDump())")
        }
        let continueSeq = send(command: "continue", arguments: ["threadId": threadID])
        let stopped = try await event("stopped", seconds: 20)
        _ = try await finish(continueSeq, command: "continue", seconds: 10)
        return Stop(reason: stopped.body?.string("reason"), threadID: stopped.body?.int("threadId"))
    }

    fileprivate func topFrame(threadID: Int) async throws -> Frame {
        let response = try await request("stackTrace", [
            "threadId": threadID,
            "startFrame": 0,
            "levels": 20
        ], seconds: 20)
        guard let frame = response.body?.array("stackFrames")?.first, let id = frame.int("id") else {
            throw LLDBDAPSpikeError.failed("stackTrace returned no frame id")
        }
        return Frame(id: id, name: frame.string("name") ?? "")
    }

    func variable(named name: String, frameID: Int) async throws -> String? {
        let scopes = try await request("scopes", ["frameId": frameID], seconds: 20)
        for scope in scopes.body?.array("scopes") ?? [] {
            guard let reference = scope.int("variablesReference"), reference > 0 else { continue }
            let variables = try await request("variables", ["variablesReference": reference], seconds: 20)
            for variable in variables.body?.array("variables") ?? [] {
                if variable.string("name") == name { return variable.string("value") }
            }
        }
        return nil
    }

    func stepOver(threadID: Int) async throws {
        async let stepped: DAPValue = request("next", ["threadId": threadID], seconds: 30)
        _ = try await event("stopped", seconds: 30)
        _ = try await stepped
    }

    func evaluate(_ expression: String, frameID: Int) async throws -> String {
        let response = try await request("evaluate", [
            "expression": expression,
            "frameId": frameID,
            "context": "repl"
        ], seconds: 20)
        return response.body?.string("result") ?? ""
    }

    func disconnect() async throws {
        _ = try await request("disconnect", ["terminateDebuggee": true], seconds: 10)
    }

    func request(_ command: String, _ arguments: [String: Any], seconds: Double) async throws -> DAPValue {
        let seq = send(command: command, arguments: arguments)
        return try await finish(seq, command: command, seconds: seconds)
    }

    func finish(_ seq: Int, command: String, seconds: Double) async throws -> DAPValue {
        let response = try await receive(seconds: seconds, label: command) { $0.isResponse(seq) }
        if response.bool("success") == false {
            throw LLDBDAPSpikeError.failed("\(command) failed: \(response.string("message") ?? command). \(stderrText)")
        }
        return response
    }

    func event(_ name: String, seconds: Double) async throws -> DAPValue {
        try await receive(seconds: seconds, label: name) { $0.isEvent(name) }
    }

    private var stderrText: String {
        let data = lock.withLock { stderr }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func debugDump() -> String {
        lock.lock()
        let traced = trace
        let leftover = String(data: buffer.prefix(180), encoding: .utf8) ?? ""
        let errors = String(data: stderr.prefix(500), encoding: .utf8) ?? ""
        lock.unlock()
        return "trace=\(traced) leftover=\(leftover) stderr=\(errors)"
    }

    /// The next DAP event, including ones that arrived while a request was in flight.
    func nextEvent(seconds: Double) async throws -> DAPValue {
        try await receive(seconds: seconds, label: "event") { value in
            guard case .object(let fields) = value else { return false }
            if case .string("event") = fields["type"] { return true }
            return false
        }
    }

    var adapterIsFinished: Bool { transport.isFinished }

    /// Answers a reverse request, such as js-debug's `startDebugging`.
    func respond(requestSeq: Int, command: String) {
        let seq: Int = lock.withLock {
            let value = nextSeq
            nextSeq += 1
            return value
        }
        let payload: [String: Any] = [
            "seq": seq,
            "type": "response",
            "request_seq": requestSeq,
            "success": true,
            "command": command
        ]
        writePayload(payload)
    }

    func reverseRequest(_ command: String, seconds: Double) async throws -> DAPValue {
        try await receive(seconds: seconds, label: command) { value in
            guard case .object(let fields) = value,
                  case .string("request") = fields["type"],
                  case .string(let name) = fields["command"] else { return false }
            return name == command
        }
    }

    func nextMessage(seconds: Double) async throws -> DAPValue {
        try await receive(seconds: seconds, label: "message") { _ in true }
    }

    func send(command: String, arguments: [String: Any]) -> Int {
        let seq: Int = lock.withLock {
            let value = nextSeq
            nextSeq += 1
            return value
        }
        let payload: [String: Any] = [
            "seq": seq,
            "type": "request",
            "command": command,
            "arguments": arguments
        ]
        writePayload(payload)
        return seq
    }

    private func writePayload(_ payload: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        transport.write(frame)
    }

    private func receive(
        seconds: Double,
        label: String,
        match: @escaping @Sendable (DAPValue) -> Bool
    ) async throws -> DAPValue {
        let once = ResumeOnce()
        let slot = ContinuationSlot()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DAPValue, Error>) in
                let cancelled = slot.store(continuation)
                if cancelled {
                    fail(once, continuation, .timeout(label))
                    return
                }
                let queued: DAPValue? = lock.withLock {
                    guard let index = inbox.firstIndex(where: match) else {
                        waiters.append(Waiter(once: once, continuation: continuation, match: match))
                        return nil
                    }
                    return inbox.remove(at: index)
                }
                if let queued {
                    once.resume(continuation, .success(queued))
                    return
                }
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    self.fail(once, continuation, .timeout("\(label). \(self.debugDump())"))
                }
            }
        } onCancel: {
            let continuation = slot.cancel()
            if let continuation { self.fail(once, continuation, .timeout(label)) }
        }
    }

    private func fail(
        _ once: ResumeOnce,
        _ continuation: CheckedContinuation<DAPValue, Error>,
        _ error: LLDBDAPSpikeError
    ) {
        lock.withLock { waiters.removeAll { $0.once === once } }
        once.resume(continuation, .failure(error))
    }

    fileprivate func accept(_ data: Data, source: SubprocessOutputSource) {
        if source == .stderr {
            lock.withLock {
                if stderr.count < 12_000 { stderr.append(data) }
            }
            return
        }
        let resumptions: [(ResumeOnce, CheckedContinuation<DAPValue, Error>, DAPValue)] = lock.withLock {
            buffer.append(data)
            var resumptions: [(ResumeOnce, CheckedContinuation<DAPValue, Error>, DAPValue)] = []
            for message in takeMessages() {
                if let index = waiters.firstIndex(where: { $0.match(message) }) {
                    let waiter = waiters.remove(at: index)
                    resumptions.append((waiter.once, waiter.continuation, message))
                } else {
                    inbox.append(message)
                }
            }
            return resumptions
        }
        for (once, continuation, message) in resumptions {
            once.resume(continuation, .success(message))
        }
    }

    /// Caller holds `lock`.
    private func takeMessages() -> [DAPValue] {
        var messages: [DAPValue] = []
        let marker = Data("Content-Length:".utf8)
        while true {
            if let range = buffer.range(of: marker), range.lowerBound > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<range.lowerBound)
            }
            guard buffer.starts(with: marker) else { break }
            let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) ?? buffer.range(of: Data("\n\n".utf8))
            guard let headerEnd else { break }
            let header = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
            guard let length = contentLength(in: header) else {
                buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
                continue
            }
            let bodyStart = headerEnd.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { break }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            let body = buffer.subdata(in: bodyStart..<bodyEnd)
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
            if let object = try? JSONSerialization.jsonObject(with: body) {
                let value = DAPValue(object)
                messages.append(value)
                if trace.count < 20 {
                    trace.append(value.traceLine)
                }
            } else if trace.count < 20 {
                trace.append("unparsed \(body.count) bytes")
            }
        }
        return messages
    }

    private func contentLength(in header: Data) -> Int? {
        guard let text = String(data: header, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { continue }
            return Int(pair[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

/// Holds the output callback. The process can write before `make` returns, so the box exists first
/// and the session is installed as soon as it does.
/// Output can arrive before `make` has a session. Bytes wait here and are delivered once the
/// handler is installed.
private final class CallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Data, SubprocessOutputSource) -> Void)?
    private var pending: [(Data, SubprocessOutputSource)] = []

    func setHandler(_ handler: @escaping @Sendable (Data, SubprocessOutputSource) -> Void) {
        let queued: [(Data, SubprocessOutputSource)] = lock.withLock {
            self.handler = handler
            let queued = pending
            pending = []
            return queued
        }
        for (data, source) in queued { handler(data, source) }
    }

    func accept(_ data: Data, source: SubprocessOutputSource) {
        let handler: (@Sendable (Data, SubprocessOutputSource) -> Void)? = lock.withLock {
            if let handler { return handler }
            pending.append((data, source))
            return nil
        }
        handler?(data, source)
    }
}

private struct Stop: Sendable {
    var reason: String?
    var threadID: Int?
}

private struct Frame: Sendable {
    var id: Int
    var name: String
}

private struct Waiter {
    var once: ResumeOnce
    var continuation: CheckedContinuation<DAPValue, Error>
    var match: @Sendable (DAPValue) -> Bool
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<DAPValue, Error>, _ result: Result<DAPValue, Error>) {
        let already: Bool = lock.withLock {
            let already = resumed
            resumed = true
            return already
        }
        if !already { continuation.resume(with: result) }
    }
}

private final class ContinuationSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DAPValue, Error>?
    private var cancelled = false

    func store(_ continuation: CheckedContinuation<DAPValue, Error>) -> Bool {
        lock.withLock {
            self.continuation = continuation
            return cancelled
        }
    }

    func cancel() -> CheckedContinuation<DAPValue, Error>? {
        lock.withLock {
            cancelled = true
            let continuation = continuation
            self.continuation = nil
            return continuation
        }
    }
}

enum DAPValue: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([DAPValue])
    case object([String: DAPValue])

    init(_ any: Any) {
        if any is NSNull {
            self = .null
        } else if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if number.doubleValue.rounded(.towardZero) == number.doubleValue,
                      number.doubleValue >= Double(Int.min), number.doubleValue <= Double(Int.max) {
                self = .int(number.intValue)
            } else {
                self = .double(number.doubleValue)
            }
        } else if let value = any as? String {
            self = .string(value)
        } else if let value = any as? [Any] {
            self = .array(value.map(DAPValue.init))
        } else if let value = any as? [String: Any] {
            self = .object(value.mapValues(DAPValue.init))
        } else {
            self = .null
        }
    }

    func object(_ key: String) -> DAPValue? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    func jsonObject() -> Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        case .array(let values): values.map { $0.jsonObject() }
        case .object(let fields): fields.mapValues { $0.jsonObject() }
        }
    }

    func string(_ key: String) -> String? {
        guard case .object(let fields) = self, case .string(let value) = fields[key] else { return nil }
        return value
    }

    func bool(_ key: String) -> Bool? {
        guard case .object(let fields) = self, case .bool(let value) = fields[key] else { return nil }
        return value
    }

    func int(_ key: String) -> Int? {
        guard case .object(let fields) = self else { return nil }
        switch fields[key] {
        case .int(let value): return value
        case .double(let value): return Int(value)
        default: return nil
        }
    }

    func array(_ key: String) -> [DAPValue]? {
        guard case .object(let fields) = self, case .array(let value) = fields[key] else { return nil }
        return value
    }

    var body: DAPValue? {
        guard case .object(let fields) = self else { return nil }
        return fields["body"]
    }

    func isResponse(_ seq: Int) -> Bool {
        guard case .object(let fields) = self, case .string("response") = fields["type"] else { return false }
        switch fields["request_seq"] {
        case .int(let value): return value == seq
        case .double(let value): return Int(value) == seq
        default: return false
        }
    }

    func isEvent(_ name: String) -> Bool {
        guard case .object(let fields) = self,
              case .string("event") = fields["type"],
              case .string(let event) = fields["event"] else { return false }
        return event == name
    }

    var traceLine: String {
        let type = string("type") ?? "?"
        let name = string("command") ?? string("event") ?? ""
        return "\(type) \(name)"
    }
}

private final class ProcessDAPTransport: DAPTransport, @unchecked Sendable {
    private let handle: SubprocessHandle

    init(handle: SubprocessHandle) {
        self.handle = handle
    }

    func write(_ data: Data) { handle.write(data) }
    func stop() { handle.terminate() }
    var isFinished: Bool { handle.isFinished }
}

private final class SocketDAPTransport: DAPTransport, @unchecked Sendable {
    private let fd: Int32
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var finished = false

    static func connect(host: String, port: UInt16, onRead: @escaping @Sendable (Data) -> Void) throws -> SocketDAPTransport {
        let fd = try openSocket(host: host, port: port)
        let transport = SocketDAPTransport(fd: fd, onRead: onRead)
        return transport
    }

    private init(fd: Int32, onRead: @escaping @Sendable (Data) -> Void) {
        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "umbra.dap.socket"))
        self.source = source
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                onRead(Data(buffer.prefix(count)))
            } else if count == 0 {
                self?.source.cancel()
            }
        }
        source.setCancelHandler { [weak self] in
            self?.markFinished()
            close(fd)
        }
        source.resume()
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if count > 0 { sent += count; continue }
                if errno == EINTR { continue }
                return
            }
        }
    }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        source.cancel()
    }

    var isFinished: Bool { lock.withLock { finished } }

    private func markFinished() {
        lock.withLock { finished = true }
    }

    private static func openSocket(host: String, port: UInt16) throws -> Int32 {
        let ipv6 = host.contains(":")
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LLDBDAPSpikeError.failed("could not open a socket") }
        var result: Int32 = -1
        if ipv6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            guard host.withCString({ inet_pton(AF_INET6, $0, &address.sin6_addr) }) == 1 else {
                close(fd)
                throw LLDBDAPSpikeError.failed("could not read the debug server address \(host)")
            }
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
                close(fd)
                throw LLDBDAPSpikeError.failed("could not read the debug server address \(host)")
            }
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard result == 0 else {
            close(fd)
            throw LLDBDAPSpikeError.failed("could not connect to the debug server at \(host):\(port)")
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        return fd
    }
}
