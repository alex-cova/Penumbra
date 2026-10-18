import Foundation

/// The ACP transport seam: newline-delimited JSON-RPC frames over an injected channel.
///
/// AgentKit never spawns a process. Umbra implements this over `SubprocessKit`; tests use the
/// in-memory pair in `Testing/`. A transport yields arbitrary chunks in `incoming` — framing
/// (splitting/coalescing, oversized-line cap) lives in `ACPConnection`.
public protocol ACPTransport: Sendable {
    /// Sends one frame. The connection passes a single JSON object without a trailing newline;
    /// transports that need one on the wire add it themselves.
    func send(_ line: Data) async throws
    /// Incoming bytes, in arbitrary chunkings. Finishing the stream means the peer went away.
    var incoming: AsyncStream<Data> { get }
    func close() async
}
