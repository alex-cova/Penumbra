import Foundation

/// A paired in-memory `ACPTransport` for tests: two ends, each sending to the other's stream.
/// Closing one end finishes the other's stream, like a process exiting.
public final class ACPInMemoryTransport: ACPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private var peer: ACPInMemoryTransport?
    private var didClose = false

    public let incoming: AsyncStream<Data>

    private init() {
        var captured: AsyncStream<Data>.Continuation?
        incoming = AsyncStream<Data> { captured = $0 }
        continuation = captured
    }

    public static func pair() -> (client: ACPInMemoryTransport, agent: ACPInMemoryTransport) {
        let client = ACPInMemoryTransport()
        let agent = ACPInMemoryTransport()
        client.peer = agent
        agent.peer = client
        return (client, agent)
    }

    public func send(_ line: Data) async throws {
        let target: ACPInMemoryTransport? = lock.withLock {
            if didClose { return nil }
            return peer
        }
        guard let target else { throw ACPError.transportClosed }
        var frame = line
        if !frame.isEmpty, frame.last != UInt8(ascii: "\n") { frame.append(UInt8(ascii: "\n")) }
        target.deliver(frame)
    }

    private func deliver(_ data: Data) {
        lock.withLock { continuation }?.yield(data)
    }

    /// Delivers raw bytes without newline framing, to exercise the connection's reassembly.
    public func sendRaw(_ data: Data) {
        peer?.deliver(data)
    }

    public func close() async {
        let (own, other): (AsyncStream<Data>.Continuation?, ACPInMemoryTransport?) = lock.withLock {
            if didClose { return (nil, nil) }
            didClose = true
            let current = continuation
            continuation = nil
            return (current, peer)
        }
        own?.finish()
        other?.finishFromPeer()
    }

    private func finishFromPeer() {
        let current: AsyncStream<Data>.Continuation? = lock.withLock {
            let captured = continuation
            continuation = nil
            return captured
        }
        current?.finish()
    }
}
