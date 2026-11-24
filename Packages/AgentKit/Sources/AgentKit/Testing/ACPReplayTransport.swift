import Foundation

/// The agent's side of an `ACPRecording`, played back to a live client (`ACPClientSession`): each frame the
/// client sends must be the next one the recording has the client sending, and the agent's frames that follow
/// it are then sent back. A client request is matched by method and its live id stands in for the recorded
/// one in the agent's answer; a notification by method; an answer to an agent request by id and by being a
/// result or an error. Client frames sent back to back may come in another order. Anything else is a
/// mismatch: it is recorded in `mismatches` and the stream ends, as if the agent had gone away.
public final class ACPReplayTransport: ACPTransport, @unchecked Sendable {
    public struct Mismatch: Sendable, Equatable, CustomStringConvertible {
        public var expected: String
        public var got: String
        public var description: String { "expected \(expected), got \(got)" }
    }

    public let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var entries: [ACPRecording.Entry]
    private var position = 0
    private var liveIDs: [JSONRPCID: JSONRPCID] = [:]
    private var recordedMismatches: [Mismatch] = []
    private var finished = false

    public init(_ entries: [ACPRecording.Entry]) {
        self.entries = entries
        (incoming, continuation) = AsyncStream<Data>.makeStream()
        lock.withLock { emitAgentFrames() }
    }

    public convenience init(recording text: String) throws {
        self.init(try ACPRecording.entries(from: text))
    }

    public var mismatches: [Mismatch] { lock.withLock { recordedMismatches } }
    /// Every frame of the recording was played or matched.
    public var isComplete: Bool { lock.withLock { position == entries.count } }

    public func send(_ line: Data) async throws {
        lock.withLock {
            guard !finished else { return }
            guard let message = try? JSONRPCMessage(parsing: line) else {
                fail(expected: "a JSON-RPC frame", got: String(decoding: line, as: UTF8.self))
                return
            }
            // The run of client frames before the agent's next one may arrive in any order.
            var candidate = position
            var matched: Int?
            while candidate < entries.count, entries[candidate].side == .client {
                if let recorded = Self.message(entries[candidate]), matches(recorded: recorded, live: message) {
                    matched = candidate
                    break
                }
                candidate += 1
            }
            guard let matched else {
                let expected = position < entries.count ? Self.describe(entries[position]) : "the end of the recording"
                fail(expected: expected, got: Self.describe(message))
                return
            }
            if matched != position { entries.swapAt(matched, position) }
            if case .request(let recordedID, _, _) = Self.message(entries[position]), case .request(let liveID, _, _) = message {
                liveIDs[recordedID] = liveID
            }
            position += 1
            emitAgentFrames()
        }
    }

    public func close() async {
        lock.withLock { finish() }
    }

    // MARK: - Under the lock

    private func matches(recorded: JSONRPCMessage, live: JSONRPCMessage) -> Bool {
        switch (recorded, live) {
        case (.request(_, let a, _), .request(_, let b, _)): a == b
        case (.notification(let a, _), .notification(let b, _)): a == b
        case (.result(let a, _), .result(let b, _)): a == b
        case (.error(let a, _), .error(let b, _)): a == b
        default: false
        }
    }

    private func emitAgentFrames() {
        while !finished, position < entries.count, entries[position].side == .agent {
            let entry = entries[position]
            position += 1
            guard var frame = entry.frame else {
                finish()
                return
            }
            // An answer to a client request carries the id the live client used.
            if frame["method"] == nil, let recordedID = frame["id"].flatMap(JSONRPCID.init(jsonValue:)) {
                guard let liveID = liveIDs[recordedID] else {
                    fail(expected: "a client request with id \(recordedID) before its answer", got: "nothing")
                    return
                }
                if case .object(var object) = frame {
                    object["id"] = liveID.jsonValue
                    frame = .object(object)
                }
            }
            guard let text = try? frame.serialized() else { continue }
            continuation.yield(Data((text + "\n").utf8))
        }
    }

    private func fail(expected: String, got: String) {
        recordedMismatches.append(Mismatch(expected: expected, got: got))
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        continuation.finish()
    }

    private static func message(_ entry: ACPRecording.Entry) -> JSONRPCMessage? {
        guard let text = try? entry.frame?.serialized() else { return nil }
        return try? JSONRPCMessage(parsing: Data(text.utf8))
    }

    private static func describe(_ entry: ACPRecording.Entry) -> String {
        guard entry.frame != nil else { return "the agent closing" }
        return message(entry).map(describe) ?? "a frame"
    }

    private static func describe(_ message: JSONRPCMessage) -> String {
        switch message {
        case .request(let id, let method, _): "request \(method) (id \(id))"
        case .notification(let method, _): "notification \(method)"
        case .result(let id, _): "result for id \(id)"
        case .error(let id, let error): "error for id \(id.map { "\($0)" } ?? "none"): \(error.message)"
        }
    }
}
