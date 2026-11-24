import Foundation

/// This process's own stdin and stdout as an `ACPTransport`: newline-delimited JSON-RPC, for a program that is
/// the agent or server end of a pipe (`UmbraACP`, the `umbra-conversation-mcp` helper). Nothing is spawned.
public final class ACPStandardIOTransport: ACPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private var closedFlag = false
    public let incoming: AsyncStream<Data>

    public init() {
        var captured: AsyncStream<Data>.Continuation?
        incoming = AsyncStream<Data> { captured = $0 }
        continuation = captured
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                FileHandle.standardInput.readabilityHandler = nil
                self.lock.withLock { self.continuation }?.finish()
            } else {
                self.lock.withLock { self.continuation }?.yield(data)
            }
        }
    }

    public func send(_ line: Data) async throws {
        lock.withLock {
            if closedFlag { return }
            var frame = line
            if !frame.isEmpty, frame.last != UInt8(ascii: "\n") { frame.append(UInt8(ascii: "\n")) }
            FileHandle.standardOutput.write(frame)
        }
    }

    public func close() async {
        let continuation: AsyncStream<Data>.Continuation? = lock.withLock {
            closedFlag = true
            let captured = self.continuation
            self.continuation = nil
            return captured
        }
        FileHandle.standardInput.readabilityHandler = nil
        continuation?.finish()
    }
}
