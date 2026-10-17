import Foundation
import SubprocessKit

/// Speaks to one `JavaAnalysisServer` (warm `javac`) over JSON lines on its stdio, through
/// SubprocessKit — never `Foundation.Process`.
///
/// The server starts lazily on the first request, restarts on crash with backoff, and shuts
/// down after `idleTimeout` without requests. Every request carries a numeric id; responses
/// are matched back to their sender, so a slow `check` never blocks `cancel` or `shutdown`.
public actor JavaAnalysisServerClient {
    /// Handle for an in-flight `check`: await it, or cancel just this request.
    public struct CheckHandle: Sendable {
        fileprivate let id: Int64
    }

    private let configuration: JavaAnalysisServerConfiguration
    private let idleTimeout: Duration

    private var nextID: Int64 = 1
    /// The last `configure` params per module id, replayed whenever the server (re)starts —
    /// a relaunch forgets every module, and callers must not reconfigure by hand.
    private var configuredModules: [String: [String: Any]] = [:]
    private var handle: SubprocessHandle?
    private var pump: LinePump?
    private var lineContinuation: AsyncStream<String>.Continuation?
    private var readerTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var pending: [Int64: CheckedContinuation<ServerResult, Error>] = [:]
    /// Responses that arrived before their `result(for:)` call (or after a cancellation).
    private var earlyResults: [Int64: Result<ServerResult, Error>] = [:]
    private var consecutiveFailures = 0
    private var isShutdown = false

    /// JSON-decoded `result` of one response: either `{"ok":true}` or `{"diagnostics":[…]}`.
    private struct ServerResult: Sendable {
        var ok = false
        var diagnostics: [JavaAnalysisServerDiagnostic] = []
    }

    public init(configuration: JavaAnalysisServerConfiguration, idleTimeout: Duration = .seconds(600)) {
        self.configuration = configuration
        self.idleTimeout = idleTimeout
    }

    // MARK: - Requests

    /// Sends `configure` for a module. The server caches one file manager per module id, so
    /// calling this again with new paths re-resolves the module from scratch.
    public func configure(_ module: JavaAnalysisServerModule) async throws {
        var params: [String: Any] = [
            "moduleId": module.moduleId,
            "classpath": module.classpath.map(\.path),
            "sourcepath": module.sourcepath.map(\.path),
            "processorPath": module.processorPath.map(\.path),
            "options": module.options,
        ]
        if let release = module.release { params["release"] = String(release) }
        configuredModules[module.moduleId] = params
        let result = try await send(method: "configure", params: params)
        guard result.ok else {
            configuredModules.removeValue(forKey: module.moduleId)
            throw JavaAnalysisServerError.serverError("configure not acknowledged")
        }
    }

    /// Sends `check` without waiting: the returned handle selects this request in `result(for:)`
    /// and `cancel(_:)`.
    public func beginCheck(moduleId: String, file: URL, text: String, overlays: [JavaAnalysisServerOverlay] = []) async throws -> CheckHandle {
        var params: [String: Any] = [
            "moduleId": moduleId,
            "file": file.path,
            "text": text,
        ]
        if !overlays.isEmpty {
            params["overlays"] = overlays.map { ["file": $0.file.path, "text": $0.text] }
        }
        return CheckHandle(id: try await sendWithoutWaiting(method: "check", params: params))
    }

    /// The `check` result for a handle from `beginCheck`. Throws `cancelled` after `cancel(_:)`,
    /// `terminated` when the server died mid-request (the next request relaunches it).
    public func result(for handle: CheckHandle) async throws -> [JavaAnalysisServerDiagnostic] {
        try await response(for: handle).diagnostics
    }

    /// Sends `cancel` for a `check` handle and fails its waiter with `cancelled`. Best effort:
    /// an in-flight compilation still finishes on the server, but its response is dropped.
    public func cancel(_ handle: CheckHandle) {
        if let continuation = pending.removeValue(forKey: handle.id) {
            continuation.resume(throwing: JavaAnalysisServerError.cancelled)
        } else {
            rememberEarly(handle.id, .failure(JavaAnalysisServerError.cancelled))
        }
        let params: [String: Any] = ["id": handle.id]
        Task { try? await self.send(method: "cancel", params: params) }
    }

    /// `beginCheck` plus `result(for:)`.
    public func check(moduleId: String, file: URL, text: String, overlays: [JavaAnalysisServerOverlay] = []) async throws -> [JavaAnalysisServerDiagnostic] {
        try await result(for: try await beginCheck(moduleId: moduleId, file: file, text: text, overlays: overlays))
    }

    /// Shuts the server down now (a drained `shutdown`: in-flight checks answer first). A later
    /// request relaunches it. A no-op when it was never started.
    public func shutdown() async {
        idleTask?.cancel()
        idleTask = nil
        guard let handle else { return }
        isShutdown = true
        defer { isShutdown = false }
        _ = try? await send(method: "shutdown", params: [:])
        handle.closeInput()
        _ = await handle.result
        readerTask?.cancel()
        monitorTask?.cancel()
        self.handle = nil
        pump = nil
        lineContinuation?.finish()
        lineContinuation = nil
        pending.removeAll()
        earlyResults.removeAll()
    }

    // MARK: - Transport

    private func send(method: String, params: [String: Any]) async throws -> ServerResult {
        try await response(for: CheckHandle(id: try await sendWithoutWaiting(method: method, params: params)))
    }

    private func response(for handle: CheckHandle) async throws -> ServerResult {
        if let early = earlyResults.removeValue(forKey: handle.id) {
            rescheduleIdleShutdown()
            return try early.get()
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ServerResult, Error>) in
                    pending[handle.id] = continuation
                }
            } onCancel: {
                Task { await self.cancel(handle) }
            }
            rescheduleIdleShutdown()
            return result
        } catch {
            rescheduleIdleShutdown()
            throw error
        }
    }

    /// Writes one request line, relaunching a dead server once. Returns the request id; the
    /// caller owns awaiting (or cancelling) the response.
    private func sendWithoutWaiting(method: String, params: [String: Any]) async throws -> Int64 {
        for attempt in 0...1 {
            try await ensureRunning()
            let id = nextID
            nextID += 1
            let request: [String: Any] = ["id": id, "method": method, "params": params]
            // JSONSerialization writes without spaces; the server reads line-delimited frames.
            let line = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)! + "\n"
            handle?.write(Data(line.utf8))
            // The server may have died between `ensureRunning` and the write: its monitor fails
            // the waiter, and the second attempt goes to a fresh process.
            if attempt == 0, let handle, handle.isFinished {
                failAllPending(with: JavaAnalysisServerError.terminated("server exited before accepting the request"))
                continue
            }
            idleTask?.cancel()
            idleTask = nil
            return id
        }
        throw JavaAnalysisServerError.terminated("server would not stay up")
    }

    private func ensureRunning() async throws {
        if let handle, !handle.isFinished { return }
        cleanupAfterExit()
        if consecutiveFailures > 0 {
            let backoffMs = min(250 * Int(pow(2.0, Double(consecutiveFailures - 1))), 5000)
            try? await Task.sleep(for: .milliseconds(backoffMs))
        }
        var request = SubprocessRequest(
            executable: configuration.javaExecutable.path,
            arguments: ["-Xmx\(configuration.maxHeapMB)m", "-jar", configuration.jarURL.path]
        )
        request.standardInput = .interactive
        request.stdoutCapture = .discard
        request.stderrCapture = .discard
        let pump = LinePump()
        self.pump = pump
        let (lines, continuation) = AsyncStream<String>.makeStream()
        lineContinuation = continuation
        do {
            handle = try SubprocessRunner.start(request, onOutput: { data, source in
                pump.received(data, from: source, into: continuation)
            })
        } catch {
            self.pump = nil
            lineContinuation = nil
            continuation.finish()
            consecutiveFailures += 1
            throw JavaAnalysisServerError.launchFailed(error.localizedDescription)
        }
        consecutiveFailures = 0
        startReader(stream: lines)
        startMonitor()
        try await replayConfigurations()
    }

    private func replayConfigurations() async throws {
        for (moduleId, params) in configuredModules {
            let result = try await send(method: "configure", params: params)
            guard result.ok else {
                throw JavaAnalysisServerError.serverError("configure not acknowledged for \(moduleId)")
            }
        }
    }

    private func startReader(stream: AsyncStream<String>) {
        readerTask?.cancel()
        readerTask = Task { await self.readLoop(stream: stream) }
    }

    private func startMonitor() {
        monitorTask?.cancel()
        guard let handle else { return }
        monitorTask = Task { [weak self] in
            let result = await handle.result
            guard let self else { return }
            await self.serverDidExit(result: result)
        }
    }

    private func serverDidExit(result: SubprocessResult) async {
        if result.exit.succeeded {
            consecutiveFailures = 0
        } else {
            consecutiveFailures += 1
        }
        let tail = pump?.stderrTail ?? ""
        cleanupAfterExit()
        guard !isShutdown else { return }
        let detail = tail.isEmpty ? "exit \(result.exit.status)" : String(tail.suffix(2000))
        failAllPending(with: JavaAnalysisServerError.terminated("analysis server exited (\(detail))"))
    }

    private func cleanupAfterExit() {
        handle = nil
        pump = nil
        readerTask?.cancel()
        readerTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        lineContinuation?.finish()
        lineContinuation = nil
    }

    private func failAllPending(with error: Error) {
        let waiting = pending
        pending = [:]
        for (id, continuation) in waiting {
            rememberEarly(id, .failure(error))
            continuation.resume(throwing: error)
        }
    }

    /// Keeps responses that arrived before their waiter, bounded so abandoned ids can't grow it.
    private func rememberEarly(_ id: Int64, _ result: Result<ServerResult, Error>) {
        if earlyResults.count > 64 { earlyResults.removeAll() }
        earlyResults[id] = result
    }

    private func readLoop(stream: AsyncStream<String>) async {
        for await line in stream {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = (object["id"] as? NSNumber)?.int64Value
            if let id, let continuation = pending.removeValue(forKey: id) {
                continuation.resume(with: decodeResponse(object))
            } else if let id {
                rememberEarly(id, decodeResponse(object))
            }
            // Responses without an id answer no request; they are server bugs, ignored.
        }
    }

    private func decodeResponse(_ object: [String: Any]) -> Result<ServerResult, Error> {
        if let error = object["error"] as? [String: Any] {
            return .failure(JavaAnalysisServerError.serverError(error["message"] as? String ?? "unknown error"))
        }
        guard let result = object["result"] as? [String: Any] else {
            return .failure(JavaAnalysisServerError.serverError("response has neither result nor error"))
        }
        var decoded = ServerResult()
        decoded.ok = (result["ok"] as? NSNumber)?.boolValue ?? false
        if let items = result["diagnostics"] as? [[String: Any]] {
            decoded.diagnostics = items.compactMap(Self.decodeDiagnostic)
            decoded.ok = true
        }
        return .success(decoded)
    }

    private static func decodeDiagnostic(_ object: [String: Any]) -> JavaAnalysisServerDiagnostic? {
        guard let key = object["key"] as? String,
              let severityString = object["severity"] as? String,
              let severity = JavaAnalysisServerDiagnostic.Severity(rawValue: severityString),
              let message = object["message"] as? String else { return nil }
        return JavaAnalysisServerDiagnostic(
            key: key,
            severity: severity,
            start: (object["start"] as? NSNumber)?.intValue,
            end: (object["end"] as? NSNumber)?.intValue,
            line: (object["line"] as? NSNumber)?.intValue,
            column: (object["column"] as? NSNumber)?.intValue,
            file: object["file"] as? String,
            message: message
        )
    }

    private func rescheduleIdleShutdown() {
        idleTask?.cancel()
        guard idleTimeout > .zero else { return }
        idleTask = Task {
            try? await Task.sleep(for: self.idleTimeout)
            guard !Task.isCancelled else { return }
            await self.shutdownIfIdle()
        }
    }

    private func shutdownIfIdle() async {
        guard pending.isEmpty else {
            rescheduleIdleShutdown()
            return
        }
        await shutdown()
    }
}

/// Splits the server's stdout byte stream into lines and keeps a bounded stderr tail for crash
/// reports. One instance per launched process: it is captured by SubprocessKit's Sendable
/// output closure and mutated under a lock.
private final class LinePump: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = UTF8ChunkDecoder()
    private var lineBuffer = ""
    private var stderrText = ""

    var stderrTail: String { lock.withLock { stderrText } }

    func received(_ data: Data, from source: SubprocessOutputSource, into continuation: AsyncStream<String>.Continuation) {
        switch source {
        case .stdout:
            let lines: [String] = lock.withLock {
                lineBuffer += decoder.feed(data)
                var lines: [String] = []
                while let newline = lineBuffer.firstIndex(of: "\n") {
                    lines.append(String(lineBuffer[..<newline]))
                    lineBuffer = String(lineBuffer[lineBuffer.index(after: newline)...])
                }
                return lines
            }
            for line in lines { continuation.yield(line) }
        case .stderr:
            lock.withLock {
                stderrText += String(decoding: data, as: UTF8.self)
                if stderrText.count > 8192 { stderrText = String(stderrText.suffix(8192)) }
            }
        }
    }
}
