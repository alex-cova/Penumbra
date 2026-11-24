import Foundation

/// A recorded ACP conversation between a client and a real agent, one JSON object per line
/// (`docs/harness/agent-harness-11.md`, item 3): `{"from":"client"|"agent","frame":{…}}`, and
/// `{"from":"agent","closed":true}` where the agent went away. `ACPReplayTransport` plays the agent's side of
/// one back, so tests check the client against what an adapter really sends instead of hand-written frames.
public enum ACPRecording {
    public enum Side: String, Sendable, Codable {
        case client
        case agent
    }

    public struct Entry: Sendable, Equatable {
        public var side: Side
        /// Nil for the agent's close marker.
        public var frame: JSONValue?

        public init(side: Side, frame: JSONValue?) {
            self.side = side
            self.frame = frame
        }

        public static func closed() -> Entry { Entry(side: .agent, frame: nil) }
        public var isClose: Bool { frame == nil }

        public var line: String {
            let object: JSONValue = if let frame {
                .object(["from": .string(side.rawValue), "frame": frame])
            } else {
                .object(["from": .string(side.rawValue), "closed": .bool(true)])
            }
            return (try? object.serialized()) ?? "{}"
        }
    }

    /// Reads a recording. Blank lines and lines starting with `//` (a note at the top) are skipped.
    public static func entries(from text: String) throws -> [Entry] {
        try text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") { return nil }
            let value = try JSONValue(parsing: line)
            guard let side = value["from"]?.stringValue.flatMap(Side.init(rawValue:)) else {
                throw ACPError.malformedFrame("recording line without \"from\"")
            }
            if value["closed"]?.boolValue == true { return .closed() }
            guard let frame = value["frame"] else { throw ACPError.malformedFrame("recording line without \"frame\"") }
            return Entry(side: side, frame: frame)
        }
    }

    /// Every string in `value` passed through `transform` (keys are left alone), for scrubbing a recording
    /// without breaking its JSON.
    public static func mappingStrings(_ value: JSONValue, _ transform: (String) -> String) -> JSONValue {
        switch value {
        case .string(let text): .string(transform(text))
        case .array(let items): .array(items.map { mappingStrings($0, transform) })
        case .object(let object): .object(object.mapValues { mappingStrings($0, transform) })
        default: value
        }
    }
}

/// Wraps a transport and reports every frame that crosses it, and the agent closing, to `record`. What to keep
/// and how to scrub it is the caller's. Frames are passed on unchanged and unchanged in timing.
public final class ACPRecordingTransport: ACPTransport, @unchecked Sendable {
    public let incoming: AsyncStream<Data>
    private let inner: any ACPTransport
    private let record: @Sendable (ACPRecording.Entry) -> Void
    private let forwarding: Task<Void, Never>

    public init(wrapping inner: any ACPTransport, record: @escaping @Sendable (ACPRecording.Entry) -> Void) {
        self.inner = inner
        self.record = record
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        incoming = stream
        forwarding = Task {
            var buffer = Data()
            for await chunk in inner.incoming {
                continuation.yield(chunk)
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let frame = try? JSONValue(parsing: String(decoding: line, as: UTF8.self)) {
                        record(ACPRecording.Entry(side: .agent, frame: frame))
                    }
                }
            }
            record(.closed())
            continuation.finish()
        }
    }

    public func send(_ line: Data) async throws {
        if let frame = try? JSONValue(parsing: String(decoding: line, as: UTF8.self)) {
            record(ACPRecording.Entry(side: .client, frame: frame))
        }
        try await inner.send(line)
    }

    public func close() async {
        await inner.close()
    }
}
