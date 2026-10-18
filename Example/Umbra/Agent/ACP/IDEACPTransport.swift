import AgentKit
import Foundation
import SubprocessKit

/// Umbra's real `ACPTransport`: an ACP agent process over `SubprocessKit`, spawned lazily on
/// the first frame (plan step 5). Stdout is the ACP channel; stderr is kept (bounded) for
/// error reporting and never parsed as protocol.
final class IDEACPTransport: ACPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private var handle: SubprocessHandle?
    private var spawned = false
    private var closedFlag = false
    private var stderrText = ""

    let definition: IDEACPDefinition
    let workingDirectory: URL
    let environment: [String: String]

    public let incoming: AsyncStream<Data>

    init(definition: IDEACPDefinition, workingDirectory: URL, environment: [String: String]) {
        self.definition = definition
        self.workingDirectory = workingDirectory
        self.environment = environment
        var captured: AsyncStream<Data>.Continuation?
        incoming = AsyncStream<Data> { captured = $0 }
        continuation = captured
    }

    var isRunning: Bool { lock.withLock { handle != nil && !(handle?.isFinished ?? true) } }

    /// The last of what the agent wrote to stderr, for a crash message.
    var recentStderr: String { lock.withLock { stderrText } }

    func send(_ line: Data) async throws {
        let handle = try ensureSpawned()
        var frame = line
        if !frame.isEmpty, frame.last != UInt8(ascii: "\n") { frame.append(UInt8(ascii: "\n")) }
        handle.write(frame)
    }

    private func ensureSpawned() throws -> SubprocessHandle {
        try lock.withLock {
            if closedFlag { throw ACPError.transportClosed }
            if let handle { return handle }
            guard !spawned else { throw ACPError.transportClosed }
            spawned = true
            guard let executable = definition.resolvedExecutable(pathValue: environment["PATH"] ?? "") else {
                throw ACPError.agentError(JSONRPCError(
                    code: -32000, message: "Could not find the ACP agent executable “\(definition.command)” on PATH."))
            }
            var request = SubprocessRequest(executable: executable, arguments: definition.args)
            request.workingDirectory = workingDirectory
            request.environment = environment
            request.standardInput = .interactive
            request.output = .separateStreams
            request.processGroup = true
            request.killGroupOnExit = true
            request.terminationGrace = .seconds(2)
            let started = try SubprocessRunner.start(request) { [weak self] data, source in
                guard let self else { return }
                switch source {
                case .stdout:
                    self.lock.withLock { self.continuation }?.yield(data)
                case .stderr:
                    self.lock.withLock {
                        self.stderrText += String(decoding: data, as: UTF8.self)
                        if self.stderrText.count > 4096 { self.stderrText = String(self.stderrText.suffix(4096)) }
                    }
                }
            }
            handle = started
            Task { [weak self] in
                _ = await started.result
                guard let self else { return }
                let continuation: AsyncStream<Data>.Continuation? = self.lock.withLock {
                    let captured = self.continuation
                    self.continuation = nil
                    return captured
                }
                continuation?.finish()
            }
            return started
        }
    }

    /// Hard stop: SIGTERM to the process group, then SIGKILL after the request's grace.
    func terminate() {
        lock.withLock { handle }?.terminate()
    }

    func close() async {
        let (continuation, handle): (AsyncStream<Data>.Continuation?, SubprocessHandle?) = lock.withLock {
            closedFlag = true
            let captured = self.continuation
            self.continuation = nil
            return (captured, self.handle)
        }
        handle?.closeInput()
        handle?.terminate()
        continuation?.finish()
    }
}
